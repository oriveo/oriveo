#if DEBUG
import Foundation
import GRDB

/// DEBUG: attribution print for SQLite disk I/O errors (SQLITE_IOERR).
///
/// This error almost always has one cause: the database file was deleted or replaced while a connection was open (a partition
/// removed before an in-flight write, an atomic replace of an open database). The common write-failure exit only knows
/// the op, not which partition the database belongs to or who is writing, and with several suites running in parallel in the
/// test process "the most recently started test" does not identify the source either. At the moment SQLite reports it this
/// prints the partition this thread most recently asked for (a write resolved by uid must pass `openIfNeeded` first),
/// whether the database file still exists, and the app frames of the call stack.
nonisolated enum DatabaseIOErrorDiagnostics {
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false
    private static let uidKey = "oriveo.database.requestedUID"

    /// Must be called before the first connection is opened (a constraint of `Database.logError`): `DatabaseManager` installs it when it is created.
    static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true
        Database.logError = { code, message in
            guard code.primaryResultCode == .SQLITE_IOERR else { return }
            let uid = Thread.current.threadDictionary[uidKey] as? String
            let fileExists = uid.map { FileManager.default.fileExists(atPath: AppSessionStore.databasePath(for: $0).path) }
            let frames = Thread.callStackSymbols
                .filter { $0.contains(" Oriveo ") || $0.contains("Oriveo.debug.dylib") }
                .prefix(8)
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ") }
                .joined(separator: " | ")
            print("[DiskIO] sqlite \(code.rawValue) \(message) uid=\(uid ?? "?") dbFileExists=\(fileExists.map(String.init) ?? "?") stack=\(frames)")
        }
    }

    /// Which partition this thread's next reads and writes go to (recorded by `openIfNeeded(for:)`).
    static func noteRequestedUID(_ uid: String) {
        Thread.current.threadDictionary[uidKey] = uid
    }
}
#endif
