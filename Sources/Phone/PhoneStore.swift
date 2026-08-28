import Foundation
import SQLite3

struct ArchivedCall: Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: CallDirection
    let peer: String?
    let displayName: String?
    let startedAt: Date
    let duration: TimeInterval
    let missed: Bool
    let summary: String?
}

enum PhoneStoreError: Error, LocalizedError {
    case database(String)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .database(let operation): "The conversation archive could not \(operation)."
        case .invalidRecord: "The conversation archive contains an invalid record."
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    deinit { sqlite3_close(pointer) }
}

actor PhoneStore {
    static let currentSchemaVersion = 1
    static let migrationDefaultsKey = "didMigrateCallHistoryToSQLite"

    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.pointer }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone", isDirectory: true)
            .appendingPathComponent("phone.db")
    }

    init(path: String = PhoneStore.defaultDatabaseURL.path) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw PhoneStoreError.database("be opened")
        }
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.configure(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        connection = SQLiteConnection(handle)
    }

    func recordCall(_ call: CallRecord, displayName: String?) throws {
        let statement = try prepare(
            """
            INSERT INTO calls (id, direction, peer, display_name, started_at, duration, missed, summary)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                direction = excluded.direction,
                peer = excluded.peer,
                display_name = excluded.display_name,
                started_at = excluded.started_at,
                duration = excluded.duration,
                missed = excluded.missed
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(call.id.uuidString, at: 1, in: statement)
        try bind(call.direction.rawValue, at: 2, in: statement)
        try bind(call.peer, at: 3, in: statement)
        try bind(displayName, at: 4, in: statement)
        try check(sqlite3_bind_double(statement, 5, call.date.timeIntervalSince1970), operation: "be saved")
        try check(sqlite3_bind_double(statement, 6, call.duration), operation: "be saved")
        try check(sqlite3_bind_int(statement, 7, call.missed ? 1 : 0), operation: "be saved")
        try stepDone(statement, operation: "be saved")
    }

    func attachSummary(_ summary: String, to callID: UUID) throws {
        let statement = try prepare("UPDATE calls SET summary = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(summary, at: 1, in: statement)
        try bind(callID.uuidString, at: 2, in: statement)
        try stepDone(statement, operation: "be updated")
    }

    func insertUtterances(_ entries: [TranscriptEntry], callId: UUID) throws {
        guard !entries.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(
                """
                INSERT INTO utterances (id, call_id, speaker, is_assistant, text, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    call_id = excluded.call_id,
                    speaker = excluded.speaker,
                    is_assistant = excluded.is_assistant,
                    text = excluded.text,
                    created_at = excluded.created_at
                """
            )
            defer { sqlite3_finalize(statement) }
            for entry in entries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(entry.id.uuidString, at: 1, in: statement)
                try bind(callId.uuidString, at: 2, in: statement)
                try bind(entry.speaker == .me ? "me" : "caller", at: 3, in: statement)
                try check(sqlite3_bind_int(statement, 4, entry.isAssistant ? 1 : 0), operation: "be saved")
                try bind(entry.text, at: 5, in: statement)
                try check(sqlite3_bind_double(statement, 6, entry.createdAt.timeIntervalSince1970), operation: "be saved")
                try stepDone(statement, operation: "be saved")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func archiveCall(
        _ call: CallRecord,
        displayName: String?,
        utterances: [TranscriptEntry],
        summary: String?,
        includeConversationContent: Bool
    ) throws {
        try recordCall(call, displayName: displayName)
        guard includeConversationContent else {
            try deleteConversationContent(callId: call.id)
            return
        }
        try insertUtterances(utterances.filter(\.isFinal), callId: call.id)
        if let summary { try attachSummary(summary, to: call.id) }
    }

    private func deleteConversationContent(callId: UUID) throws {
        let utterances = try prepare("DELETE FROM utterances WHERE call_id = ?")
        defer { sqlite3_finalize(utterances) }
        try bind(callId.uuidString, at: 1, in: utterances)
        try stepDone(utterances, operation: "be updated")

        let summary = try prepare("UPDATE calls SET summary = NULL WHERE id = ?")
        defer { sqlite3_finalize(summary) }
        try bind(callId.uuidString, at: 1, in: summary)
        try stepDone(summary, operation: "be updated")
    }

    func fetchCalls(query: String? = nil, limit: Int = 100, offset: Int = 0) throws -> [ArchivedCall] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = trimmed?.isEmpty == false
        let sql = """
            SELECT c.id, c.direction, c.peer, c.display_name, c.started_at, c.duration, c.missed, c.summary
            FROM calls c
            \(hasQuery ? """
            WHERE c.peer LIKE ? ESCAPE '\\' COLLATE NOCASE
               OR c.display_name LIKE ? ESCAPE '\\' COLLATE NOCASE
               OR c.summary LIKE ? ESCAPE '\\' COLLATE NOCASE
               OR EXISTS (
                    SELECT 1 FROM utterances u
                    WHERE u.call_id = c.id AND u.text LIKE ? ESCAPE '\\' COLLATE NOCASE
               )
            """ : "")
            ORDER BY c.started_at DESC
            LIMIT ? OFFSET ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var parameter: Int32 = 1
        if let trimmed, hasQuery {
            let pattern = "%\(escapeLike(trimmed))%"
            for _ in 0..<4 {
                try bind(pattern, at: parameter, in: statement)
                parameter += 1
            }
        }
        try check(sqlite3_bind_int64(statement, parameter, Int64(max(0, limit))), operation: "be read")
        try check(sqlite3_bind_int64(statement, parameter + 1, Int64(max(0, offset))), operation: "be read")

        var calls: [ArchivedCall] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError("be read") }
            guard let id = UUID(uuidString: text(statement, column: 0) ?? ""),
                  let direction = CallDirection(rawValue: text(statement, column: 1) ?? "") else {
                throw PhoneStoreError.invalidRecord
            }
            calls.append(ArchivedCall(
                id: id,
                direction: direction,
                peer: text(statement, column: 2),
                displayName: text(statement, column: 3),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                duration: sqlite3_column_double(statement, 5),
                missed: sqlite3_column_int(statement, 6) != 0,
                summary: text(statement, column: 7)
            ))
        }
        return calls
    }

    func fetchUtterances(callId: UUID) throws -> [TranscriptEntry] {
        let statement = try prepare(
            """
            SELECT id, speaker, is_assistant, text, created_at
            FROM utterances
            WHERE call_id = ?
            ORDER BY created_at ASC, rowid ASC
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(callId.uuidString, at: 1, in: statement)
        var entries: [TranscriptEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError("be read") }
            guard let id = UUID(uuidString: text(statement, column: 0) ?? ""),
                  let speakerValue = text(statement, column: 1),
                  let body = text(statement, column: 3) else {
                throw PhoneStoreError.invalidRecord
            }
            entries.append(TranscriptEntry(
                id: id,
                speaker: speakerValue == "me" ? .me : .caller,
                text: body,
                isFinal: true,
                isAssistant: sqlite3_column_int(statement, 2) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return entries
    }

    func deleteCall(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM calls WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement, operation: "be deleted")
    }

    func deleteAll() throws {
        try execute("DELETE FROM calls")
    }

    func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError("be inspected") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func configure(_ database: OpaquePointer) throws {
        try execute("PRAGMA foreign_keys = ON", in: database)
        try execute("PRAGMA journal_mode = WAL", in: database)
        let version = try readSchemaVersion(in: database)
        guard version <= currentSchemaVersion else { throw PhoneStoreError.database("be opened") }
        guard version < 1 else { return }
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            try execute(
                """
                CREATE TABLE calls (
                    id TEXT PRIMARY KEY,
                    direction TEXT NOT NULL,
                    peer TEXT,
                    display_name TEXT,
                    started_at REAL NOT NULL,
                    duration REAL NOT NULL,
                    missed INTEGER NOT NULL,
                    summary TEXT NULL
                )
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE utterances (
                    id TEXT PRIMARY KEY,
                    call_id TEXT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    speaker TEXT NOT NULL,
                    is_assistant INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                in: database
            )
            try execute("CREATE INDEX calls_started_at_idx ON calls(started_at DESC)", in: database)
            try execute("CREATE INDEX utterances_call_id_created_at_idx ON utterances(call_id, created_at)", in: database)
            try execute("PRAGMA user_version = 1", in: database)
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private static func readSchemaVersion(in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw PhoneStoreError.database("be inspected") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw PhoneStoreError.database("be inspected") }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard result == SQLITE_OK else { throw PhoneStoreError.database("be updated") }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard result == SQLITE_OK else { throw databaseError("be updated") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError("be prepared")
        }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        try check(result, operation: "be prepared")
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(operation) }
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else { throw databaseError(operation) }
    }

    private func databaseError(_ operation: String) -> PhoneStoreError {
        PhoneStoreError.database(operation)
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

@MainActor
enum CallHistoryMigration {
    static func migrate(
        defaults: UserDefaults,
        store: PhoneStore,
        displayName: (String?) -> String? = { _ in nil }
    ) async throws -> Int {
        guard !defaults.bool(forKey: PhoneStore.migrationDefaultsKey) else { return 0 }
        let records: [CallRecord]
        if let data = defaults.data(forKey: "callHistory") {
            records = try JSONDecoder().decode([CallRecord].self, from: data)
        } else {
            records = []
        }
        for record in records {
            let resolvedName = displayName(record.peer)
            try await store.recordCall(record, displayName: resolvedName)
        }
        defaults.set(true, forKey: PhoneStore.migrationDefaultsKey)
        return records.count
    }
}

extension Notification.Name {
    static let phoneArchiveChanged = Notification.Name("PhoneArchiveChanged")
    static let phoneOpenLibrary = Notification.Name("PhoneOpenLibrary")
}
