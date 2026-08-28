import Foundation
import Testing
@testable import Phone

@Test func encodesGeminiTranscribeSetupInVerbatimMode() throws {
    let message = try GeminiTranscribeProtocol.setupMessage(
        smartMode: false,
        languageCodes: []
    )
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let setup = try #require(root["setup"] as? [String: Any])
    let generationConfig = try #require(setup["generationConfig"] as? [String: Any])
    let transcription = try #require(setup["inputAudioTranscription"] as? [String: Any])

    #expect(setup["model"] as? String == "models/gemini-3.5-transcribe-live")
    #expect(generationConfig["responseModalities"] as? [String] == ["TEXT"])
    #expect(transcription["languageCodes"] as? [String] == [])
    #expect(transcription["mode"] == nil)
}

@Test func encodesGeminiTranscribeSetupInSmartModeWithLanguages() throws {
    let message = try GeminiTranscribeProtocol.setupMessage(
        smartMode: true,
        languageCodes: ["de-DE", "en-US"]
    )
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let setup = try #require(root["setup"] as? [String: Any])
    let transcription = try #require(setup["inputAudioTranscription"] as? [String: Any])

    #expect(transcription["languageCodes"] as? [String] == ["de-DE", "en-US"])
    #expect(transcription["mode"] as? String == "SMART")
}

@Test func decodesGeminiTranscribeInterimAndFinalResults() throws {
    let interim = try #require(GeminiTranscribeProtocol.decodeServerMessage(Data(
        #"{"serverContent":{"interimInputTranscription":{"text":"Guten Mor"}}}"#.utf8
    )))
    let final = try #require(GeminiTranscribeProtocol.decodeServerMessage(Data(
        #"{"serverContent":{"inputTranscription":{"text":"Guten Morgen"}}}"#.utf8
    )))

    #expect(interim.results == [GeminiTranscribeResult(text: "Guten Mor", isFinal: false)])
    #expect(final.results == [GeminiTranscribeResult(text: "Guten Morgen", isFinal: true)])
}

@Test func encodesGeminiTranscribeAudioStreamEnd() throws {
    let message = try GeminiTranscribeProtocol.audioStreamEndMessage()
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let input = try #require(root["realtimeInput"] as? [String: Any])

    #expect(input["audioStreamEnd"] as? Bool == true)
}

@Test func resolvesTranscriptionEngineAndMissingKeyFallback() {
    #expect(resolveTranscriptionEngine(requested: .apple, geminiAPIKey: nil).active == .apple)
    #expect(resolveTranscriptionEngine(requested: .gemini, geminiAPIKey: "api-key").active == .gemini)

    let missing = resolveTranscriptionEngine(requested: .gemini, geminiAPIKey: nil)
    let blank = resolveTranscriptionEngine(requested: .gemini, geminiAPIKey: "  \n ")
    #expect(missing.active == .apple)
    #expect(missing.fellBackToApple)
    #expect(blank.active == .apple)
    #expect(blank.fellBackToApple)
}

@Test func defaultsUnknownTranscriptionEngineToApple() throws {
    let suiteName = "GeminiTranscribeLaneTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(configuredTranscriptionEngine(defaults: defaults) == .apple)
    defaults.set("gemini", forKey: "transcriptionEngine")
    #expect(configuredTranscriptionEngine(defaults: defaults) == .gemini)
    defaults.set("unknown", forKey: "transcriptionEngine")
    #expect(configuredTranscriptionEngine(defaults: defaults) == .apple)
}

@Test func redactsGeminiAPIKeyFromErrors() {
    let error = "socket failed at wss://example.test/live?key=super-secret_key&alt=ws"
    #expect(!redactSensitiveValues(in: error).contains("super-secret_key"))
    #expect(redactSensitiveValues(in: error).contains("key=••••"))
}
