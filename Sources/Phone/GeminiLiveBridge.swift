@preconcurrency import AVFoundation
import Darwin
import Foundation
import Security

let defaultGeminiLiveModel = "gemini-3.1-flash-live-preview"
let defaultAssistantInstructions = "Du bist der freundliche, professionelle Telefonassistent von Arne Wiese. Arne ist gerade nicht erreichbar. Begrüße Anrufer kurz, erkläre das, und biete an, eine Nachricht mit Name, Anliegen und Rückrufnummer aufzunehmen. Halte dich kurz und antworte auf Deutsch, außer der Anrufer spricht eine andere Sprache."
let assistantGreetingTrigger = "Der Anruf wurde soeben angenommen. Begrüße den Anrufer jetzt."

struct ResolvedAssistantProfile: Equatable, Sendable {
    let account: ManagedSIPAccount?
    let instructions: String
    let contextData: String?
}

func normalizedSIPAOR(_ value: String?) -> String? {
    guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
    if let separator = value.firstIndex(where: { $0 == ";" || $0 == ">" || $0.isWhitespace }) {
        value = String(value[..<separator])
    }
    let decoded = value.removingPercentEncoding ?? value
    let parts = decoded.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return decoded.lowercased()
}

func resolveAssistantProfile(
    accounts: [ManagedSIPAccount],
    savedProfiles: [SavedAssistantProfile] = [],
    calledAOR: String?,
    activeSIPAddress: String?,
    globalInstructions: String,
    date: Date = Date(),
    calendar: Calendar = .current
) -> ResolvedAssistantProfile {
    let called = normalizedSIPAOR(calledAOR)
    let active = normalizedSIPAOR(activeSIPAddress)
    let account = called.flatMap { address in
        accounts.first { normalizedSIPAOR($0.sipAddress) == address }
    } ?? active.flatMap { address in
        accounts.first { normalizedSIPAOR($0.sipAddress) == address }
    }
    guard let account else {
        return ResolvedAssistantProfile(account: nil, instructions: globalInstructions, contextData: nil)
    }
    let savedProfile = account.savedProfileID.flatMap { id in
        savedProfiles.first { $0.id == id }
    }
    let instructions = savedProfile?.instructions
        ?? account.assistantInstructionsOverride
        ?? account.assistantProfile.presetInstructions(globalFallback: globalInstructions)
    let contextData = savedProfile?.contextData
        ?? account.assistantContextData
        ?? account.assistantProfile.presetContextData(startingAt: date, calendar: calendar)
    return ResolvedAssistantProfile(account: account, instructions: instructions, contextData: contextData)
}

let phoneEtiquettePreamble = """
Telefon-Grundregeln: Du führst ein Telefongespräch mit genau einem Anrufer. \
Sprich in kurzen Sätzen und stelle höchstens eine Frage pro Redebeitrag. \
Wenn du mehrere Stimmen, Hintergrundgespräche oder Störgeräusche hörst, bleib ruhig bei deinem Gesprächspartner \
und reagiere nur auf das, was klar an dich gerichtet ist; frag im Zweifel kurz nach. \
Wenn du unterbrochen wirst, hör auf zu sprechen, höre zu und antworte dann knapp auf das Neue.
"""

func composeAssistantSystemInstruction(
    instructions: String,
    contextData: String?,
    includesGreetingTrigger: Bool = false
) -> String {
    let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = contextData?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let dataSection = context.isEmpty ? "" : "Daten:\n\(context)"
    let greeting = includesGreetingTrigger ? assistantGreetingTrigger : ""
    return [phoneEtiquettePreamble, instructions, dataSection, greeting].filter { !$0.isEmpty }.joined(separator: "\n\n")
}

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

/// The model always speaks mono. A call that negotiated stereo needs the same
/// voice on both channels — centred, and lossless, because there is no stereo
/// information to lose.
func interleavedMonoAudio(_ mono: Data, channels: UInt8) -> Data {
    guard channels > 1 else { return mono }
    let sampleCount = mono.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return mono }
    var result = Data(capacity: sampleCount * Int(channels) * MemoryLayout<Int16>.size)
    mono.withUnsafeBytes { bytes in
        let samples = bytes.bindMemory(to: Int16.self)
        for index in 0..<sampleCount {
            var sample = samples[index]
            let bytes = withUnsafeBytes(of: &sample) { Data($0) }
            for _ in 0..<channels { result.append(bytes) }
        }
    }
    return result
}

