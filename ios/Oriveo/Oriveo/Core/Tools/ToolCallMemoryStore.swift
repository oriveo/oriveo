import Foundation
import GRDB

nonisolated struct ToolCallMemoryRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "connection_tool_call_memory"

    var connectionId: String
    var modelId: String
    var toolCall: Bool
    var observedAt: Date
    var reason: String
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

    init(poolProvider: @escaping @Sendable () throws -> DatabasePool = { try DatabaseManager.shared.openCurrent() }) {
        self.poolProvider = poolProvider
    }

    static func key(connectionID: UUID, modelID: String) -> (String, String) {
        (connectionID.uuidString, modelID)
    }

    private static func cacheKey(_ connection: String, _ model: String) -> String {
        "\(connection)\u{1F}\(model)"
    }

    func lookup(connectionID: UUID, modelID: String) -> ToolCallMemoryRecord? {
        let (connection, model) = Self.key(connectionID: connectionID, modelID: modelID)
        let key = Self.cacheKey(connection, model)
        if let cached = cacheLock.withLock({ cache[key] }) { return cached }
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
        now: Date = Date()
    ) -> Bool {
        let (connection, model) = Self.key(connectionID: connectionID, modelID: modelID)
        let record = ToolCallMemoryRecord(
            connectionId: connection, modelId: model, toolCall: toolCall,
            observedAt: now, reason: reason.rawValue
        )
        do {
            try poolProvider().write { db in try record.save(db) }
            cacheLock.withLock { cache[Self.cacheKey(connection, model)] = .some(record) }
            return true
        } catch {
            return false
        }
    }

    func clear(connectionID: UUID) {
        let connection = connectionID.uuidString
        cacheLock.withLock {
            cache = cache.filter { !$0.key.hasPrefix(connection + "\u{1F}") }
        }
        _ = try? poolProvider().write { db in
            try ToolCallMemoryRecord
                .filter(Column("connectionId") == connection)
                .deleteAll(db)
        }
    }

    var poolProviderForTesting: @Sendable () throws -> DatabasePool { poolProvider }

    func count() -> Int {
        (try? poolProvider().read { db in try ToolCallMemoryRecord.fetchCount(db) }) ?? 0
    }
}
