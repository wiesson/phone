# Apple-ML-Implementierung (macOS 26)

Geprüft gegen die lokal installierten Interfaces aus Xcode/macOS SDK 26.5:

- `Speech.framework/.../Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
- `FoundationModels.framework/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
- Swift 6.3.3, Target `arm64-apple-macosx26.0`

Alle hier verwendeten neuen APIs sind ab macOS 26.0 verfügbar.

## Minimales kompilierbares Skelett

Die beiden PCM-Quellen müssen bereits getrennt vorliegen, beispielsweise lokales Mikrofon und entfernter Gesprächskanal. Jede Quelle erhält einen eigenen `SpeechTranscriber` und `SpeechAnalyzer`; PCM-Puffer eines Streams dürfen dasselbe Format haben wie das an `prepareToAnalyze(in:)` übergebene Format.

```swift
import AVFAudio
import Foundation
import FoundationModels
import Speech

@available(macOS 26.0, *)
final class PCMTranscriptionStream: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer

    init(locale: Locale) {
        transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func run(
        pcm: AsyncStream<AVAudioPCMBuffer>,
        audioFormat: AVAudioFormat,
        onResult: @escaping @Sendable (SpeechTranscriber.Result) async -> Void
    ) async throws {
        try await analyzer.prepareToAnalyze(in: audioFormat)

        async let consume: Void = consumeResults(onResult)

        let inputs = AsyncStream<AnalyzerInput> { continuation in
            Task {
                for await buffer in pcm {
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
                continuation.finish()
            }
        }

        try await analyzer.start(inputSequence: inputs)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await consume
    }

    private func consumeResults(
        _ onResult: @escaping @Sendable (SpeechTranscriber.Result) async -> Void
    ) async throws {
        for try await result in transcriber.results {
            await onResult(result)
        }
    }
}

@available(macOS 26.0, *)
struct TwoPartyTranscription {
    let local: PCMTranscriptionStream
    let remote: PCMTranscriptionStream

    init(locale: Locale) {
        local = PCMTranscriptionStream(locale: locale)
        remote = PCMTranscriptionStream(locale: locale)
    }

    func run(
        localPCM: AsyncStream<AVAudioPCMBuffer>,
        localFormat: AVAudioFormat,
        remotePCM: AsyncStream<AVAudioPCMBuffer>,
        remoteFormat: AVAudioFormat,
        onLocal: @escaping @Sendable (SpeechTranscriber.Result) async -> Void,
        onRemote: @escaping @Sendable (SpeechTranscriber.Result) async -> Void
    ) async throws {
        async let localRun: Void = local.run(
            pcm: localPCM,
            audioFormat: localFormat,
            onResult: onLocal
        )
        async let remoteRun: Void = remote.run(
            pcm: remotePCM,
            audioFormat: remoteFormat,
            onResult: onRemote
        )
        _ = try await (localRun, remoteRun)
    }
}

@available(macOS 26.0, *)
@Generable(description: "Structured summary of a two-party phone call")
struct CallSummary {
    @Guide(description: "Brief factual summary")
    var summary: String

    @Guide(description: "Decisions made during the call")
    var decisions: [String]

    @Guide(description: "Concrete follow-up tasks")
    var actionItems: [String]
}

@available(macOS 26.0, *)
enum CallSummaryError: Error {
    case modelUnavailable(SystemLanguageModel.Availability)
}

@available(macOS 26.0, *)
func summarizeCall(transcriptWithSpeakerLabels: String) async throws -> CallSummary {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        throw CallSummaryError.modelUnavailable(model.availability)
    }

    let session = LanguageModelSession(
        model: model,
        instructions: "Summarize only facts present in the transcript."
    )
    let response = try await session.respond(
        to: "Create a call summary from this speaker-labeled transcript:\n\n\(transcriptWithSpeakerLabels)",
        generating: CallSummary.self
    )
    return response.content
}
```

`SpeechTranscriber.Result.text` ist ein `AttributedString`; `Result.range` ist ein `CMTimeRange`, `Result.isFinal` kommt von `SpeechModuleResult`. Für die Zusammenfassung sollten die beiden Ergebnisfolgen anhand der Zeitbereiche zusammengeführt und mit stabilen Sprecherbezeichnungen versehen werden. Bei `.progressiveTranscription` können volatile Resultate ersetzt werden; persistiert werden sollten nur finale Resultate oder eine explizit gepflegte Revision.

