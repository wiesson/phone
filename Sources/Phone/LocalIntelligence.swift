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
            case .unavailable: "Lokale Spracherkennung ist nicht verfügbar."
            case .unsupportedFormat: "Das Anruf-Audioformat wird nicht unterstützt."
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
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var onResult: (@Sendable (Speaker, String, Bool) -> Void)?

    init(speaker: Speaker, locale: Locale = Locale(identifier: "de-DE")) {
        self.speaker = speaker
        self.locale = locale
    }

    func start(onResult: @escaping @Sendable (Speaker, String, Bool) -> Void) async throws {
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
                for try await result in transcriber.results {
                    onResult(speaker, String(result.text.characters), result.isFinal)
                }
            } catch { }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { }
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
        }
    }

    func stop() async {
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
        let requested = Locale(identifier: "de-DE")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func start(onResult: @escaping @Sendable (Speaker, String, Bool) -> Void) async throws {
        try await me.start(onResult: onResult)
        do {
            try await caller.start(onResult: onResult)
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
        guard !transcript.isEmpty else { return "Für diesen Anruf liegt noch kein Transkript vor." }

        let session = LanguageModelSession(instructions: "Du fasst Telefonate knapp, sachlich und auf Deutsch zusammen. Erfinde nichts.")
        let response = try await session.respond(to: """
        Fasse das folgende Telefonat in höchstens vier kurzen Sätzen zusammen. Ergänze danach nur dann die Überschrift „Nächste Schritte“, wenn konkrete Aufgaben, Termine oder Zusagen genannt wurden.

        \(transcript)
        """)
        return response.content
    }

    private func fallbackSummary(_ entries: [TranscriptEntry]) -> String {
        let final = entries.filter { $0.isFinal && !$0.text.isEmpty }
        guard !final.isEmpty else { return "Für diesen Anruf liegt noch kein Transkript vor." }
        return final.suffix(6).map { "\($0.speaker.title): \($0.text)" }.joined(separator: "\n")
    }
}
