import AVFoundation
import Foundation
import Testing
@testable import Phone

@Test func buildsPTAIAudioInjectionPacket() {
    let samples = Data([0x01, 0x02, 0x03, 0x04])
    let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: 8_000, channels: 1)

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

@Test func encodesGeminiToolDeclarations() throws {
    let message = try GeminiLiveProtocol.setupMessage(model: "gemini-live-test", instructions: "Handle the call.")
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let setup = try #require(root["setup"] as? [String: Any])
    let tools = try #require(setup["tools"] as? [[String: Any]])
    let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])

    #expect(declarations.map { $0["name"] as? String } == ["send_dtmf", "handover_to_user"])
    let dtmf = try #require(declarations.first)
    let parameters = try #require(dtmf["parameters"] as? [String: Any])
    let properties = try #require(parameters["properties"] as? [String: Any])
    let digit = try #require(properties["digit"] as? [String: Any])
    #expect(digit["enum"] as? [String] == ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"])
    #expect(parameters["required"] as? [String] == ["digit"])
}

@Test func composesAssistantCallInstructions() {
    let named = assistantCallInstructions(
        general: "Allgemeine Anweisung",
        task: "Termin vereinbaren",
        userDisplayName: "  Arne  "
    )
    #expect(named.contains("Allgemeine Anweisung\n\nAuftrag für diesen Anruf:\nTermin vereinbaren"))
    #expect(named.contains("send_dtmf"))
    #expect(named.contains("Warteschleifen geduldig"))
    #expect(named.contains("Ich verbinde Sie mit Arne."))
    #expect(named.contains("handover_to_user"))

    let unnamed = assistantCallInstructions(general: "", task: "Termin vereinbaren")
    #expect(unnamed.contains("Auftrag für diesen Anruf:\nTermin vereinbaren"))
    #expect(unnamed.contains("Ich verbinde Sie jetzt."))
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
    #expect(message.toolCalls.isEmpty)
}