## Speech-Assets und Verfügbarkeit

Vor Erzeugung der Streams:

1. `SpeechTranscriber.isAvailable` prüfen.
2. Mit `await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)` eine tatsächlich unterstützte `Locale` bestimmen; alternativ `supportedLocales` beziehungsweise `installedLocales` lesen.
3. Pro Locale einen `SpeechTranscriber` erzeugen und für `[transcriber]` `await AssetInventory.status(forModules:)` prüfen. Mögliche Werte: `.unsupported`, `.supported`, `.downloading`, `.installed`.
4. Falls nötig: `try await AssetInventory.assetInstallationRequest(supporting:)`; liefert dies einen `AssetInstallationRequest`, `try await request.downloadAndInstall()` ausführen. Fortschritt steht in `request.progress` (`Progress`).
5. Optional hält `try await AssetInventory.reserve(locale:)` ein Locale-Asset vor; Limits und Zustand liefern `maximumReservedLocales` und `reservedLocales`. Später mit `release(reservedLocale:)` freigeben.
6. Das konkrete PCM-Format kann auch mit `await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` gewählt werden. `prepareToAnalyze(in:)` muss vor `start(inputSequence:)` laufen.

`AnalyzerInput` wird konkret mit `init(buffer: AVAudioPCMBuffer)` oder `init(buffer:bufferStartTime:)` erzeugt. Am Eingabeende beendet `finalizeAndFinishThroughEndOfInput()` Analyse und Result-Sequence. Für Abbruch existiert `cancelAndFinishNow()`.

## Permissions

`SpeechAnalyzer` konsumiert PCM und öffnet selbst kein Aufnahmegerät. Berechtigungen hängen daher von der PCM-Quelle ab:

- Mikrofon: `NSMicrophoneUsageDescription` in `Info.plist`; Status über `AVCaptureDevice.authorizationStatus(for: .audio)`, Anfrage über `await AVCaptureDevice.requestAccess(for: .audio)`.
- Speech Recognition: `NSSpeechRecognitionUsageDescription`; Status/Anfrage über `SFSpeechRecognizer.authorizationStatus()` und `SFSpeechRecognizer.requestAuthorization(_:)`. Vor Produktivbetrieb auf dem Zielsystem testen, auch wenn ausschließlich lokale Analyzer-Assets genutzt werden.
- System-/Anwendungs-Audio über ScreenCaptureKit: Benutzerfreigabe für Bildschirm-/Systemaudio-Aufnahme ist separat und wird von der Capture-Schicht ausgelöst; der hier gezeigte PCM-Consumer fordert sie nicht an.

Berechtigungsfehler der Aufnahme dürfen nicht mit fehlenden Speech-Assets verwechselt werden.

## FoundationModels-Verfügbarkeit

`SystemLanguageModel.default.availability` liefert:

- `.available`
- `.unavailable(.deviceNotEligible)`
- `.unavailable(.appleIntelligenceNotEnabled)`
- `.unavailable(.modelNotReady)`

`isAvailable` ist die Bool-Kurzform. FoundationModels stellt keinen App-seitigen Asset-Download wie `Speech.AssetInventory` bereit; bei `.modelNotReady` muss die UI warten beziehungsweise später erneut prüfen. Die strukturierte Ausgabe entsteht lokal über `LanguageModelSession.respond(to:generating:)` und den durch `@Generable` erzeugten Schema-Typ. Relevante Laufzeitfehler sind unter anderem `LanguageModelSession.GenerationError.assetsUnavailable`, `.unsupportedLanguageOrLocale`, `.exceededContextWindowSize`, `.guardrailViolation`, `.rateLimited` und `.refusal`.

Für lange Calls das Transkript vorab segmentieren oder hierarchisch zusammenfassen, da `exceededContextWindowSize` konkret auftreten kann. Keine Audio- oder Transkriptdaten müssen für diese APIs an einen eigenen Server gesendet werden; die Capture- und Persistenzschicht bleibt dennoch für Datenschutz, Einwilligung und Aufbewahrung verantwortlich.
