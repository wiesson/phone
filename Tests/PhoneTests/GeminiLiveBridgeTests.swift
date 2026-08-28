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
}

@Test func resamplesGeminiAudioFrom24kTo8k() {
    let input = pcmData([0, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000, 10_000, 11_000])
    let output = resamplePCM16Mono(input, from: 24_000, to: 8_000)

    #expect(pcmSamples(output) == [0, 3_000, 6_000, 9_000])
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
