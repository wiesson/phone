@preconcurrency import AVFoundation
import Darwin
import Foundation
import Security

let defaultGeminiLiveModel = "gemini-3.1-flash-live-preview"
let defaultAssistantInstructions = "Du bist der freundliche, professionelle Telefonassistent von Arne Wiese. Arne ist gerade nicht erreichbar. Begrüße Anrufer kurz, erkläre das, und biete an, eine Nachricht mit Name, Anliegen und Rückrufnummer aufzunehmen. Halte dich kurz und antworte auf Deutsch, außer der Anrufer spricht eine andere Sprache."
let assistantGreetingTrigger = "Der Anruf wurde soeben angenommen. Begrüße den Anrufer jetzt."

enum GeminiLiveState: Equatable, Sendable {
    case off
    case connecting
    case live
    case failed(String)
}

enum GeminiLiveError: LocalizedError {
    case invalidAPIKey
    case invalidAudioFormat
    case invalidEndpoint
    case keychain(OSStatus)
    case socket(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "Configure a Gemini API key in Settings."
        case .invalidAudioFormat: "The call audio format is not supported by the Gemini bridge."
        case .invalidEndpoint: "The Gemini Live endpoint could not be created."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil).map { ($0 as NSString) as String } ?? "The Gemini API key could not be saved in Keychain."
        case .socket(let code): String(cString: strerror(code))
        }
    }
}

enum GeminiAPIKeyStore {
    static let service = "Phone Gemini"
    static let account = "api-key"

    static func save(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw GeminiLiveError.keychain(updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GeminiLiveError.keychain(addStatus) }
    }

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }
        let fallback = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }
}

enum AudioInjectionProtocol {
    static func packet(samples: Data, sampleRate: UInt32) -> Data {
        var packet = Data([0x50, 0x54, 0x41, 0x49, 1, Speaker.me.rawValue, 1, 1])
        appendLittleEndian(sampleRate, to: &packet)
        appendLittleEndian(UInt32(samples.count), to: &packet)
        packet.append(samples)
        return packet
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

struct GeminiServerMessage: Equatable, Sendable {
    let setupComplete: Bool
    let audioChunks: [Data]
    let turnComplete: Bool
}

enum GeminiLiveProtocol {
    static func setupMessage(model: String, instructions: String) throws -> String {
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        var setup: [String: Any] = [
            "model": modelPath,
            "generationConfig": ["responseModalities": ["AUDIO"]]
        ]
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            setup["systemInstruction"] = ["parts": [["text": trimmedInstructions]]]
        }
        let object: [String: Any] = ["setup": setup]
        return try jsonString(object)
    }

    static func greetingMessage() throws -> String {
        let object: [String: Any] = [
            "clientContent": [
                "turns": [
                    ["role": "user", "parts": [["text": assistantGreetingTrigger]]]
                ],
                "turnComplete": true
            ]
        ]
        return try jsonString(object)
    }

    static func realtimeInputMessage(pcm: Data) throws -> String {
        let object: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm.base64EncodedString()
                ]
            ]
        ]
        return try jsonString(object)
    }

    static func decodeServerMessage(_ data: Data) -> GeminiServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let setupComplete = object["setupComplete"] != nil
        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return GeminiServerMessage(setupComplete: setupComplete, audioChunks: [], turnComplete: false)
        }
        let turnComplete = serverContent["turnComplete"] as? Bool ?? false
        let modelTurn = serverContent["modelTurn"] as? [String: Any]
        let parts = modelTurn?["parts"] as? [[String: Any]] ?? []
        let chunks = parts.compactMap { part -> Data? in
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let encoded = inlineData["data"] as? String else { return nil }
            return Data(base64Encoded: encoded)
        }
        return GeminiServerMessage(setupComplete: setupComplete, audioChunks: chunks, turnComplete: turnComplete)
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw GeminiLiveError.invalidEndpoint }
        return string
    }
}

