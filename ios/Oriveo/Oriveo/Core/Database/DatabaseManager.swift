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

        let databaseURL = AppSessionStore.databasePath(for: uid)
        try Self.throwIfExistingFileIsNotSQLite(databaseURL)

        let pool = try DatabasePool(
            path: databaseURL.path,
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

    /// replaceAll and similar paths must fail loudly when the file exists but is not SQLite,
    /// instead of letting GRDB treat the garbage as an empty database.
    private static func throwIfExistingFileIsNotSQLite(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 16)
        guard prefix.isEmpty || prefix.starts(with: Data("SQLite format 3".utf8)) else {
            throw DatabaseError(resultCode: .SQLITE_NOTADB)
        }
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
}
