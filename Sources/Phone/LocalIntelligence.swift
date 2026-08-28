import AVFoundation
import Foundation
import FoundationModels
import Speech

enum TranscriptionEngine: String, CaseIterable, Sendable {
    case apple
    case gemini
}

struct TranscriptionEngineResolution: Equatable, Sendable {
    let requested: TranscriptionEngine
    let active: TranscriptionEngine

    var fellBackToApple: Bool { requested == .gemini && active == .apple }
}

func configuredTranscriptionEngine(defaults: UserDefaults = .standard) -> TranscriptionEngine {
    guard let value = defaults.string(forKey: "transcriptionEngine"),
          let engine = TranscriptionEngine(rawValue: value) else { return .apple }
    return engine
}

func resolveTranscriptionEngine(
    requested: TranscriptionEngine,
    geminiAPIKey: String?
) -> TranscriptionEngineResolution {
    let hasGeminiAPIKey = geminiAPIKey?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    let active: TranscriptionEngine = requested == .gemini && hasGeminiAPIKey ? .gemini : .apple
    return TranscriptionEngineResolution(requested: requested, active: active)
}

protocol TranscriptionLane: Actor {
    func start(
        onResult: @escaping @Sendable (Speaker, String, Bool) -> Void,
        onError: @escaping @Sendable (Speaker, String) -> Void
    ) async throws
    func append(_ frame: AudioFrame) async
    func stop() async
}

actor SpeechLane {
    enum LaneError: LocalizedError {
        case unavailable
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unavailable: "Local speech recognition is unavailable."
            case .unsupportedFormat: "The call audio format is not supported."
            }
        }
    }

    private let speaker: Speaker
    private let locale: Locale
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var appendedBuffers = 0
    private var droppedBuffers = 0
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var onResult: (@Sendable (Speaker, String, Bool) -> Void)?

    init(speaker: Speaker, locale: Locale = .current) {
        self.speaker = speaker
        self.locale = locale
    }

    func start(
        onResult: @escaping @Sendable (Speaker, String, Bool) -> Void,
        onError: @escaping @Sendable (Speaker, String) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw LaneError.unavailable }
        self.onResult = onResult

        let selectedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: selectedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: selectedLocale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw LaneError.unsupportedFormat
        }
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.continuation = continuation
        }
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)

        self.targetFormat = format
        self.transcriber = transcriber
        self.analyzer = analyzer

        resultTask = Task { [speaker] in
            var lastVolatile: String?
            do {
                var results = 0
                for try await result in transcriber.results {
                    results += 1
                    if results == 1 { phoneDiagnosticLog("phone-app: \(speaker.title) transcriber produced its first result\n") }
                    let text = String(result.text.characters)
                    lastVolatile = result.isFinal ? nil : text
                    onResult(speaker, text, result.isFinal)
                }
                phoneDiagnosticLog("phone-app: \(speaker.title) transcriber finished after \(results) results\n")
            } catch {
                if !(error is CancellationError) {
                    onError(speaker, "Transcriber failed: \(error.localizedDescription)")
                }
            }
            if let lastVolatile {
                phoneDiagnosticLog("phone-app: \(speaker.title) transcriber persisted its last volatile result\n")
                onResult(speaker, lastVolatile, true)
            }
        }
        analysisTask = Task { [speaker] in
            do { try await analyzer.start(inputSequence: stream) }
            catch {
                if !(error is CancellationError) {
                    onError(speaker, "Speech analysis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func append(_ frame: AudioFrame) async {
        guard frame.speaker == speaker,
              let targetFormat,
              let inputFormat = AVAudioFormat(
                commonFormat: frame.format,
                sampleRate: frame.sampleRate,
                channels: frame.channels,
                interleaved: true
              ) else { return }

        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = AVAudioFrameCount(frame.samples.count / bytesPerFrame)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return }
        input.frameLength = frameCount
        frame.samples.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress, let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            memcpy(destination, source, frame.samples.count)
            input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(frame.samples.count)
        }

        if inputFormat == targetFormat {
            continuation?.yield(AnalyzerInput(buffer: input))
            noteAppended()
            return
        }

        if sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if status == .haveData || status == .inputRanDry, output.frameLength > 0 {
            continuation?.yield(AnalyzerInput(buffer: output))
            noteAppended()
        } else {
            droppedBuffers += 1
            if droppedBuffers == 1 || droppedBuffers % 2_500 == 0 {
                phoneDiagnosticLog("phone-app: \(speaker.title) lane dropped \(droppedBuffers) buffers (status \(status.rawValue), error: \(conversionError?.localizedDescription ?? "none"))\n")
            }
        }
    }

    private func noteAppended() {
        appendedBuffers += 1
        if appendedBuffers == 1 || appendedBuffers % 2_500 == 0 {
            phoneDiagnosticLog("phone-app: \(speaker.title) lane fed \(appendedBuffers) buffers to the analyzer (target \(Int(targetFormat?.sampleRate ?? 0)) Hz)\n")
        }
    }

    func stop() async {
        phoneDiagnosticLog("phone-app: \(speaker.title) lane stopping — appended \(appendedBuffers), dropped \(droppedBuffers)\n")
        appendedBuffers = 0
        droppedBuffers = 0
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        if let resultTask {
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                resultTask.cancel()
            }
            await resultTask.value
            timeoutTask.cancel()
        }
        analysisTask?.cancel()
        resultTask = nil
        analysisTask = nil
        continuation = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        sourceFormat = nil
    }
}


