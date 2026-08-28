import Foundation
import Testing
@testable import Phone

@Test func buildsPTAIAudioInjectionPacket() {
    let samples = Data([0x01, 0x02, 0x03, 0x04])
    let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: 8_000)

    #expect(Array(packet.prefix(4)) == [0x50, 0x54, 0x41, 0x49])
    #expect(Array(packet[4..<8]) == [1, Speaker.me.rawValue, 1, 1])
    #expect(Array(packet[8..<12]) == [0x40, 0x1f, 0x00, 0x00])
    #expect(Array(packet[12..<16]) == [0x04, 0x00, 0x00, 0x00])
    #expect(packet.dropFirst(16) == samples)
}

@Test func encodesGeminiSetupWithSystemInstruction() throws {
    let message = try GeminiLiveProtocol.setupMessage(
        model: "gemini-live-test",
        instructions: "  Sei kurz und freundlich.  "
    )
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let setup = try #require(root["setup"] as? [String: Any])
    let systemInstruction = try #require(setup["systemInstruction"] as? [String: Any])
    let parts = try #require(systemInstruction["parts"] as? [[String: Any]])

    #expect(setup["model"] as? String == "models/gemini-live-test")
    #expect(parts.first?["text"] as? String == "Sei kurz und freundlich.")
    #expect(setup["inputAudioTranscription"] as? [String: Any] != nil)
    #expect(setup["outputAudioTranscription"] as? [String: Any] != nil)
}

@Test func composesAssistantCallInstructions() {
    #expect(
        assistantCallInstructions(general: "Allgemeine Anweisung", task: "Termin vereinbaren") ==
        "Allgemeine Anweisung\n\nAuftrag für diesen Anruf:\nTermin vereinbaren"
    )
    #expect(
        assistantCallInstructions(general: "", task: "Termin vereinbaren") ==
        "Auftrag für diesen Anruf:\nTermin vereinbaren"
    )
    #expect(assistantCallInstructions(general: "Allgemeine Anweisung", task: "") == "Allgemeine Anweisung")
}

@Test func clearsPendingAssistantCallOnFailure() {
    var plan = AssistantCallPlan()
    plan.begin(task: "Termin vereinbaren")

    #expect(plan.isPending)
    #expect(plan.isActive)

    plan.callFailed()

    #expect(!plan.isPending)
    #expect(!plan.isActive)
}

@Test func omitsEmptyGeminiSystemInstruction() throws {
    let message = try GeminiLiveProtocol.setupMessage(model: "models/gemini-live-test", instructions: "  \n ")
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let setup = try #require(root["setup"] as? [String: Any])

    #expect(setup["model"] as? String == "models/gemini-live-test")
    #expect(setup["systemInstruction"] == nil)
}

@Test func encodesGeminiGreetingClientContent() throws {
    let message = try GeminiLiveProtocol.greetingMessage()
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let clientContent = try #require(root["clientContent"] as? [String: Any])
    let turns = try #require(clientContent["turns"] as? [[String: Any]])
    let turn = try #require(turns.first)
    let parts = try #require(turn["parts"] as? [[String: Any]])

    #expect(turn["role"] as? String == "user")
    #expect(parts.first?["text"] as? String == assistantGreetingTrigger)
    #expect(clientContent["turnComplete"] as? Bool == true)
}

@Test func encodesGeminiRealtimeAudioChunk() throws {
    let pcm = Data([0x00, 0x01, 0x02, 0x03])
    let message = try GeminiLiveProtocol.realtimeInputMessage(pcm: pcm)
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let realtimeInput = try #require(root["realtimeInput"] as? [String: Any])
    let audio = try #require(realtimeInput["audio"] as? [String: Any])

    #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
    #expect(audio["data"] as? String == pcm.base64EncodedString())
}

@Test func decodesGeminiServerAudioFraming() throws {
    let first = Data([1, 2, 3, 4])
    let second = Data([5, 6, 7, 8])
    let object: [String: Any] = [
        "setupComplete": [:],
        "serverContent": [
            "turnComplete": true,
            "inputTranscription": ["text": "Ich brauche einen Termin."],
            "outputTranscription": ["text": "Gern, wann passt es?"],
            "modelTurn": [
                "parts": [
                    ["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": first.base64EncodedString()]],
                    ["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": second.base64EncodedString()]]
                ]
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let message = try #require(GeminiLiveProtocol.decodeServerMessage(data))

    #expect(message.setupComplete)
    #expect(message.audioChunks == [first, second])
    #expect(message.turnComplete)
    #expect(message.inputTranscription == "Ich brauche einen Termin.")
    #expect(message.outputTranscription == "Gern, wann passt es?")
}

@Test func buffersGeminiTranscriptionUntilSpeakerAndTurnBoundaries() {
    var buffer = GeminiTranscriptionBuffer()

    #expect(buffer.receive(inputTranscription: "Ich brauche", outputTranscription: nil, turnComplete: false).isEmpty)
    #expect(buffer.receive(inputTranscription: " einen Termin", outputTranscription: nil, turnComplete: false).isEmpty)

    let speakerSwitch = buffer.receive(
        inputTranscription: nil,
        outputTranscription: "Gern",
        turnComplete: false
    )
    #expect(speakerSwitch == [
        GeminiTranscriptUtterance(speaker: .caller, text: "Ich brauche einen Termin")
    ])

    let turnComplete = buffer.receive(
        inputTranscription: nil,
        outputTranscription: ", ich rufe zurück.",
        turnComplete: true
    )
    #expect(turnComplete == [
        GeminiTranscriptUtterance(speaker: .me, text: "Gern, ich rufe zurück.")
    ])
}