enum AudioInjectionProtocol {
    /// Injection has to match the transmit format the call negotiated. Since
    /// Opus is offered first, sipgate answers with stereo, and a packet that
    /// claims mono is rejected by the tap.
    static func packet(samples: Data, sampleRate: UInt32, channels: UInt8) -> Data {
        var packet = Data([0x50, 0x54, 0x41, 0x49, 1, Speaker.me.rawValue, 1, channels])
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
    let inputTranscription: String?
    let outputTranscription: String?
    let toolCalls: [GeminiToolCall]
}

indirect enum GeminiToolArgument: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: GeminiToolArgument])
    case array([GeminiToolArgument])
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    init(jsonValue: Any) {
        switch jsonValue {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.mapValues(Self.init(jsonValue:)))
        case let value as [Any]:
            self = .array(value.map(Self.init(jsonValue:)))
        default:
            self = .null
        }
    }
}

struct GeminiToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: [String: GeminiToolArgument]
}

struct GeminiTranscriptUtterance: Equatable, Sendable {
    let speaker: Speaker
    let text: String
}

struct GeminiTranscriptionBuffer: Sendable {
    private var speaker: Speaker?
    private var text = ""

    mutating func receive(
        inputTranscription: String?,
        outputTranscription: String?,
        turnComplete: Bool
    ) -> [GeminiTranscriptUtterance] {
        var utterances: [GeminiTranscriptUtterance] = []
        append(inputTranscription, for: .caller, to: &utterances)
        append(outputTranscription, for: .me, to: &utterances)
        if turnComplete, let utterance = flush() { utterances.append(utterance) }
        return utterances
    }

    mutating func flush() -> GeminiTranscriptUtterance? {
        defer {
            speaker = nil
            text = ""
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker, !cleaned.isEmpty else { return nil }
        return GeminiTranscriptUtterance(speaker: speaker, text: cleaned)
    }

    private mutating func append(
        _ fragment: String?,
        for newSpeaker: Speaker,
        to utterances: inout [GeminiTranscriptUtterance]
    ) {
        guard let fragment, !fragment.isEmpty else { return }
        if speaker != nil, speaker != newSpeaker, let utterance = flush() {
            utterances.append(utterance)
        }
        speaker = newSpeaker
        if text.isEmpty || text.last?.isWhitespace == true || fragment.first?.isWhitespace == true || fragment.first?.isPunctuation == true {
            text += fragment
        } else {
            text += " " + fragment
        }
    }
}

enum AssistantLiveEndpoint: Equatable, Sendable {
    case gemini
    case brain(URL)
}

func resolveAssistantLiveEndpoint(_ value: String?) -> AssistantLiveEndpoint {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
          url.host?.isEmpty == false else { return .gemini }
    return .brain(url)
}

enum BrainServerMessage: Equatable, Sendable {
    case state(GeminiLiveState)
    case toolLog(String)
}

enum BrainLiveProtocol {
    static func setupMessage(model: String, instructions: String, greeting: Bool) throws -> String {
        let object: [String: Any] = [
            "type": "setup",
            "instructions": instructions,
            "greeting": greeting,
            "model": model
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw GeminiLiveError.invalidEndpoint }
        return string
    }

    static func decodeServerMessage(_ data: Data) -> BrainServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "state", let value = object["value"] as? String {
            switch value {
            case "live": return .state(.live)
            case "failed": return .state(.failed(object["message"] as? String ?? "External brain failed"))
            default: return nil
            }
        }
        if type == "toolLog", let name = object["name"] as? String {
            let args = compactJSONString(object["args"] ?? [:])
            let result = object["result"].map(compactJSONString)
            let suffix = result.map { " result=\($0)" } ?? ""
            return .toolLog("phone-app: brain tool \(name) args=\(args)\(suffix)\n")
        }
        return nil
    }

