import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The first open of a partition database (connection + migrations) never happens on the main thread in production:
/// it is prepared in the background at launch and the UI shows nothing that could reach the database until it is ready.
@MainActor
@Suite("Partition database: first open is never on the main thread", .serialized)
struct DatabasePrepareOffMainTests {
    @Test("The main thread does not open an unprepared partition; after prepare it returns the open database")
    func mainThreadDoesNotOpen() async throws {
        let uid = "prepare-offmain-\(UUID().uuidString)"
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        let previousHandler = DatabaseManager.mainThreadMissHandler
        var misses: [String] = []
        DatabaseManager.allowsMainThreadFirstOpen = false
        DatabaseManager.mainThreadMissHandler = { misses.append($0) }
        defer {
            DatabaseManager.allowsMainThreadFirstOpen = previousAllows
            DatabaseManager.mainThreadMissHandler = previousHandler
        }
        DatabaseManager.shared.close()

        #expect(throws: DatabaseManager.NotPreparedOnMainThread.self) {
            _ = try DatabaseManager.shared.openIfNeeded(for: uid)
        }
        #expect(misses == [uid])
        #expect(DatabaseManager.shared.openedPool(for: uid) == nil, "nothing was opened on the main thread")

        let pool = try await DatabaseManager.shared.prepare(for: uid)
        #expect(try DatabaseManager.shared.openIfNeeded(for: uid) === pool)
        #expect(misses == [uid], "an open database is returned without another miss")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("A cold-start AppState prepares the database in the background: not ready at first, no main-thread open, ready after waiting")
    func coldStartPreparesInBackground() async throws {
        let uid = "prepare-offmain-cold-\(UUID().uuidString)"
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        let previousHandler = DatabaseManager.mainThreadMissHandler
        var misses: [String] = []
        DatabaseManager.allowsMainThreadFirstOpen = false
        DatabaseManager.mainThreadMissHandler = { misses.append($0) }
        defer {
            DatabaseManager.allowsMainThreadFirstOpen = previousAllows
            DatabaseManager.mainThreadMissHandler = previousHandler
        }
        DatabaseManager.shared.close()

        let state = AppState(seedDemoData: false, sessionUID: uid)
        #expect(!state.sessionStoreReady, "the database is not open yet, so the session is not ready")
        await state.waitForSessionStore()
        #expect(state.sessionStoreReady)
        #expect(DatabaseManager.shared.openedPool(for: uid) != nil)
        #expect(misses.isEmpty, "\(misses)")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("A partition reopened by uid in the background goes to the secondary slot and does not replace the current database")
    func backgroundReopenKeepsCurrent() async throws {
        let current = "prepare-offmain-current-\(UUID().uuidString)"
        let other = "prepare-offmain-other-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let currentPool = try await DatabaseManager.shared.prepare(for: current)
        let otherPool = try await Task.detached { try DatabaseManager.shared.openIfNeeded(for: other) }.value

        #expect(DatabaseManager.shared.openedPool() === currentPool, "the current database is unchanged")
        #expect(DatabaseManager.shared.openedPool(for: other) === otherPool)
        await TestPartitionCleanup.remove(current, other)
    }
}
