import Foundation
import Testing
@testable import Phone

@Test func phoneStoreCRUD() async throws {
    let database = try TemporaryPhoneStore()
    let store = database.store
    let call = sampleCall(id: UUID(), peer: "+491234", date: Date(timeIntervalSince1970: 1_800_000_000))
    let utterances = [
        TranscriptEntry(
            speaker: .caller,
            text: "Hello from the caller",
            isFinal: true,
            createdAt: call.date.addingTimeInterval(2)
        ),
        TranscriptEntry(
            speaker: .me,
            text: "How can I help?",
            isFinal: true,
            isAssistant: true,
            createdAt: call.date.addingTimeInterval(4)
        )
    ]

    try await store.recordCall(call, displayName: "Alice")
    try await store.insertUtterances(utterances, callId: call.id)
    try await store.attachSummary("A short local summary", to: call.id)

    let calls = try await store.fetchCalls()
    let storedCall = try #require(calls.first)
    #expect(try await store.schemaVersion() == PhoneStore.currentSchemaVersion)
    #expect(calls.count == 1)
    #expect(storedCall.id == call.id)
    #expect(storedCall.displayName == "Alice")
    #expect(storedCall.summary == "A short local summary")
    #expect(try await store.fetchUtterances(callId: call.id) == utterances)
    #expect(FileManager.default.fileExists(atPath: database.url.path + "-wal"))

    try await store.deleteCall(call.id)
    #expect(try await store.fetchCalls().isEmpty)
    #expect(try await store.fetchUtterances(callId: call.id).isEmpty)

    try await store.recordCall(call, displayName: "Alice")
    try await store.deleteAll()
    #expect(try await store.fetchCalls().isEmpty)
}

@Test func phoneStoreSearchesMetadataSummaryAndUtterances() async throws {
    let database = try TemporaryPhoneStore()
    let store = database.store
    let alice = sampleCall(id: UUID(), peer: "+49111", date: Date(timeIntervalSince1970: 1_800_000_100))
    let bob = sampleCall(id: UUID(), peer: "+49222", date: Date(timeIntervalSince1970: 1_800_000_000))

    try await store.archiveCall(
        alice,
        displayName: "Alice Adams",
        utterances: [TranscriptEntry(speaker: .caller, text: "Discuss the lighthouse", isFinal: true, createdAt: alice.date)],
        summary: "Project launch notes",
        includeConversationContent: true
    )
    try await store.archiveCall(
        bob,
        displayName: "Bob Brown",
        utterances: [],
        summary: nil,
        includeConversationContent: true
    )

    #expect(try await store.fetchCalls(query: "Alice").map(\.id) == [alice.id])
    #expect(try await store.fetchCalls(query: "222").map(\.id) == [bob.id])
    #expect(try await store.fetchCalls(query: "launch").map(\.id) == [alice.id])
    #expect(try await store.fetchCalls(query: "LIGHTHOUSE").map(\.id) == [alice.id])
    #expect(try await store.fetchCalls(query: "%").isEmpty)
    #expect(try await store.fetchCalls(limit: 1, offset: 1).map(\.id) == [bob.id])
}

@MainActor
@Test func migratesSampleUserDefaultsCallHistoryOnce() async throws {
    let suiteName = "PhoneStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let database = try TemporaryPhoneStore()
    let store = database.store
    let records = [
        sampleCall(id: UUID(), peer: "+49333", date: Date(timeIntervalSince1970: 1_800_000_200)),
        sampleCall(id: UUID(), peer: "+49444", date: Date(timeIntervalSince1970: 1_800_000_100))
    ]
    defaults.set(try JSONEncoder().encode(records), forKey: "callHistory")

    let migrated = try await CallHistoryMigration.migrate(
        defaults: defaults,
        store: store,
        displayName: { $0 == "+49333" ? "Caroline" : nil }
    )
    let secondMigration = try await CallHistoryMigration.migrate(defaults: defaults, store: store)

    #expect(migrated == 2)
    #expect(secondMigration == 0)
    #expect(defaults.bool(forKey: PhoneStore.migrationDefaultsKey))
    let calls = try await store.fetchCalls()
    #expect(calls.count == 2)
    #expect(calls.first { $0.id == records[0].id }?.displayName == "Caroline")
}

@Test func archivingOffStoresOnlyCallMetadata() async throws {
    let database = try TemporaryPhoneStore()
    let store = database.store
    let call = sampleCall(id: UUID(), peer: "+49555", date: Date(timeIntervalSince1970: 1_800_000_000))
    let utterance = TranscriptEntry(
        speaker: .caller,
        text: "This must not be archived",
        isFinal: true,
        createdAt: call.date
    )

    try await store.archiveCall(
        call,
        displayName: "Dana",
        utterances: [utterance],
        summary: "Previously archived",
        includeConversationContent: true
    )
    try await store.archiveCall(
        call,
        displayName: "Dana",
        utterances: [utterance],
        summary: "This must not be archived either",
        includeConversationContent: false
    )

    let stored = try #require(try await store.fetchCalls().first)
    #expect(stored.peer == call.peer)
    #expect(stored.displayName == "Dana")
    #expect(stored.summary == nil)
    #expect(try await store.fetchUtterances(callId: call.id).isEmpty)
    #expect(try await store.fetchCalls(query: "must not").isEmpty)
}

private final class TemporaryPhoneStore {
    let url: URL
    let store: PhoneStore

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("phone.db")
        store = try PhoneStore(path: url.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private func sampleCall(id: UUID, peer: String, date: Date) -> CallRecord {
    CallRecord(
        id: id,
        direction: .incoming,
        peer: peer,
        date: date,
        duration: 65,
        missed: false
    )
}