    private static func compactJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return String(string.prefix(1_000))
    }
}

enum GeminiLiveProtocol {
    static func setupMessage(model: String, instructions: String) throws -> String {
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        var setup: [String: Any] = [
            "model": modelPath,
            "generationConfig": ["responseModalities": ["AUDIO"]],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            "tools": [[
                "functionDeclarations": [
                    [
                        "name": "send_dtmf",
                        "description": "Send one DTMF key during the phone call to navigate an IVR menu.",
                        "parameters": [
                            "type": "OBJECT",
                            "properties": [
                                "digit": [
                                    "type": "STRING",
                                    "description": "The single DTMF key to send.",
                                    "enum": ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"]
                                ]
                            ],
                            "required": ["digit"]
                        ]
                    ],
                    [
                        "name": "handover_to_user",
                        "description": "Make the user audible after announcing that the call is being handed over."
                    ]
                ]
            ]]
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

    static func toolResponseMessage(for call: GeminiToolCall) throws -> String {
        let object: [String: Any] = [
            "toolResponse": [
                "functionResponses": [[
                    "id": call.id,
                    "name": call.name,
                    "response": ["result": "ok"]
                ]]
            ]
        ]
        return try jsonString(object)
    }

    static func decodeServerMessage(_ data: Data) -> GeminiServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let setupComplete = object["setupComplete"] != nil
        let toolCall = object["toolCall"] as? [String: Any]
        let functionCalls = toolCall?["functionCalls"] as? [[String: Any]] ?? []
        let decodedToolCalls = functionCalls.compactMap { functionCall -> GeminiToolCall? in
            guard let id = functionCall["id"] as? String,
                  let name = functionCall["name"] as? String else { return nil }
            let arguments = (functionCall["args"] as? [String: Any] ?? [:])
                .mapValues(GeminiToolArgument.init(jsonValue:))
            return GeminiToolCall(id: id, name: name, arguments: arguments)
        }
        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return GeminiServerMessage(
                setupComplete: setupComplete,
                audioChunks: [],
                turnComplete: false,
                inputTranscription: nil,
                outputTranscription: nil,
                toolCalls: decodedToolCalls
            )
        }
        let turnComplete = serverContent["turnComplete"] as? Bool ?? false
        let inputTranscription = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String
        let outputTranscription = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String
        let modelTurn = serverContent["modelTurn"] as? [String: Any]
        let parts = modelTurn?["parts"] as? [[String: Any]] ?? []
        let chunks = parts.compactMap { part -> Data? in
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let encoded = inlineData["data"] as? String else { return nil }
            return Data(base64Encoded: encoded)
        }
        return GeminiServerMessage(
            setupComplete: setupComplete,
            audioChunks: chunks,
            turnComplete: turnComplete,
            inputTranscription: inputTranscription,
            outputTranscription: outputTranscription,
            toolCalls: decodedToolCalls
        )
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw GeminiLiveError.invalidEndpoint }
        return string
    }
}

private final class GeminiConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class PCM16MonoResampler {
    private struct RatePair: Hashable {
        let source: Int
        let target: Int
    }

    private struct ConversionState {
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        let converter: AVAudioConverter
    }

    private var states: [RatePair: ConversionState] = [:]