func resamplePCM16Mono(_ data: Data, from sourceRate: Int, to targetRate: Int) -> Data {
    guard sourceRate > 0, targetRate > 0, data.count >= 2 else { return Data() }
    if sourceRate == targetRate { return Data(data.prefix(data.count - data.count % 2)) }
    let sampleCount = data.count / 2
    var samples = [Int16]()
    samples.reserveCapacity(sampleCount)
    for index in 0..<sampleCount {
        let offset = index * 2
        let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        samples.append(Int16(bitPattern: value))
    }
    let outputCount = max(1, Int((Double(sampleCount) * Double(targetRate) / Double(sourceRate)).rounded()))
    var output = Data(capacity: outputCount * 2)
    for index in 0..<outputCount {
        let position = Double(index) * Double(sourceRate) / Double(targetRate)
        let lower = min(Int(position), sampleCount - 1)
        let upper = min(lower + 1, sampleCount - 1)
        let fraction = position - Double(lower)
        let interpolated = Double(samples[lower]) + (Double(samples[upper]) - Double(samples[lower])) * fraction
        var value = UInt16(bitPattern: Int16(clamping: Int(interpolated.rounded()))).littleEndian
        withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
    }
    return output
}

private final class GeminiConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class GeminiCallerAudioConverter {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func convert(_ frame: AudioFrame) -> Data? {
        guard let inputFormat = AVAudioFormat(
            commonFormat: frame.format,
            sampleRate: frame.sampleRate,
            channels: frame.channels,
            interleaved: true
        ) else { return nil }
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = AVAudioFrameCount(frame.samples.count / bytesPerFrame)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        input.frameLength = frameCount
        frame.samples.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress,
                  let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(destination, source, frame.samples.count)
            input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(frame.samples.count)
        }
        if inputFormat == targetFormat { return frame.samples }
        if sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let converterInput = GeminiConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if converterInput.supplied {
                status.pointee = .noDataNow
                return nil
            }
            converterInput.supplied = true
            status.pointee = .haveData
            return converterInput.buffer
        }
        guard status == .haveData || status == .inputRanDry,
              output.frameLength > 0,
              let bytes = output.audioBufferList.pointee.mBuffers.mData else { return nil }
        return Data(bytes: bytes, count: Int(output.audioBufferList.pointee.mBuffers.mDataByteSize))
    }
}

private final class AudioInjectionSender {
    static let socketPath = "/tmp/phone-audio-inject-\(getuid()).sock"
    private var descriptor: Int32 = -1

    init() throws {
        descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw GeminiLiveError.socket(errno) }
    }

    func write(samples: Data, sampleRate: UInt32) throws {
        let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: sampleRate)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw GeminiLiveError.socket(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard sent == packet.count else { throw GeminiLiveError.socket(errno) }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}

