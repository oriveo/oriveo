import Foundation
import GRDB
import OriveoProviderKit

// Local memory candidate table and repository. Candidates live only in the current partition database on this device (the memory_candidate table, created by v39) and are not included in backups;
// they are deleted with the partition database, kept across a normal sign-out, and not carried over on guest sign-in. Only pending and unexpired rejected rows are kept: sweep deletes the rest before every write / read.
// All rules come from the ProviderKit `MemoryIntent` pure functions; after confirmation the item repository's `createFromDraft` takes the normal create path. Database reads and writes all run on a background thread.

/// A candidate operation failed: not_pending / expired / empty / too_long.
nonisolated struct MemoryCandidateFailure: Error, Equatable {
    let error: MemoryCandidateTransitionError
}

/// The outcome of one propose_memory call for the host: a new candidate, an instruction suggestion for this conversation (instruct), or nothing.
nonisolated enum ProposeMemoryResult: Sendable, Equatable {
    case candidate(MemoryCandidate)
    case instruct(sentence: String)
    case none

    var candidate: MemoryCandidate? {
        if case let .candidate(candidate) = self { return candidate }
        return nil
    }
}

/// Reads and writes the memory_candidate table: one row per candidate, with the payload holding the whole MemoryCandidate JSON.
nonisolated final class MemoryCandidateStore: Sendable {
    static let table = "memory_candidate"

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Creates the table (`v39_memory_candidates`).
    static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE \(table) (
                id TEXT PRIMARY KEY NOT NULL,
                status TEXT NOT NULL,
                payload TEXT NOT NULL
            )
            """)
    }

    /// The store of the partition; nil when the database cannot be opened.
    static func forPartition(_ uid: String) -> MemoryCandidateStore? {
        (try? DatabaseManager.shared.openIfNeeded(for: uid)).map { MemoryCandidateStore(dbPool: $0) }
    }

    /// All candidate rows in the database (no sweep), ordered by id ascending; corrupt rows are skipped.
    func all() throws -> [MemoryCandidate] {
        try dbPool.read { db in try Self.fetchAll(db) }
    }

    /// Sweeps first, then generates a candidate from the classification result; written only when makeCandidate decides create. Done within one transaction, so repeated calls for the same message never write two rows.
    func generate(
        _ classification: MemoryIntent.Classification,
        conversationId: String,
        folderId: String?,
        messageId: String,
        activeContents: [String],
        autoSuggest: Bool = true,
        nowMs: Int64
    ) throws -> MemoryCandidate? {
        try dbPool.write { db in
            let records = try Self.sweep(db, activeContents: activeContents, nowMs: nowMs)
            let context = MemoryCandidateContext(
                conversationId: conversationId,
                folderId: folderId,
                messageId: messageId,
                nowMs: nowMs,
                activeContents: activeContents,
                records: records,
                autoSuggest: autoSuggest
            )
            let decision = MemoryIntent.makeCandidate(classification, context: context)
            guard decision.action == .create, let candidate = decision.candidate else { return nil }
            return try Self.write(candidate, replace: false, in: db) ? candidate : nil
        }
    }

    /// Sweeps first, then generates a candidate from a single propose_memory call (MemoryPropose.propose); written only on create, within one transaction.
    /// instruct writes nothing to the database and only hands the sentence back to the caller, which shows the "set as this conversation's instruction" bar.
    func propose(
        _ arguments: String,
        priorInTurn: Int,
        priorInstructInTurn: Int = 0,
        userText: String,
        conversationId: String,
        folderId: String?,
        messageId: String,
        activeContents: [String],
        nowMs: Int64
    ) throws -> ProposeMemoryResult {
        try dbPool.write { db in
            let records = try Self.sweep(db, activeContents: activeContents, nowMs: nowMs)
            let context = MemoryProposeContext(
                conversationId: conversationId,
                folderId: folderId,
                messageId: messageId,
                nowMs: nowMs,
                activeContents: activeContents,
                records: records,
                userText: userText
            )
            let decision = MemoryPropose.propose(
                arguments, context: context, priorInTurn: priorInTurn, priorInstructInTurn: priorInstructInTurn
            )
            switch decision.action {
            case .instruct:
                return decision.sentence.map { .instruct(sentence: $0) } ?? .none
            case .create:
                guard let candidate = decision.candidate else { return .none }
                return try Self.write(candidate, replace: false, in: db) ? .candidate(candidate) : .none
            case .skip:
                return .none
            }
        }
    }

    /// Sweeps first, then returns the candidates awaiting confirmation: createdAtMs descending, ties by id ascending.
    func pending(activeContents: [String], nowMs: Int64) throws -> [MemoryCandidate] {
        try dbPool.write { db in
            try Self.sweep(db, activeContents: activeContents, nowMs: nowMs)
                .filter { $0.status == .pending }
                .sorted { lhs, rhs in
                    lhs.createdAtMs != rhs.createdAtMs ? lhs.createdAtMs > rhs.createdAtMs : lhs.id < rhs.id
                }
        }
    }

    /// The database part of confirming: returns the item draft to create; the candidate row is deleted by the same write transaction that creates the item (`deleteRow`). An expired candidate is deleted at the same time.
    func acceptDraft(id: String, edit: MemoryCandidateEdit?, nowMs: Int64) throws -> MemoryItemDraft {
        let outcome = try dbPool.write { db -> Result<MemoryItemDraft, MemoryCandidateFailure> in
            guard let record = try Self.fetchOne(db, id: id) else { return .failure(MemoryCandidateFailure(error: .notPending)) }
            let transition = MemoryIntent.accept(record, edit: edit, nowMs: nowMs)
            if let error = transition.error {
                if error == .expired { try Self.delete([record.id], in: db) }
                return .failure(MemoryCandidateFailure(error: error))
            }
            guard let draft = transition.item else { return .failure(MemoryCandidateFailure(error: .notPending)) }
            return .success(draft)
        }
        return try outcome.get()
    }

    /// Reject: stores the result of MemoryIntent.reject (only the fingerprint is kept).
    func reject(id: String, nowMs: Int64) throws -> MemoryCandidate {
        let outcome = try dbPool.write { db -> Result<MemoryCandidate, MemoryCandidateFailure> in
            guard let record = try Self.fetchOne(db, id: id) else { return .failure(MemoryCandidateFailure(error: .notPending)) }
            let transition = MemoryIntent.reject(record, nowMs: nowMs)
            guard let rejected = transition.record else {
                return .failure(MemoryCandidateFailure(error: transition.error ?? .notPending))
            }
            try Self.write(rejected, replace: true, in: db)
            return .success(rejected)
        }
        return try outcome.get()
    }

    func delete(id: String) throws {
        try dbPool.write { db in try Self.delete([id], in: db) }
    }

    /// Deletes the rows that sweep judges purged and returns the remaining candidates. Rows whose payload cannot be decoded are also deleted as purged, so no bad rows are left that never go away.
    private static func sweep(_ db: Database, activeContents: [String], nowMs: Int64) throws -> [MemoryCandidate] {
        var records: [MemoryCandidate] = []
        var unreadableIds: [String] = []
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM \(table) ORDER BY id ASC") {
            if let record = candidate(from: row) {
                records.append(record)
            } else if let id: String = row["id"] {
                unreadableIds.append(id)
            }
        }
        let result = MemoryIntent.sweep(records, activeContents: activeContents, nowMs: nowMs)
        try delete(unreadableIds + result.purgedIds, in: db)
        let purged = Set(result.purgedIds)
        return records.filter { !purged.contains($0.id) }
    }

    @discardableResult
    private static func write(_ candidate: MemoryCandidate, replace: Bool, in db: Database) throws -> Bool {
        let payload = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
        let verb = replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        try db.execute(
            sql: "\(verb) INTO \(table) (id, status, payload) VALUES (?, ?, ?)",
            arguments: [candidate.id, candidate.status.rawValue, payload]
        )
        return db.changesCount > 0
    }

    /// Deletes one candidate row inside the caller's write transaction (it succeeds or fails together with creating the item on confirmation).
    static func deleteRow(id: String, in db: Database) throws {
        try delete([id], in: db)
    }

    private static func delete(_ ids: [String], in db: Database) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
        }
    }

    private static func fetchOne(_ db: Database, id: String) throws -> MemoryCandidate? {
        try Row.fetchOne(db, sql: "SELECT payload FROM \(table) WHERE id = ?", arguments: [id]).flatMap(candidate(from:))
    }

    private static func fetchAll(_ db: Database) throws -> [MemoryCandidate] {
        try Row.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY id ASC").compactMap(candidate(from:))
    }

    private static func candidate(from row: Row) -> MemoryCandidate? {
        guard let payload: String = row["payload"] else { return nil }
        return try? JSONDecoder().decode(MemoryCandidate.self, from: Data(payload.utf8))
    }
}

/// A per-partition serial gate for confirming / rejecting candidates: the next one is let in only after the previous one is done (including the item being written and the candidate row deleted).
actor MemoryCandidateGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// The memory candidate repository of one partition. Time is always passed in by the caller (epoch milliseconds); database reads and writes run on a background thread.
final class MemoryCandidateRepository {
    let store: MemoryCandidateStore
    private let items: MemoryItemRepository

    /// A serial gate per partition uid: AppState creates a new repository instance each time, and the gate hangs off the uid, so instances of the same partition share one.
    private static var gates: [String: MemoryCandidateGate] = [:]

    init(store: MemoryCandidateStore, items: MemoryItemRepository) {
        self.store = store
        self.items = items
    }

    /// nil when the partition database cannot be opened; the item repository must belong to the same partition.
    static func forPartition(_ uid: String, items: MemoryItemRepository) -> MemoryCandidateRepository? {
        MemoryCandidateStore.forPartition(uid).map { MemoryCandidateRepository(store: $0, items: items) }
    }

    /// This partition's auto-suggestion switch (on by default): turning it off blocks only implicit candidates, while an explicit "remember" still works; existing pending candidates are not deleted.
    func autoSuggestEnabled() -> Bool {
        AppPreferencesStore.memoryAutoSuggestEnabled(uid: items.uid)
    }

    func setAutoSuggestEnabled(_ enabled: Bool) {
        AppPreferencesStore.setMemoryAutoSuggestEnabled(enabled, uid: items.uid)
    }

    /// A sentence the user just sent -> a new candidate or nil. No candidate when useMemory=false; implicit candidates are skipped when auto-suggestion is off; the item table is not touched.
    func generate(
        text: String,
        messageId: String,
        conversationId: String,
        folderId: String?,
        useMemory: Bool,
        nowMs: Int64
    ) async throws -> MemoryCandidate? {
        guard useMemory else { return nil }
        let store = store
        let itemStore = items.store
        let autoSuggest = autoSuggestEnabled()
        return try await Task.detached(priority: .utility) {
            let classification = MemoryIntent.classify(text)
            guard classification.suggestion == .memory else { return nil }
            return try store.generate(
                classification,
                conversationId: conversationId,
                folderId: folderId,
                messageId: messageId,
                activeContents: try Self.activeContents(itemStore),
                autoSuggest: autoSuggest,
                nowMs: nowMs
            )
        }.value
    }

    /// A model's propose_memory call -> a new candidate, an instruction suggestion, or nothing (stored the same way as generate; only create writes, every other outcome writes nothing).
    /// Whether to go through the tool is decided by the caller from MemoryPropose.mode, so useMemory / the auto-suggestion switch are not checked here; bad arguments also just return none.
    /// userText = the body of the user message newly sent this turn; priorInTurn = the number of propose calls earlier in this turn (whatever their outcome);
    /// priorInstructInTurn = the number of earlier calls in this turn whose outcome was instruct.
    func propose(
        argumentsJSON: String,
        priorInTurn: Int,
        priorInstructInTurn: Int = 0,
        userText: String,
        messageId: String,
        conversationId: String,
        folderId: String?,
        nowMs: Int64
    ) async throws -> ProposeMemoryResult {
        let store = store
        let itemStore = items.store
        return try await Task.detached(priority: .utility) {
            try store.propose(
                argumentsJSON,
                priorInTurn: priorInTurn,
                priorInstructInTurn: priorInstructInTurn,
                userText: userText,
                conversationId: conversationId,
                folderId: folderId,
                messageId: messageId,
                activeContents: try Self.activeContents(itemStore),
                nowMs: nowMs
            )
        }.value
    }

    /// Confirm: creating the item (new id, pending, dual-write of the legacy fields, same as create) and deleting the candidate row happen in one write transaction,
    /// and if either fails everything rolls back (no item, the candidate stays pending); returns the item. The item and the candidate live in the same partition database.
    /// Serial within a partition: when the same id is confirmed concurrently only one item is created, and the latecomer gets not_pending.
    func accept(id: String, edit: MemoryCandidateEdit?, nowMs: Int64) async throws -> MemoryItem {
        let store = store
        let items = items
        return try await serialized {
            let draft = try await Task.detached(priority: .userInitiated) {
                try store.acceptDraft(id: id, edit: edit, nowMs: nowMs)
            }.value
            return try await items.createFromDraft(draft) { db in
                try MemoryCandidateStore.deleteRow(id: id, in: db)
            }
        }
    }

    /// Reject: only the fingerprint is kept, and the same sentence is not suggested again during the rejection period.
    @discardableResult
    func reject(id: String, nowMs: Int64) async throws -> MemoryCandidate {
        let store = store
        return try await serialized {
            try await Task.detached(priority: .userInitiated) {
                try store.reject(id: id, nowMs: nowMs)
            }.value
        }
    }

    /// Runs body inside this partition's serial gate, and releases the gate even if it throws.
    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        let gate = Self.gates[items.uid] ?? MemoryCandidateGate()
        Self.gates[items.uid] = gate
        await gate.acquire()
        do {
            let value = try await body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Candidates awaiting confirmation (sweep first): createdAtMs descending, ties by id ascending.
    func pending(nowMs: Int64) async throws -> [MemoryCandidate] {
        let store = store
        let itemStore = items.store
        return try await Task.detached(priority: .userInitiated) {
            try store.pending(activeContents: try Self.activeContents(itemStore), nowMs: nowMs)
        }.value
    }

    /// Text of this partition's items that are active / paused / conflicted (superseded / expired / deleted do not count).
    private nonisolated static func activeContents(_ itemStore: MemoryItemStore) throws -> [String] {
        let counted: Set<MemoryStatus> = [.active, .paused, .conflicted]
        return try itemStore.all().filter { counted.contains($0.status) }.map(\.content)
    }
}