    func resample(_ data: Data, from sourceRate: Int, to targetRate: Int) -> Data {
        guard sourceRate > 0, targetRate > 0, data.count >= 2 else { return Data() }
        let byteCount = data.count - data.count % MemoryLayout<Int16>.size
        if sourceRate == targetRate { return Data(data.prefix(byteCount)) }
        let pair = RatePair(source: sourceRate, target: targetRate)
        guard let state = state(for: pair) else { return Data() }
        let inputFrameCount = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
        guard let input = AVAudioPCMBuffer(pcmFormat: state.inputFormat, frameCapacity: inputFrameCount) else {
            return Data()
        }
        input.frameLength = inputFrameCount
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress,
                  let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(destination, source, byteCount)
            input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        }
        let ratio = state.outputFormat.sampleRate / state.inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrameCount) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: state.outputFormat, frameCapacity: outputCapacity) else {
            return Data()
        }
        let converterInput = GeminiConverterInput(buffer: input)
        var conversionError: NSError?
        let status = state.converter.convert(to: output, error: &conversionError) { _, status in
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
              let bytes = output.audioBufferList.pointee.mBuffers.mData else { return Data() }
        return Data(bytes: bytes, count: Int(output.audioBufferList.pointee.mBuffers.mDataByteSize))
    }

    private func state(for pair: RatePair) -> ConversionState? {
        if let state = states[pair] { return state }
        guard let inputFormat = Self.format(sampleRate: pair.source),
              let outputFormat = Self.format(sampleRate: pair.target),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let state = ConversionState(inputFormat: inputFormat, outputFormat: outputFormat, converter: converter)
        states[pair] = state
        return state
    }

    private static func format(sampleRate: Int) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        )
    }
}

final class GeminiCallerAudioConverter {
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
    let socketPath: String
    private var descriptor: Int32 = -1
    private var lastSampleRate: UInt32?
    private var lastChannels: UInt8 = 1

    init(socketPath: String) throws {
        self.socketPath = socketPath
        descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw GeminiLiveError.socket(errno) }
    }

    func write(samples: Data, sampleRate: UInt32, channels: UInt8) throws {
        let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: sampleRate, channels: channels)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
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
        guard sent == packet.count else {
            let code = errno
            if code == ENOBUFS || code == ECONNREFUSED || code == ENOENT {
                phoneDiagnosticLog("phone-app: injection packet dropped (\(code)) — receiver not draining\n")
                return
            }
            throw GeminiLiveError.socket(code)
        }
        if !samples.isEmpty {
            lastSampleRate = sampleRate
            lastChannels = channels
        }
    }

    func finish() throws {
        guard let lastSampleRate else { return }
        self.lastSampleRate = nil
        // The closing packet has to carry the same format as the audio it ends.
        try write(samples: Data(), sampleRate: lastSampleRate, channels: lastChannels)
    }

    deinit {
        try? finish()
        if descriptor >= 0 { close(descriptor) }
    }
}