actor GeminiLiveBridge {
    typealias StateHandler = @Sendable (GeminiLiveState) -> Void

    private var state: GeminiLiveState = .off
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pacingTask: Task<Void, Never>?
    private var stateHandler: StateHandler?
    private var callerConverter = GeminiCallerAudioConverter()
    private var injectionSender: AudioInjectionSender?
    private var targetSampleRate: UInt32?
    private var modelAudio = Data()
    private var outputAudio = Data()
    private var sessionID = 0
    private var sendsInitialGreeting = false

    func start(
        apiKey: String,
        model: String,
        instructions: String,
        sendsInitialGreeting: Bool = false,
        onState: @escaping StateHandler
    ) async {
        stop(notify: false)
        sessionID &+= 1
        let requestID = sessionID
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            onState(.failed(GeminiLiveError.invalidAPIKey.localizedDescription))
            return
        }
        stateHandler = onState
        self.sendsInitialGreeting = sendsInitialGreeting
        publish(.connecting)
        do {
            injectionSender = try AudioInjectionSender()
            var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            guard let url = components?.url else { throw GeminiLiveError.invalidEndpoint }
            let session = URLSession(configuration: .default)
            let socket = session.webSocketTask(with: url)
            self.session = session
            self.socket = socket
            socket.resume()
            let setup = try GeminiLiveProtocol.setupMessage(model: model, instructions: instructions)
            try await socket.send(.string(setup))
            guard requestID == sessionID, state != .off else { return }
            receiveTask = Task { [weak self] in await self?.receiveLoop(sessionID: requestID) }
        } catch {
            if requestID == sessionID { fail(error.localizedDescription) }
        }
    }

    func append(_ frame: AudioFrame) async {
        if frame.speaker == .me {
            guard frame.format == .pcmFormatInt16, frame.channels == 1,
                  frame.sampleRate > 0, frame.sampleRate <= Double(UInt32.max) else {
                if state == .connecting || state == .live { fail(GeminiLiveError.invalidAudioFormat.localizedDescription) }
                return
            }
            let rate = UInt32(frame.sampleRate.rounded())
            if targetSampleRate != rate {
                targetSampleRate = rate
                outputAudio.removeAll(keepingCapacity: true)
                flushModelAudio()
            }
            return
        }
        guard frame.speaker == .caller, state == .live, let socket,
              let pcm = callerConverter.convert(frame), !pcm.isEmpty else { return }
        do {
            try await socket.send(.string(GeminiLiveProtocol.realtimeInputMessage(pcm: pcm)))
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        sessionID &+= 1
        state = .off
        receiveTask?.cancel()
        pacingTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        receiveTask = nil
        pacingTask = nil
        socket = nil
        session = nil
        injectionSender = nil
        targetSampleRate = nil
        modelAudio.removeAll(keepingCapacity: false)
        outputAudio.removeAll(keepingCapacity: false)
        callerConverter = GeminiCallerAudioConverter()
        sendsInitialGreeting = false
        if notify { stateHandler?(.off) }
        stateHandler = nil
    }

    private func receiveLoop(sessionID requestID: Int) async {
        do {
            while !Task.isCancelled, requestID == sessionID, let socket {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                guard let decoded = GeminiLiveProtocol.decodeServerMessage(data) else {
                    phoneDiagnosticLog("phone-app: Gemini message not decoded: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")\n")
                    continue
                }
                if decoded.setupComplete {
                    phoneDiagnosticLog("phone-app: Gemini setup complete, session live\n")
                    publish(.live)
                    if sendsInitialGreeting {
                        sendsInitialGreeting = false
                        try await socket.send(.string(GeminiLiveProtocol.greetingMessage()))
                    }
                }
                for chunk in decoded.audioChunks {
                    modelAudio.append(chunk)
                }
                flushModelAudio()
                if decoded.turnComplete { flushPartialOutput() }
            }
        } catch {
            if requestID == sessionID, state != .off && !(error is CancellationError) {
                let code = socket?.closeCode.rawValue ?? -1
                let reason = socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
                let redactedError = redactSensitiveValues(in: String(describing: error))
                phoneDiagnosticLog("phone-app: Gemini socket closed — code \(code), reason: \(reason), error: \(redactedError)\n")
                fail(error.localizedDescription)
            }
        }
    }

    private func flushModelAudio() {
        guard let targetSampleRate, !modelAudio.isEmpty else { return }
        outputAudio.append(resamplePCM16Mono(modelAudio, from: 24_000, to: Int(targetSampleRate)))
        modelAudio.removeAll(keepingCapacity: true)
        startPacingIfNeeded()
    }

    private func flushPartialOutput() {
        guard let targetSampleRate, !outputAudio.isEmpty else { return }
        let packetSize = Int(targetSampleRate / 50) * MemoryLayout<Int16>.size
        guard packetSize > 0 else { return }
        let remainder = outputAudio.count % packetSize
        if remainder > 0 {
            outputAudio.append(Data(repeating: 0, count: packetSize - remainder))
        }
        startPacingIfNeeded()
    }

    private func startPacingIfNeeded() {
        guard state == .live, pacingTask == nil, let targetSampleRate else { return }
        let packetSize = Int(targetSampleRate / 50) * MemoryLayout<Int16>.size
        guard packetSize > 0, outputAudio.count >= packetSize else { return }
        let requestID = sessionID
        pacingTask = Task { [weak self] in await self?.paceOutput(sessionID: requestID) }
    }

    private func paceOutput(sessionID requestID: Int) async {
        while !Task.isCancelled, requestID == sessionID, state == .live, let targetSampleRate, let injectionSender {
            let packetSize = Int(targetSampleRate / 50) * MemoryLayout<Int16>.size
            guard packetSize > 0, outputAudio.count >= packetSize else { break }
            let samples = Data(outputAudio.prefix(packetSize))
            outputAudio.removeFirst(packetSize)
            do {
                try injectionSender.write(samples: samples, sampleRate: targetSampleRate)
                try await Task.sleep(for: .milliseconds(20))
            } catch is CancellationError {
                break
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        guard requestID == sessionID else { return }
        pacingTask = nil
        if !outputAudio.isEmpty { startPacingIfNeeded() }
    }

    private func publish(_ newState: GeminiLiveState) {
        state = newState
        stateHandler?(newState)
    }

    private func fail(_ message: String) {
        sessionID &+= 1
        receiveTask?.cancel()
        pacingTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        receiveTask = nil
        pacingTask = nil
        socket = nil
        session = nil
        injectionSender = nil
        sendsInitialGreeting = false
        modelAudio.removeAll(keepingCapacity: false)
        outputAudio.removeAll(keepingCapacity: false)
        publish(.failed("Gemini Live: \(message)"))
    }
}
