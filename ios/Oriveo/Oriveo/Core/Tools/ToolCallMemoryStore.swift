import Foundation
import GRDB

nonisolated struct ToolCallMemoryRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "connection_tool_call_memory"

    var connectionId: String
    var modelId: String
    var toolCall: Bool
    var observedAt: Date
    var reason: String
    /// The `modelFactsRevision` at the time of recording (nil = there was no facts dictionary then); a mismatch with the current one voids the record.
    var factsRevision: String?
    /// Snapshot of the hand-entered tool_call declaration of the model at the time of recording; a current declaration that differs means the user changed it after recording, which voids the record.
    var handEnteredDeclaration: Bool?
}

nonisolated enum ToolCallMemoryReason: String, Sendable {
    case structuredToolCalls = "structured_tool_calls"
    case toolsRejected4xx = "tools_rejected_4xx"
}

nonisolated final class ToolCallMemoryStore: @unchecked Sendable {
    static let shared = ToolCallMemoryStore()

    private let poolProvider: @Sendable () throws -> DatabasePool
    private let cacheLock = NSLock()
    private var cache: [String: ToolCallMemoryRecord?] = [:]
    /// Connections whose delete is still queued on the writer: until it lands, reading the database would return the stale rows, so lookups treat them as having no memory (key: connection id, value: in-flight count).
    private var pendingClears: [String: Int] = [:]

    init(poolProvider: @escaping @Sendable () throws -> DatabasePool = { try DatabaseManager.shared.openCurrent() }) {
        self.poolProvider = poolProvider
    }

    static func key(connectionID: UUID, modelID: String) -> (String, String) {
        (connectionID.uuidString, modelID)
    }

    private static func cacheKey(_ connection: String, _ model: String) -> String {
        "\(connection)\u{1F}\(model)"
    }

    /// A rejection record (false) whose revision differs from `currentFactsRevision` is treated as absent;
    /// "observed to support" (true) is not voided by a revision change.
    func lookup(
        connectionID: UUID,
        modelID: String,
        currentFactsRevision: String? = MetadataClient.shared.syncModelFactsRevision()
    ) -> ToolCallMemoryRecord? {
        let record = cachedOrFetched(connectionID: connectionID, modelID: modelID)
        guard let record, record.toolCall || record.factsRevision == currentFactsRevision else { return nil }
        return record
    }

    private func cachedOrFetched(connectionID: UUID, modelID: String) -> ToolCallMemoryRecord? {
        let (connection, model) = Self.key(connectionID: connectionID, modelID: modelID)
        let key = Self.cacheKey(connection, model)
        let (cached, clearing) = cacheLock.withLock { (cache[key], pendingClears[connection] != nil) }
        if let cached { return cached }
        if clearing { return nil }
        let fetched: ToolCallMemoryRecord?
        do {
            fetched = try poolProvider().read { db in
                try ToolCallMemoryRecord
                    .filter(Column("connectionId") == connection && Column("modelId") == model)
                    .fetchOne(db)
            }
        } catch {
            return nil
        }
        cacheLock.withLock { cache[key] = .some(fetched) }
        return fetched
    }

    @discardableResult
    func record(
        connectionID: UUID,
        modelID: String,
        toolCall: Bool,
        reason: ToolCallMemoryReason,
        handEnteredDeclaration: Bool? = nil,
        factsRevision: String? = MetadataClient.shared.syncModelFactsRevision(),
        now: Date = Date()
    ) -> Bool {
        let (connection, model) = Self.key(connectionID: connectionID, modelID: modelID)
        let record = ToolCallMemoryRecord(
            connectionId: connection, modelId: model, toolCall: toolCall,
            observedAt: now, reason: reason.rawValue,
            factsRevision: factsRevision, handEnteredDeclaration: handEnteredDeclaration
        )
        let pool: DatabasePool
        do { pool = try poolProvider() } catch { return false }
        // The cache takes effect first (later lookups see it at once); the write is queued on the GRDB writer
        // (FIFO keeps order) instead of waiting for the write lock on the calling thread: stream completion calls
        // this on the main thread, and a whole-table write holding the lock would stall it.
        cacheLock.withLock { cache[Self.cacheKey(connection, model)] = .some(record) }
        pool.asyncWrite({ db in try record.save(db) }, completion: { _, _ in })
        return true
    }

    func clear(connectionID: UUID) {
        let connection = connectionID.uuidString
        guard let pool = try? poolProvider() else {
            cacheLock.withLock { cache = cache.filter { !$0.key.hasPrefix(connection + "\u{1F}") } }
            return
        }
        cacheLock.withLock {
            cache = cache.filter { !$0.key.hasPrefix(connection + "\u{1F}") }
            pendingClears[connection, default: 0] += 1
        }
        pool.asyncWrite({ db in
            try ToolCallMemoryRecord
                .filter(Column("connectionId") == connection)
                .deleteAll(db)
        }, completion: { [weak self] _, _ in
            guard let self else { return }
            self.cacheLock.withLock {
                let remaining = (self.pendingClears[connection] ?? 1) - 1
                self.pendingClears[connection] = remaining > 0 ? remaining : nil
            }
        })
    }

    /// For tests: wait until queued record / clear writes have landed.
    func waitForPendingWritesForTesting() throws {
        try poolProvider().writeWithoutTransaction { _ in }
    }

    var poolProviderForTesting: @Sendable () throws -> DatabasePool { poolProvider }

    func count() -> Int {
        // Queued writes are not visible to a concurrent reader yet; let them land first so the count is deterministic.
        try? waitForPendingWritesForTesting()
        return (try? poolProvider().read { db in try ToolCallMemoryRecord.fetchCount(db) }) ?? 0
    }
}
