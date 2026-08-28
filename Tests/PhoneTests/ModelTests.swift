import Foundation
import Testing
@testable import Phone

@Test func identifiesReadyState() {
    #expect(CallState.ready.isReady)
    #expect(!CallState.starting.isReady)
    #expect(!CallState.connected(nil).isReady)
}

@Test func identifiesInCallStates() {
    #expect(CallState.dialing("123").isInCall)
    #expect(CallState.answering(nil).isInCall)
    #expect(CallState.connected("Alice").isInCall)
    #expect(!CallState.ringing("Alice").isInCall)
    #expect(!CallState.ready.isInCall)
    #expect(!CallState.error("Failed").isInCall)
}

@Test func returnsCallPeers() {
    #expect(CallState.ringing("Alice").peer == "Alice")
    #expect(CallState.ringing(nil).peer == nil)
    #expect(CallState.dialing("123").peer == "123")
    #expect(CallState.answering("Bob").peer == "Bob")
    #expect(CallState.connected(nil).peer == nil)
    #expect(CallState.ready.peer == nil)
}

@Test func producesCallStateLabels() {
    #expect(CallState.stopped.label == "Phone is off")
    #expect(CallState.starting.label == "Registering SIP …")
    #expect(CallState.ready.label == "Ready")
    #expect(CallState.ringing("Alice").label == "Call from Alice")
    #expect(CallState.ringing(nil).label == "Incoming call")
    #expect(CallState.dialing("123").label == "Calling 123")
    #expect(CallState.answering(nil).label == "Connecting …")
    #expect(CallState.connected("Bob").label == "Connected to Bob")
    #expect(CallState.connected(nil).label == "Connected")
    #expect(CallState.error("Registration failed").label == "Registration failed")
}

@Test func roundTripsAssistantTranscriptEntryThroughJSON() throws {
    let entry = TranscriptEntry(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        speaker: .me,
        text: "Guten Tag.",
        isFinal: true,
        isAssistant: true,
        createdAt: Date(timeIntervalSince1970: 1_725_000_000)
    )

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)

    #expect(decoded == entry)
    #expect(decoded.isAssistant)
    #expect(decoded.speakerTitle == "Assistant")
}

@Test func transcriptEntryDefaultsToHumanSpeaker() {
    let entry = TranscriptEntry(speaker: .me, text: "Hello", isFinal: true, createdAt: Date())

    #expect(!entry.isAssistant)
    #expect(entry.speakerTitle == "Me")
}

@Test func roundTripsCallRecordThroughJSON() throws {
    let record = CallRecord(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        direction: .incoming,
        peer: "+491234",
        date: Date(timeIntervalSince1970: 1_725_000_000),
        duration: 42.5,
        missed: false
    )

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(CallRecord.self, from: data)

    #expect(decoded == record)
}
