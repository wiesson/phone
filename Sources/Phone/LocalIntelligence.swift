import AVFoundation
import Foundation
import FoundationModels
import Speech

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
            do {
                var results = 0
                for try await result in transcriber.results {
                    results += 1
                    if results == 1 { phoneDiagnosticLog("phone-app: \(speaker.title) transcriber produced its first result\n") }
                    onResult(speaker, String(result.text.characters), result.isFinal)
                }
                phoneDiagnosticLog("phone-app: \(speaker.title) transcriber finished after \(results) results\n")
            } catch {
                if !(error is CancellationError) {
                    onError(speaker, "Transcriber failed: \(error.localizedDescription)")
                }
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

    func append(_ frame: AudioFrame) {
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
        if status == .haveData, output.frameLength > 0 {
            continuation?.yield(AnalyzerInput(buffer: output))
            noteAppended()
        } else {
            droppedBuffers += 1
            if droppedBuffers == 1 || droppedBuffers % 250 == 0 {
                phoneDiagnosticLog("phone-app: \(speaker.title) lane dropped \(droppedBuffers) buffers (status \(status.rawValue), error: \(conversionError?.localizedDescription ?? "none"))\n")
            }
        }
    }

    private func noteAppended() {
        appendedBuffers += 1
        if appendedBuffers == 1 || appendedBuffers % 250 == 0 {
            phoneDiagnosticLog("phone-app: \(speaker.title) lane fed \(appendedBuffers) buffers to the analyzer (target \(Int(targetFormat?.sampleRate ?? 0)) Hz)\n")
        }
    }

    func stop() async {
        phoneDiagnosticLog("phone-app: \(speaker.title) lane stopping — appended \(appendedBuffers), dropped \(droppedBuffers)\n")
        appendedBuffers = 0
        droppedBuffers = 0
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultTask?.cancel()
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

actor LocalIntelligence {
    private let me = SpeechLane(speaker: .me)
    private let caller = SpeechLane(speaker: .caller)

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechLane.LaneError.unavailable }
        let requested = Locale.current
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
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
        try await me.start(onResult: onResult, onError: onError)
        do {
            try await caller.start(onResult: onResult, onError: onError)
        } catch {
            await me.stop()
            throw error
        }
    }

    func append(_ frame: AudioFrame) async {
        if frame.speaker == .me { await me.append(frame) }
        else { await caller.append(frame) }
    }

    func stop() async {
        await me.stop()
        await caller.stop()
    }

    func summarize(entries: [TranscriptEntry]) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            return fallbackSummary(entries)
        }
        let transcript = entries
            .filter { $0.isFinal && !$0.text.isEmpty }
            .map { "\($0.speaker.title): \($0.text)" }
            .joined(separator: "\n")
        guard !transcript.isEmpty else { return "There is no transcript for this call yet." }

        let session = LanguageModelSession(instructions: "You summarize phone calls concisely and factually, in the language of the conversation. Do not invent anything.")
        let response = try await session.respond(to: """
        Summarize the following phone call in at most four short sentences, in the language of the conversation. Only add a "Next steps" heading afterwards if concrete tasks, dates, or commitments were mentioned.

        \(transcript)
        """)
        return response.content
    }

    private func fallbackSummary(_ entries: [TranscriptEntry]) -> String {
        let final = entries.filter { $0.isFinal && !$0.text.isEmpty }
        guard !final.isEmpty else { return "There is no transcript for this call yet." }
        return final.suffix(6).map { "\($0.speaker.title): \($0.text)" }.joined(separator: "\n")
    }
}