@Test func summaryPromptPrioritizesCallerIntentAndFallbackIsMarked() {
    let prompt = callSummaryPrompt(transcript: "Caller: Ich brauche am Dienstag einen Termin.")

    #expect(prompt.contains("Wer hat angerufen"))
    #expect(prompt.contains("WAS DER ANRUFER WOLLTE"))
    #expect(prompt.contains("Name, Rückrufnummer und Termine"))
    #expect(prompt.contains("Vereinbarte nächste Schritte"))
    #expect(prompt.contains("Keine Dialognacherzählung"))
    #expect(callSummaryInstructions.contains("immer auf Deutsch"))

    let fallback = fallbackCallSummary([
        TranscriptEntry(
            speaker: .caller,
            text: "Ich brauche am Dienstag einen Termin.",
            isFinal: true,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    ])
    #expect(fallback.hasPrefix("(Ohne KI-Zusammenfassung) "))
    #expect(fallback.contains("Ich brauche am Dienstag einen Termin."))
}

@Test func assistantCallSummaryPromptLeadsWithOutcome() {
    let prompt = assistantCallSummaryPrompt(task: "Bestelle eine Pizza Thunfisch", transcript: "Assistant: Hallo.")
    #expect(prompt.contains("Bestelle eine Pizza Thunfisch"))
    #expect(prompt.contains("ERGEBNIS"))
    #expect(prompt.contains("Nächste Schritte"))
    #expect(prompt.contains("Keine Dialognacherzählung"))
}

@Test func resamplesGeminiAudioFrom24kTo8k() {
    let sourceRate = 24_000
    let targetRate = 8_000
    let sampleCount = sourceRate / 10
    let samples = (0..<sampleCount).map { index in
        Int16((sin(2 * Double.pi * 1_000 * Double(index) / Double(sourceRate)) * 12_000).rounded())
    }
    let input = pcmData(samples)
    let resampler = PCM16MonoResampler()
    var output = Data()
    let chunkSize = sourceRate / 50 * MemoryLayout<Int16>.size
    for offset in stride(from: 0, to: input.count, by: chunkSize) {
        output.append(resampler.resample(input.subdata(in: offset..<min(offset + chunkSize, input.count)), from: sourceRate, to: targetRate))
    }
    let outputSamples = pcmSamples(output)
    let rms = sqrt(outputSamples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(outputSamples.count))

    #expect(outputSamples.count == targetRate / 10)
    #expect(rms > 7_000 && rms < 10_000)
    #expect(outputSamples.map { abs(Int($0)) }.max() ?? 0 < 16_000)
}

@Test func preserves16kPCMWithoutResampling() {
    let input = pcmData([Int16.min, -1_000, 0, 1_000, Int16.max])
    let output = PCM16MonoResampler().resample(input, from: 16_000, to: 16_000)

    #expect(output == input)
}

@Test func builds20ms16kAudioInjectionPacket() {
    let samples = Data(repeating: 0, count: 16_000 / 50 * MemoryLayout<Int16>.size)
    let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: 16_000)

    #expect(samples.count == 640)
    #expect(Array(packet[8..<12]) == [0x80, 0x3e, 0x00, 0x00])
    #expect(Array(packet[12..<16]) == [0x80, 0x02, 0x00, 0x00])
}

private func pcmData(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        var value = UInt16(bitPattern: sample).littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
}

private func pcmSamples(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count - 1, by: 2).map { offset in
        Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
    }
}

@Test func encodesExternalBrainSetupMessage() throws {
    let message = try BrainLiveProtocol.setupMessage(
        model: "gemini-live-test",
        instructions: "Be concise.",
        greeting: true
    )
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])

    #expect(root["type"] as? String == "setup")
    #expect(root["instructions"] as? String == "Be concise.")
    #expect(root["greeting"] as? Bool == true)
    #expect(root["model"] as? String == "gemini-live-test")
}

@Test func selectsExternalBrainOnlyForValidWebSocketURLs() throws {
    #expect(resolveAssistantLiveEndpoint(nil) == .gemini)
    #expect(resolveAssistantLiveEndpoint("") == .gemini)
    #expect(resolveAssistantLiveEndpoint("not a URL") == .gemini)
    #expect(resolveAssistantLiveEndpoint("https://127.0.0.1:8791") == .gemini)
    #expect(
        resolveAssistantLiveEndpoint(" ws://127.0.0.1:8791 ") ==
        .brain(try #require(URL(string: "ws://127.0.0.1:8791")))
    )
}

@Test func decodesExternalBrainStateMessages() throws {
    let live = try #require(BrainLiveProtocol.decodeServerMessage(Data(#"{"type":"state","value":"live"}"#.utf8)))
    let failed = try #require(BrainLiveProtocol.decodeServerMessage(Data(#"{"type":"state","value":"failed","message":"offline"}"#.utf8)))

    #expect(live == .state(.live))
    #expect(failed == .state(.failed("offline")))
}