actor GeminiLiveBridge {
    typealias StateHandler = @Sendable (GeminiLiveState) -> Void
    typealias TranscriptHandler = @Sendable (Speaker, String) -> Void
    typealias ToolCallHandler = @Sendable (GeminiToolCall) async -> Void

    private var state: GeminiLiveState = .off
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pacingTask: Task<Void, Never>?
    private var stateHandler: StateHandler?
    private var transcriptHandler: TranscriptHandler?
    private var toolCallHandler: ToolCallHandler?
    private var transcriptionBuffer = GeminiTranscriptionBuffer()
    private var callerConverter = GeminiCallerAudioConverter()
    private var modelResampler = PCM16MonoResampler()
    private var injectionSender: AudioInjectionSender?
    private var targetSampleRate: UInt32?
    private var targetChannels: UInt8 = 1
    private var modelAudio = Data()
    private var outputAudio = Data()
    private var pendingInjectionEnd = false
    private var sessionID = 0
    private var sendsInitialGreeting = false
    private var usesBrain = false

    func start(
        apiKey: String,
        brainURL: URL? = nil,
        model: String,
        instructions: String,
        sendsInitialGreeting: Bool = false,
        injectionSocketPath: String,
        onState: @escaping StateHandler,
        onTranscript: @escaping TranscriptHandler,
        onToolCall: @escaping ToolCallHandler
    ) async {
        if let brainURL {
            await startBrain(
                url: brainURL,
                model: model,
                instructions: instructions,
                sendsInitialGreeting: sendsInitialGreeting,
                injectionSocketPath: injectionSocketPath,
                onState: onState
            )
            return
        }
        stop(notify: false)
        sessionID &+= 1
        let requestID = sessionID
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            onState(.failed(GeminiLiveError.invalidAPIKey.localizedDescription))
            return
        }
        stateHandler = onState
        transcriptHandler = onTranscript
        toolCallHandler = onToolCall
        self.sendsInitialGreeting = sendsInitialGreeting
        publish(.connecting)
        do {
            injectionSender = try AudioInjectionSender(socketPath: injectionSocketPath)
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
            // The transmit frame decides the injection format. A phone call is
            // mono or stereo; anything else is not something this bridge can
            // clock against.
            guard frame.format == .pcmFormatInt16, frame.channels == 1 || frame.channels == 2,
                  frame.sampleRate > 0, frame.sampleRate <= Double(UInt32.max) else {
                if state == .connecting || state == .live { fail(GeminiLiveError.invalidAudioFormat.localizedDescription) }
                return
            }
            let rate = UInt32(frame.sampleRate.rounded())
            let channels = UInt8(frame.channels)
            if targetSampleRate != rate || targetChannels != channels {
                try? injectionSender?.finish()
                targetSampleRate = rate
                targetChannels = channels
                outputAudio.removeAll(keepingCapacity: true)
                pendingInjectionEnd = false
                flushModelAudio()
            }
            return
        }
        guard frame.speaker == .caller, state == .live, let socket,
              let pcm = callerConverter.convert(frame), !pcm.isEmpty else { return }
        if usesBrain {
            do {
                try await socket.send(.data(pcm))
            } catch {
                failBrain(error.localizedDescription)
            }
            return
        }
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
        flushTranscription()
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
        targetChannels = 1
        modelAudio.removeAll(keepingCapacity: false)
        outputAudio.removeAll(keepingCapacity: false)
        callerConverter = GeminiCallerAudioConverter()
        modelResampler = PCM16MonoResampler()
        pendingInjectionEnd = false
        sendsInitialGreeting = false
        usesBrain = false
        transcriptionBuffer = GeminiTranscriptionBuffer()
        if notify { stateHandler?(.off) }
        stateHandler = nil
        transcriptHandler = nil
        toolCallHandler = nil
    }

    private func startBrain(
        url: URL,
        model: String,
        instructions: String,
        sendsInitialGreeting: Bool,
        injectionSocketPath: String,
        onState: @escaping StateHandler
    ) async {
        stop(notify: false)
        sessionID &+= 1
        let requestID = sessionID
        stateHandler = onState
        usesBrain = true
        publish(.connecting)
        do {
            injectionSender = try AudioInjectionSender(socketPath: injectionSocketPath)
            let session = URLSession(configuration: .default)
            let socket = session.webSocketTask(with: url)
            self.session = session
            self.socket = socket
            socket.resume()
            let setup = try BrainLiveProtocol.setupMessage(
                model: model,
                instructions: instructions,
                greeting: sendsInitialGreeting
            )
            try await socket.send(.string(setup))
            guard requestID == sessionID, state != .off else { return }
            receiveTask = Task { [weak self] in await self?.receiveBrainLoop(sessionID: requestID) }
        } catch {
            if requestID == sessionID { failBrain(error.localizedDescription) }
        }
    }

    private func receiveBrainLoop(sessionID requestID: Int) async {
        do {
            while !Task.isCancelled, requestID == sessionID, let socket {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    modelAudio.append(data)
                    flushModelAudio()
                case .string(let string):
                    guard let decoded = BrainLiveProtocol.decodeServerMessage(Data(string.utf8)) else {
                        phoneDiagnosticLog("phone-app: brain message not decoded: \(String(string.prefix(300)))\n")
                        continue
                    }
                    switch decoded {
                    case .state(.live):
                        phoneDiagnosticLog("phone-app: external brain session live\n")
                        publish(.live)
                    case .state(.failed(let message)):
                        failBrain(message)
                        return
                    case .state:
                        continue
                    case .toolLog(let message):
                        phoneDiagnosticLog(message)
                    }
                @unknown default:
                    continue
                }
            }
        } catch {
            if requestID == sessionID, state != .off && !(error is CancellationError) {
                let code = socket?.closeCode.rawValue ?? -1
                let reason = socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
                let redactedError = redactSensitiveValues(in: String(describing: error))
                phoneDiagnosticLog("phone-app: brain socket closed — code \(code), reason: \(reason), error: \(redactedError)\n")
                failBrain(error.localizedDescription)
            }
        }
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
                let utterances = transcriptionBuffer.receive(
                    inputTranscription: decoded.inputTranscription,
                    outputTranscription: decoded.outputTranscription,
                    turnComplete: decoded.turnComplete
                )
                for utterance in utterances {
                    transcriptHandler?(utterance.speaker, utterance.text)
                }
                for call in decoded.toolCalls {
                    await toolCallHandler?(call)
                    try await socket.send(.string(GeminiLiveProtocol.toolResponseMessage(for: call)))
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

    /// One 20 ms packet, in the format the call negotiated.
    private func injectionPacketSize(sampleRate: UInt32) -> Int {
        Int(sampleRate / 50) * Int(targetChannels) * MemoryLayout<Int16>.size
    }

    private func flushModelAudio() {
        guard let targetSampleRate, !modelAudio.isEmpty else { return }
        let mono = modelResampler.resample(modelAudio, from: 24_000, to: Int(targetSampleRate))
        outputAudio.append(interleavedMonoAudio(mono, channels: targetChannels))
        modelAudio.removeAll(keepingCapacity: true)
        startPacingIfNeeded()
    }

    private func flushPartialOutput() {
        pendingInjectionEnd = true
        guard let targetSampleRate, !outputAudio.isEmpty else {
            try? injectionSender?.finish()
            pendingInjectionEnd = false
            return
        }
        let packetSize = injectionPacketSize(sampleRate: targetSampleRate)
        guard packetSize > 0 else { return }
        let remainder = outputAudio.count % packetSize
        if remainder > 0 {
            outputAudio.append(Data(repeating: 0, count: packetSize - remainder))
        }
        startPacingIfNeeded()
    }

    private func startPacingIfNeeded() {
        guard state == .live, pacingTask == nil, let targetSampleRate else { return }
        let packetSize = injectionPacketSize(sampleRate: targetSampleRate)
        guard packetSize > 0, outputAudio.count >= packetSize else { return }
        let requestID = sessionID
        pacingTask = Task { [weak self] in await self?.paceOutput(sessionID: requestID) }
    }

    private func paceOutput(sessionID requestID: Int) async {
        let clock = ContinuousClock()
        var deadline = clock.now
        while !Task.isCancelled, requestID == sessionID, state == .live, let targetSampleRate, let injectionSender {
            let packetSize = injectionPacketSize(sampleRate: targetSampleRate)
            guard packetSize > 0, outputAudio.count >= packetSize else { break }
            let samples = Data(outputAudio.prefix(packetSize))
            outputAudio.removeFirst(packetSize)
            do {
                try injectionSender.write(samples: samples, sampleRate: targetSampleRate, channels: targetChannels)
                deadline += .milliseconds(20)
                try await clock.sleep(until: deadline)
            } catch is CancellationError {
                break
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        guard requestID == sessionID else { return }
        if pendingInjectionEnd {
            try? injectionSender?.finish()
            pendingInjectionEnd = false
        }
        pacingTask = nil
        if !outputAudio.isEmpty { startPacingIfNeeded() }
    }

    private func publish(_ newState: GeminiLiveState) {
        state = newState
        stateHandler?(newState)
    }

    private func flushTranscription() {
        guard let utterance = transcriptionBuffer.flush() else { return }
        transcriptHandler?(utterance.speaker, utterance.text)
    }

    private func failBrain(_ message: String) {
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
        usesBrain = false
        modelAudio.removeAll(keepingCapacity: false)
        outputAudio.removeAll(keepingCapacity: false)
        modelResampler = PCM16MonoResampler()
        pendingInjectionEnd = false
        transcriptionBuffer = GeminiTranscriptionBuffer()
        transcriptHandler = nil
        publish(.failed("External brain: \(message)"))
    }

    private func fail(_ message: String) {
        flushTranscription()
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
        modelResampler = PCM16MonoResampler()
        pendingInjectionEnd = false
        transcriptionBuffer = GeminiTranscriptionBuffer()
        transcriptHandler = nil
        toolCallHandler = nil
        publish(.failed("Gemini Live: \(message)"))
    }
}
