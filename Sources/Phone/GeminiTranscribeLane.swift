@preconcurrency import AVFoundation
import Foundation

let geminiTranscribeModel = "gemini-3.5-transcribe-live"

struct GeminiTranscribeResult: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

struct GeminiTranscribeServerMessage: Equatable, Sendable {
    let setupComplete: Bool
    let results: [GeminiTranscribeResult]
    let errorMessage: String?
}

enum GeminiTranscribeProtocol {
    static func setupMessage(
        smartMode: Bool,
        languageCodes: [String] = []
    ) throws -> String {
        var transcription: [String: Any] = ["languageCodes": languageCodes]
        if smartMode { transcription["mode"] = "SMART" }
        let object: [String: Any] = [
            "setup": [
                "model": "models/\(geminiTranscribeModel)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription
            ]
        ]
        return try jsonString(object)
    }

    static func realtimeInputMessage(pcm: Data) throws -> String {
        try GeminiLiveProtocol.realtimeInputMessage(pcm: pcm)
    }

    static func audioStreamEndMessage() throws -> String {
        try jsonString(["realtimeInput": ["audioStreamEnd": true]])
    }

    static func decodeServerMessage(_ data: Data) -> GeminiTranscribeServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let setupComplete = object["setupComplete"] != nil
        let errorMessage = ((object["error"] as? [String: Any])?["message"] as? String)
        guard let serverContent = object["serverContent"] as? [String: Any] else {
            return GeminiTranscribeServerMessage(
                setupComplete: setupComplete,
                results: [],
                errorMessage: errorMessage
            )
        }
        var results: [GeminiTranscribeResult] = []
        if let text = (serverContent["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            results.append(GeminiTranscribeResult(text: text, isFinal: false))
        }
        if let text = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String {
            results.append(GeminiTranscribeResult(text: text, isFinal: true))
        }
        return GeminiTranscribeServerMessage(
            setupComplete: setupComplete,
            results: results,
            errorMessage: errorMessage
        )
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GeminiLiveError.invalidEndpoint
        }
        return string
    }
}

