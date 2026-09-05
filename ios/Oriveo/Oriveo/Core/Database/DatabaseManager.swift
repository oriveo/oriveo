import Foundation
import GRDB

nonisolated final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private let lock = NSLock()
    private var currentUID: String?
    private var currentPool: DatabasePool?

    private init() {}

    func openCurrent() throws -> DatabasePool {
        try openIfNeeded(for: AppSessionStore.activeUID)
    }

    func openIfNeeded(for uid: String) throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }

        if currentUID == uid, let currentPool {
            return currentPool
        }

        let userDirectory = AppSessionStore.userDir(for: uid)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let pool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let attachmentFileStore = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(pool)

        currentUID = uid
        currentPool = pool
        return pool
    }

    func checkpoint() throws {
        let pool = try openCurrent()
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func close() {
        lock.lock()
        currentUID = nil
        currentPool = nil
        lock.unlock()
    }

    func hasDatabase(for uid: String) -> Bool {
        let path = AppSessionStore.databasePath(for: uid).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64
        else {
            return false
        }
        return size > 0
    }

    /// `conversation` / `message` / `attachment` / `search_index` / `note` / `note_folder` / `note_search_index`.
    func deleteAllSyncableData_Allowlist() async throws {
        let pool = try openCurrent()
        try await pool.write { db in
            if try db.tableExists("search_index") {
                try db.execute(sql: "DELETE FROM search_index")
            }
            try db.execute(sql: "DELETE FROM attachment")
            try db.execute(sql: "DELETE FROM message")
            try db.execute(sql: "DELETE FROM conversation")
            if try db.tableExists("note_search_index") {
                try db.execute(sql: "DELETE FROM note_search_index")
            }
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM note_folder")
        }
    }
}