extension SpeechLane: TranscriptionLane {}
extension GeminiTranscribeLane: TranscriptionLane {}

func configuredTranscriptionLocale() -> Locale {
    if let identifier = UserDefaults.standard.string(forKey: "transcriptionLocale"), !identifier.isEmpty {
        return Locale(identifier: identifier)
    }
    return .current
}

actor LocalIntelligence {
    private var me: (any TranscriptionLane)?
    private var caller: (any TranscriptionLane)?

    func prepare() async throws {
        let requested = configuredTranscriptionEngine()
        let resolution = resolveTranscriptionEngine(
            requested: requested,
            geminiAPIKey: requested == .gemini ? GeminiAPIKeyStore.apiKey() : nil
        )
        if resolution.active == .gemini { return }
        if resolution.fellBackToApple {
            phoneDiagnosticLog("phone-app: Gemini transcription selected without an API key; falling back to Apple transcription\n")
        }

        guard SpeechTranscriber.isAvailable else { throw SpeechLane.LaneError.unavailable }
        let requestedLocale = configuredTranscriptionLocale()
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) ?? requestedLocale
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func start(
        onResult: @escaping @Sendable (Speaker, String, Bool) -> Void,
        onError: @escaping @Sendable (Speaker, String) -> Void
    ) async throws {
        await stop()
        let requested = configuredTranscriptionEngine()
        let apiKey = requested == .gemini ? GeminiAPIKeyStore.apiKey() : nil
        let resolution = resolveTranscriptionEngine(requested: requested, geminiAPIKey: apiKey)
        let me: any TranscriptionLane
        let caller: any TranscriptionLane

        switch resolution.active {
        case .apple:
            if resolution.fellBackToApple {
                phoneDiagnosticLog("phone-app: Gemini transcription selected without an API key; falling back to Apple transcription\n")
            }
            let locale = configuredTranscriptionLocale()
            phoneDiagnosticLog("phone-app: Apple transcription locale: \(locale.identifier)\n")
            me = SpeechLane(speaker: .me, locale: locale)
            caller = SpeechLane(speaker: .caller, locale: locale)
        case .gemini:
            let key = apiKey ?? ""
            let smartMode = UserDefaults.standard.bool(forKey: "transcriptionSmartMode")
            phoneDiagnosticLog("phone-app: Gemini cloud transcription selected (\(smartMode ? "SMART" : "VERBATIM"))\n")
            me = GeminiTranscribeLane(speaker: .me, apiKey: key, smartMode: smartMode)
            caller = GeminiTranscribeLane(speaker: .caller, apiKey: key, smartMode: smartMode)
        }

        self.me = me
        self.caller = caller
        do {
            try await me.start(onResult: onResult, onError: onError)
            try await caller.start(onResult: onResult, onError: onError)
        } catch {
            await me.stop()
            await caller.stop()
            self.me = nil
            self.caller = nil
            throw error
        }
    }

    func append(_ frame: AudioFrame) async {
        if frame.speaker == .me { await me?.append(frame) }
        else { await caller?.append(frame) }
    }

    func stop() async {
        await me?.stop()
        await caller?.stop()
        me = nil
        caller = nil
    }


    func summarize(entries: [TranscriptEntry], assistantTask: String? = nil) async throws -> String {
        let transcript = entries
            .filter { $0.isFinal && !$0.text.isEmpty }
            .map { "\($0.speakerTitle): \($0.text)" }
            .joined(separator: "\n")
        guard !transcript.isEmpty else { return "There is no transcript for this call yet." }
        let prompt = assistantTask.map { assistantCallSummaryPrompt(task: $0, transcript: transcript) }
            ?? callSummaryPrompt(transcript: transcript)

        let model = SystemLanguageModel.default
        if model.isAvailable {
            let session = LanguageModelSession(instructions: callSummaryInstructions)
            do {
                return try await session.respond(to: prompt).content
            } catch {
                phoneDiagnosticLog("phone-app: local summary failed, trying Gemini — Foundation Models error: \(String(describing: error))\n")
            }
        } else {
            phoneDiagnosticLog("phone-app: local summary unavailable, trying Gemini — Foundation Models availability: \(String(describing: model.availability))\n")
        }
        if let apiKey = GeminiAPIKeyStore.apiKey() {
            do {
                return try await geminiSummary(prompt: prompt, apiKey: apiKey)
            } catch {
                phoneDiagnosticLog("phone-app: using fallback summary — Gemini summary error: \(redactSensitiveValues(in: String(describing: error)))\n")
            }
        } else {
            phoneDiagnosticLog("phone-app: using fallback summary — no Gemini API key configured\n")
        }
        return fallbackCallSummary(entries)
    }

    private func geminiSummary(prompt: String, apiKey: String) async throws -> String {
        let model = UserDefaults.standard.string(forKey: "geminiSummaryModel") ?? "gemini-3.6-flash"
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": callSummaryInstructions]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GeminiSummary", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "GeminiSummary", code: 0, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let callSummaryInstructions = """
Du fasst Telefongespräche kurz, sachlich und immer auf Deutsch zusammen. Erfinde nichts und erzähle den Dialog nicht nach. Das konkrete Anliegen des Anrufers ist die wichtigste Information.
"""

func callSummaryPrompt(transcript: String) -> String {
    """
    Erstelle eine kurze, sachliche Zusammenfassung auf Deutsch. Sie muss immer in dieser Reihenfolge enthalten:
    1. Wer hat angerufen und für wen war der Anruf bestimmt? Falls unbekannt, ausdrücklich „nicht genannt“ schreiben.
    2. WAS DER ANRUFER WOLLTE: das konkrete Anliegen klar und vorrangig nennen. Falls unklar, ausdrücklich „nicht eindeutig genannt“ schreiben.
    3. Hinterlassene Daten: Name, Rückrufnummer und Termine. Fehlende Daten knapp als „nicht genannt“ kennzeichnen.
    4. Vereinbarte nächste Schritte. Falls keine vereinbart wurden, „keine vereinbart“ schreiben.

    Keine Dialognacherzählung, keine Einleitung und keine Spekulation. Verwende höchstens vier kurze Sätze oder vier knappe Punkte.

    Transkript:
    \(transcript)
    """
}

func assistantCallSummaryPrompt(task: String, transcript: String) -> String {
    """
    Unser KI-Assistent hat in diesem Telefonat im Auftrag des Nutzers angerufen. Der Auftrag lautete: „\(task)“

    Erstelle eine kurze, sachliche Zusammenfassung auf Deutsch. Sie muss immer in dieser Reihenfolge enthalten:
    1. ERGEBNIS: Wurde der Auftrag erledigt? Klar mit „Erledigt“, „Teilweise erledigt“ oder „Nicht erledigt“ beginnen und das konkrete Ergebnis nennen (z. B. was bestellt oder vereinbart wurde).
    2. Wichtige Details: Preise, Zeiten, Namen, Orte — nur was tatsächlich genannt wurde.
    3. Nächste Schritte für den Nutzer (z. B. abholen, zurückrufen). Falls keine, „keine“ schreiben.

    Keine Dialognacherzählung, keine Einleitung und keine Spekulation. Verwende höchstens vier kurze Sätze oder knappe Punkte.

    Transkript:
    \(transcript)
    """
}

func fallbackCallSummary(_ entries: [TranscriptEntry]) -> String {
    let prefix = "(Ohne KI-Zusammenfassung) "
    let final = entries.filter { $0.isFinal && !$0.text.isEmpty }
    guard !final.isEmpty else { return prefix + "There is no transcript for this call yet." }
    return prefix + final.suffix(6).map { "\($0.speakerTitle): \($0.text)" }.joined(separator: "\n")
}