actor GeminiTranscribeLane {
    typealias ResultHandler = @Sendable (Speaker, String, Bool) -> Void
    typealias ErrorHandler = @Sendable (Speaker, String) -> Void

    private static let audioChunkBytes = 16_000 / 10 * MemoryLayout<Int16>.size

    private let speaker: Speaker
    private let apiKey: String
    private let smartMode: Bool
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var converter = GeminiCallerAudioConverter()
    private var pendingAudio = Data()
    private var lastInterimText: String?
    private var generation = 0
    private var isActive = false
    private var isStopping = false
    private var onResult: ResultHandler?
    private var onError: ErrorHandler?

    init(speaker: Speaker, apiKey: String, smartMode: Bool) {
        self.speaker = speaker
        self.apiKey = apiKey
        self.smartMode = smartMode
    }

    func start(
        onResult: @escaping ResultHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        closeConnection(code: .normalClosure)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiLiveError.invalidAPIKey }
        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components?.url else { throw GeminiLiveError.invalidEndpoint }

        self.onResult = onResult
        self.onError = onError
        generation &+= 1
        let requestGeneration = generation
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        isActive = true
        isStopping = false
        socket.resume()
        do {
            try await socket.send(.string(GeminiTranscribeProtocol.setupMessage(smartMode: smartMode)))
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(generation: requestGeneration)
            }
        } catch {
            closeConnection(code: .goingAway)
            throw sanitizedError(error)
        }
    }

    func append(_ frame: AudioFrame) async {
        guard frame.speaker == speaker,
              let pcm = converter.convert(frame),
              !pcm.isEmpty else { return }
        await appendPCM(pcm)
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        guard let pcm = pcmData(from: buffer), !pcm.isEmpty else { return }
        let frame = AudioFrame(
            speaker: speaker,
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount,
            format: buffer.format.commonFormat,
            samples: pcm
        )
        await append(frame)
    }

    func stop() async {
        guard isActive else {
            closeConnection(code: .normalClosure)
            return
        }
        isStopping = true
        if let socket {
            do {
                if !pendingAudio.isEmpty {
                    let finalChunk = pendingAudio
                    pendingAudio.removeAll(keepingCapacity: false)
                    try await socket.send(.string(GeminiTranscribeProtocol.realtimeInputMessage(pcm: finalChunk)))
                }
                try await socket.send(.string(GeminiTranscribeProtocol.audioStreamEndMessage()))
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                phoneDiagnosticLog("phone-app: \(speaker.title) Gemini transcription stop failed: \(sanitizedDescription(error))\n")
            }
        }
        finalizeLastInterimIfNeeded()
        closeConnection(code: .normalClosure)
    }

    private func appendPCM(_ pcm: Data) async {
        guard isActive, !isStopping, let socket else { return }
        pendingAudio.append(pcm)
        do {
            while pendingAudio.count >= Self.audioChunkBytes {
                let chunk = Data(pendingAudio.prefix(Self.audioChunkBytes))
                pendingAudio.removeFirst(Self.audioChunkBytes)
                try await socket.send(.string(GeminiTranscribeProtocol.realtimeInputMessage(pcm: chunk)))
            }
        } catch {
            fail(error)
        }
    }

    private func receiveLoop(generation requestGeneration: Int) async {
        do {
            while !Task.isCancelled,
                  requestGeneration == generation,
                  isActive,
                  let socket {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                guard let decoded = GeminiTranscribeProtocol.decodeServerMessage(data) else {
                    let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                    phoneDiagnosticLog("phone-app: \(speaker.title) Gemini transcription message not decoded: \(redactSensitiveValues(in: preview))\n")
                    continue
                }
                if let message = decoded.errorMessage {
                    failMessage(message)
                    return
                }
                if decoded.setupComplete {
                    phoneDiagnosticLog("phone-app: \(speaker.title) Gemini transcription setup complete\n")
                }
                for result in decoded.results where !result.text.isEmpty {
                    lastInterimText = result.isFinal ? nil : result.text
                    onResult?(speaker, result.text, result.isFinal)
                }
            }
        } catch {
            guard requestGeneration == generation,
                  isActive,
                  !isStopping,
                  !(error is CancellationError) else { return }
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        failMessage(sanitizedDescription(error))
    }

    private func failMessage(_ message: String) {
        guard isActive else { return }
        let message = redactSensitiveValues(in: message)
        phoneDiagnosticLog("phone-app: \(speaker.title) Gemini transcription failed: \(message)\n")
        let handler = onError
        finalizeLastInterimIfNeeded()
        closeConnection(code: .goingAway)
        handler?(speaker, "Gemini transcription failed: \(message)")
    }

    private func finalizeLastInterimIfNeeded() {
        guard let text = lastInterimText else { return }
        lastInterimText = nil
        onResult?(speaker, text, true)
    }

    private func closeConnection(code: URLSessionWebSocketTask.CloseCode) {
        generation &+= 1
        isActive = false
        isStopping = false
        receiveTask?.cancel()
        socket?.cancel(with: code, reason: nil)
        session?.invalidateAndCancel()
        receiveTask = nil
        socket = nil
        session = nil
        pendingAudio.removeAll(keepingCapacity: false)
        lastInterimText = nil
        converter = GeminiCallerAudioConverter()
        onResult = nil
        onError = nil
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        let buffers = buffer.audioBufferList.pointee
        guard buffers.mNumberBuffers == 1,
              let bytes = buffers.mBuffers.mData else { return nil }
        return Data(bytes: bytes, count: Int(buffers.mBuffers.mDataByteSize))
    }

    private func sanitizedDescription(_ error: Error) -> String {
        redactSensitiveValues(in: String(describing: error))
    }

    private func sanitizedError(_ error: Error) -> NSError {
        NSError(
            domain: "GeminiTranscribeLane",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sanitizedDescription(error)]
        )
    }
}