@Test func decodesGeminiToolCalls() throws {
    let data = Data(#"{"toolCall":{"functionCalls":[{"id":"call-123","name":"send_dtmf","args":{"digit":"7","nested":{"wait":true}}},{"id":"call-456","name":"handover_to_user","args":{}}]}}"#.utf8)
    let message = try #require(GeminiLiveProtocol.decodeServerMessage(data))

    #expect(message.toolCalls.count == 2)
    #expect(message.toolCalls[0].id == "call-123")
    #expect(message.toolCalls[0].name == "send_dtmf")
    #expect(message.toolCalls[0].arguments["digit"] == .string("7"))
    #expect(message.toolCalls[0].arguments["nested"] == .object(["wait": .bool(true)]))
    #expect(message.toolCalls[1] == GeminiToolCall(id: "call-456", name: "handover_to_user", arguments: [:]))
}

@Test func encodesGeminiToolResponse() throws {
    let call = GeminiToolCall(id: "call-123", name: "send_dtmf", arguments: ["digit": .string("5")])
    let message = try GeminiLiveProtocol.toolResponseMessage(for: call)
    let root = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
    let toolResponse = try #require(root["toolResponse"] as? [String: Any])
    let responses = try #require(toolResponse["functionResponses"] as? [[String: Any]])
    let response = try #require(responses.first)

    #expect(response["id"] as? String == "call-123")
    #expect(response["name"] as? String == "send_dtmf")
    #expect((response["response"] as? [String: String])?["result"] == "ok")
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

    // The prompt must ask for exactly the labels the parser understands, or
    // summaries silently fall back to unstructured text.
    for field in [CallSummaryField.caller, .request, .callbackNumber, .nextSteps] {
        #expect(prompt.contains("\(field.label):"))
    }
    #expect(prompt.contains("Wer hat angerufen"))
    #expect(prompt.contains("Dialognacherzählung"))
    #expect(prompt.contains("Kein Markdown"))
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
    for field in [CallSummaryField.outcome, .details, .nextSteps] {
        #expect(prompt.contains("\(field.label):"))
    }
    #expect(prompt.contains("Erledigt"))
    #expect(prompt.contains("Dialognacherzählung"))
    #expect(prompt.contains("Kein Markdown"))
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
    let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: 16_000, channels: 1)

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

@Test func parsesALabelledSummaryIntoFields() {
    let sections = parseCallSummary("""
    Anrufer: Frau Meier für die Praxis.
    Anliegen: Möchte den Termin am Dienstag verschieben.
    Rückrufnummer: 0211 1234567
    Nächste Schritte: Praxis ruft am Montag zurück.
    """)

    #expect(sections.map(\.field) == [.caller, .request, .callbackNumber, .nextSteps])
    #expect(sections[1].value == "Möchte den Termin am Dienstag verschieben.")
    #expect(sections[2].label == "Rückrufnummer")
}

@Test func parsingSurvivesTheMarkdownAModelAddsAnyway() {
    let sections = parseCallSummary("""
    1. **Anrufer:** Nicht genannt
    2. **Anliegen:** Erkundigen sich nach Reiseangeboten in Afrika
    """)

    #expect(sections.map(\.field) == [.caller, .request])
    #expect(sections[0].value == "Nicht genannt")
    #expect(sections[1].value == "Erkundigen sich nach Reiseangeboten in Afrika")
}

@Test func continuationLinesBelongToTheFieldAboveThem() {
    let sections = parseCallSummary("""
    Anliegen: Möchte ein Angebot
    für eine Reise nach Oman.
    Nächste Schritte: keine vereinbart
    """)

    #expect(sections.count == 2)
    #expect(sections[0].value == "Möchte ein Angebot für eine Reise nach Oman.")
}

@Test func unlabelledSummariesStayVerbatimSoOldCallsStillRead() {
    #expect(parseCallSummary("Der Anrufer wollte einen Termin und ruft morgen wieder an.").isEmpty)
    // A single recognised label is not enough to call the text structured.
    #expect(parseCallSummary("Anliegen: Termin").isEmpty)
}

@Test func onlyPairedEmphasisIsStripped() {
    #expect(strippingMarkdownEmphasis("**Anliegen:** Termin") == "Anliegen: Termin")
    #expect(strippingMarkdownEmphasis("2 * 3 Zimmer") == "2 * 3 Zimmer")
    #expect(strippingMarkdownEmphasis("snake_case bleibt") == "snake_case bleibt")
    #expect(strippingMarkdownEmphasis("Vorgang AB__CD") == "Vorgang AB__CD")
}

@Test func textBeforeTheFirstFieldIsNeverSilentlyDropped() {
    // Would otherwise vanish from both the card and the webhook payload.
    #expect(parseCallSummary("""
    Hinweis: dringend
    Anrufer: Frau Meier
    Anliegen: Rückruf erbeten
    """).isEmpty)
}

@Test func underscoresAndSingleAsterisksSurviveInValues() {
    let sections = parseCallSummary("""
    Anrufer: Herr Klein
    Anliegen: Fragt nach Vorgang AB__CD, Menge 2 * 3 Paletten
    """)

    #expect(sections.last?.value == "Fragt nach Vorgang AB__CD, Menge 2 * 3 Paletten")
}

@Test func aStereoCallGetsAStereoInjectionPacket() {
    // Opus is offered first, so sipgate answers with stereo. A packet that
    // claims mono is dropped by the tap and the assistant stays silent.
    let samples = Data(repeating: 0, count: 48_000 / 50 * 2 * MemoryLayout<Int16>.size)
    let packet = AudioInjectionProtocol.packet(samples: samples, sampleRate: 48_000, channels: 2)

    #expect(Array(packet[4..<8]) == [1, Speaker.me.rawValue, 1, 2])
    #expect(Array(packet[8..<12]) == [0x80, 0xbb, 0x00, 0x00])
    #expect(packet.dropFirst(16).count == samples.count)
}

@Test func theModelVoiceIsCentredWhenTheCallIsStereo() {
    let mono = pcmData([100, -200, 300])

    #expect(interleavedMonoAudio(mono, channels: 1) == mono)
    // Same sample on both channels: centred, and nothing is lost, because a
    // mono voice carries no stereo information to begin with.
    #expect(interleavedMonoAudio(mono, channels: 2) == pcmData([100, 100, -200, -200, 300, 300]))
    #expect(interleavedMonoAudio(Data(), channels: 2).isEmpty)
}

private func transmitFrame(
    rate: Double,
    channels: AVAudioChannelCount,
    format: AVAudioCommonFormat = .pcmFormatInt16,
    speaker: Speaker = .me
) -> AudioFrame {
    AudioFrame(speaker: speaker, sampleRate: rate, channels: channels, format: format, samples: Data([0, 0]))
}

@Test func theInjectionFormatFollowsWhateverTheCallNegotiated() {
    // The codecs a phone call actually negotiates. Opus at the top of the list
    // answers stereo, and rejecting that left the assistant silent on every
    // call for a day.
    #expect(injectionFormat(for: transmitFrame(rate: 8_000, channels: 1))
        == InjectionFormat(sampleRate: 8_000, channels: 1))   // G.711
    #expect(injectionFormat(for: transmitFrame(rate: 16_000, channels: 1))
        == InjectionFormat(sampleRate: 16_000, channels: 1))  // G.722
    #expect(injectionFormat(for: transmitFrame(rate: 48_000, channels: 2))
        == InjectionFormat(sampleRate: 48_000, channels: 2))  // Opus stereo
    #expect(injectionFormat(for: transmitFrame(rate: 48_000, channels: 1))
        == InjectionFormat(sampleRate: 48_000, channels: 1))  // Opus mono
}

@Test func aFormatTheBridgeCannotClockAgainstIsRefused() {
    #expect(injectionFormat(for: transmitFrame(rate: 48_000, channels: 3)) == nil)
    #expect(injectionFormat(for: transmitFrame(rate: 0, channels: 1)) == nil)
    #expect(injectionFormat(for: transmitFrame(rate: 48_000, channels: 2, format: .pcmFormatFloat32)) == nil)
    // Only the transmit direction clocks the injection; caller audio does not.
    #expect(injectionFormat(for: transmitFrame(rate: 8_000, channels: 1, speaker: .caller)) == nil)
}

@Test func everyNegotiableFormatProducesAPacketTheTapAccepts() {
    // phone_tap.c drops a packet whose format does not match the frame it is
    // clocking against, so the packet has to be built from that same decision.
    for frame in [
        transmitFrame(rate: 8_000, channels: 1),
        transmitFrame(rate: 16_000, channels: 1),
        transmitFrame(rate: 48_000, channels: 2)
    ] {
        let format = try! #require(injectionFormat(for: frame))
        let twentyMilliseconds = Int(format.sampleRate / 50) * Int(format.channels) * MemoryLayout<Int16>.size
        let packet = AudioInjectionProtocol.packet(
            samples: Data(repeating: 0, count: twentyMilliseconds),
            sampleRate: format.sampleRate,
            channels: format.channels
        )
        #expect(packet[7] == format.channels, "channel count in the header")
        #expect(packet.count == 16 + twentyMilliseconds)
    }
}

@Test func aStereoPacketExceedsTheDefaultDatagramLimit() {
    // net.local.dgram.maxdgram is 2048 by default on macOS. This is why both
    // ends of the injection socket widen their buffers; without it every send
    // fails with EMSGSIZE and the assistant is silent.
    let twentyMilliseconds = 48_000 / 50 * 2 * MemoryLayout<Int16>.size
    let packet = AudioInjectionProtocol.packet(
        samples: Data(repeating: 0, count: twentyMilliseconds),
        sampleRate: 48_000,
        channels: 2
    )

    #expect(packet.count == 3_856)
    #expect(packet.count > 2_048)
    // The widened buffer has to clear the largest packet the contract allows.
    #expect(4 * (phoneTapMaximumPayload + phoneTapHeaderSize) > packet.count)
}

@Test func aCallbackNumberNobodyGaveIsNotPassedOn() {
    // Verbatim from a real call: the caller said a fragment of her number and
    // the model produced a complete, plausible, wrong one. A wrong callback
    // number is worse than an empty field — nobody notices it is wrong.
    let transcript = """
    Caller: Ja, hallo. Mein Name ist Heike Wiese. Ich habe ein Problem mit meiner Heizung.
    Caller: und ähm 9 8 0 3 0 3 Südring 4 hier im Ort
    """
    let invented = """
    Anrufer: Heike Wiese, Bestandskunde.
    Anliegen: Störung der Heizung.
    Rückrufnummer: 0177 255 91 91
    Nächste Schritte: Techniker melden sich.
    """

    let checked = summaryWithVerifiedCallbackNumber(invented, transcript: transcript, callerNumber: "04482980303")
    #expect(!checked.contains("0177"))
    #expect(checked.contains("nicht eindeutig genannt"))
}

@Test func aNumberTheCallerActuallyGaveSurvives() {
    let transcript = "Caller: Sie erreichen mich unter 0441 9 88 77 66."
    let summary = """
    Anrufer: Herr Meier.
    Anliegen: Wartung.
    Rückrufnummer: 0441 9 88 77 66
    Nächste Schritte: keine vereinbart.
    """
    #expect(summaryWithVerifiedCallbackNumber(summary, transcript: transcript, callerNumber: nil)
        .contains("0441 9 88 77 66"))
}

@Test func theCallersOwnLineCountsAsGiven() {
    // The app knows who called; a summary naming that number is not invented.
    let summary = """
    Anrufer: unbekannt.
    Anliegen: Rückruf erbeten.
    Rückrufnummer: 04482980303
    Nächste Schritte: keine.
    """
    #expect(summaryWithVerifiedCallbackNumber(summary, transcript: "Caller: Rufen Sie mich zurück.", callerNumber: "04482980303")
        .contains("04482980303"))
}

@Test func amountsAndShortNumbersAreLeftAlone() {
    // Only the callback line is checked, and only runs long enough to be a
    // phone number, so "1500 Euro" spoken as words is not touched.
    let summary = """
    Anrufer: Frau Wiese.
    Anliegen: Angebot über 1500 Euro besprochen.
    Rückrufnummer: nicht genannt
    Nächste Schritte: keine.
    """
    #expect(summaryWithVerifiedCallbackNumber(summary, transcript: "Caller: eintausendfünfhundert Euro", callerNumber: nil)
        == summary)
}
