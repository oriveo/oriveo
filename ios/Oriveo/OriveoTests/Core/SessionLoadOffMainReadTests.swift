import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Production cold start: the recovery snapshot is read and decoded in the background, in parallel with opening the database; each load reads it only once;
/// the normal merge, database read failure and database open failure paths all use this one read, so the main thread never reads the recovery snapshot.
/// The test process allows the main thread to open the database synchronously by default (test host sync branch); here that is turned off to exercise the production path.
@MainActor
@Suite("Recovery snapshot is not read on the main thread", .serialized)
struct SessionLoadOffMainReadTests {
    /// Turns off the test host's synchronous first open, and counts main-thread "needed a library not pre-opened" events and main-thread recovery snapshot reads (following DatabasePrepareOffMainTests).
    private func productionOpening(_ body: () async throws -> Void) async rethrows -> (misses: [String], recoveryReadsOnMain: Int) {
        var misses: [String] = []
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        let previousMiss = DatabaseManager.mainThreadMissHandler
        DatabaseManager.allowsMainThreadFirstOpen = false
        DatabaseManager.mainThreadMissHandler = { uid in
            misses.append("\(uid) <- " + Thread.callStackSymbols.dropFirst(2).prefix(6).joined(separator: " | "))
        }
        defer {
            DatabaseManager.allowsMainThreadFirstOpen = previousAllows
            DatabaseManager.mainThreadMissHandler = previousMiss
        }
        let readsBefore = ConversationRuntimeBridge.debugRecoveryReadOnMainCount
        try await body()
        return (misses, ConversationRuntimeBridge.debugRecoveryReadOnMainCount - readsBefore)
    }

    private static func seedDatabase(uid: String, _ conversations: [Conversation]) throws {
        let pool = try DatabaseManager.shared.openIfNeeded(for: uid)
        try ConversationStore(
            dbPool: pool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        ).replaceAllConversations(conversations)
    }

    private static func seedRecovery(uid: String, _ conversations: [Conversation]) throws {
        try ConversationRuntimeBridge().persistRecoveryProjectionOnly(conversations, for: uid)
        #expect(FileManager.default.fileExists(atPath: AppSessionStore.recoverySnapshotPath(for: uid).path))
    }

    private static func makeFixtures() -> (stored: Conversation, recovered: Conversation) {
        let stored = TestFactories.makeConversation(
            title: "Stored", hasCustomTitle: true, messages: [TestFactories.makeMessage(text: "stored")]
        )
        let recovered = TestFactories.makeConversation(
            title: "Recovered only", hasCustomTitle: true, messages: [TestFactories.makeMessage(text: "recovered")]
        )
        return (stored, recovered)
    }

    @Test("Cold start: recovery snapshot is read in the background; merged result is field-for-field identical to the test host sync branch; zero main-thread reads")
    func coldStartRecoveryReadIsOffMainAndMergesSame() async throws {
        let syncUID = "offmain-read-sync-\(UUID().uuidString)"
        let asyncUID = "offmain-read-async-\(UUID().uuidString)"
        let fixtures = Self.makeFixtures()
        DatabaseManager.shared.close()
        for uid in [syncUID, asyncUID] {
            try Self.seedDatabase(uid: uid, [fixtures.stored])
            DatabaseManager.shared.close()
            try Self.seedRecovery(uid: uid, [fixtures.recovered])
        }

        // Baseline: test host sync branch (same merge function).
        let syncState = AppState(sessionUID: syncUID)
        #expect(syncState.sessionStoreReady)
        syncState.flushConversationPersistQueue()
        let expected = syncState.conversations
        #expect(Set(expected.map(\.id)) == [fixtures.stored.id, fixtures.recovered.id], "sessions unique to the recovery snapshot were merged back")
        await TestPartitionCleanup.remove(syncUID)
        DatabaseManager.shared.close()

        var state: AppState?
        let result = await productionOpening {
            let launched = AppState(sessionUID: asyncUID)
            state = launched
            #expect(!launched.sessionStoreReady, "database not opened correctly: loading state")
            await launched.waitForSessionStore()
            launched.flushConversationPersistQueue()
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.recoveryReadsOnMain == 0, "main thread read the recovery snapshot \(result.recoveryReadsOnMain) times")
        let launched = try #require(state)
        #expect(launched.sessionStoreReady)
        #expect(launched.conversations == expected, "merged result from the background read is field-for-field identical to the sync branch")
        await TestPartitionCleanup.remove(asyncUID)
    }

    @Test("Database opens but cannot be read: fall back to the same background-read recovery snapshot, zero main-thread reads")
    func dbReadFailureFallsBackToRecoveryReadOnceOffMain() async throws {
        let uid = "offmain-read-dbfail-\(UUID().uuidString)"
        let fixtures = Self.makeFixtures()
        DatabaseManager.shared.close()
        try Self.seedDatabase(uid: uid, [fixtures.stored])
        // Migration record is still there, session table is not: database open succeeds, reading session rows throws.
        try await DatabaseManager.shared.openIfNeeded(for: uid).write { db in
            try db.execute(sql: "ALTER TABLE conversation RENAME TO conversation_hidden_by_test")
        }
        DatabaseManager.shared.close()
        try Self.seedRecovery(uid: uid, [fixtures.recovered])

        var state: AppState?
        let result = await productionOpening {
            let launched = AppState(sessionUID: uid)
            state = launched
            #expect(!launched.sessionStoreReady, "database not opened correctly: loading state")
            await launched.waitForSessionStore()
            launched.flushConversationPersistQueue()
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.recoveryReadsOnMain == 0, "main thread read the recovery snapshot \(result.recoveryReadsOnMain) times")
        let launched = try #require(state)
        #expect(launched.sessionStoreReady)
        #expect(launched.conversations.map(\.id) == [fixtures.recovered.id], "database read failure falls back to the recovery snapshot")
        #expect(launched.conversations.first?.messages.count == 1, "recovery snapshot carries full text")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Database cannot be opened: fall back to the background-read recovery snapshot and enter the blocked state, zero main-thread reads")
    func dbOpenFailureFallsBackToRecoveryOffMain() async throws {
        let uid = "offmain-read-openfail-\(UUID().uuidString)"
        let fixtures = Self.makeFixtures()
        DatabaseManager.shared.close()
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        try Data("not-a-valid-sqlite".utf8).write(to: AppSessionStore.databasePath(for: uid), options: .atomic)
        try Self.seedRecovery(uid: uid, [fixtures.recovered])

        var state: AppState?
        let result = await productionOpening {
            let launched = AppState(sessionUID: uid)
            state = launched
            #expect(!launched.sessionStoreReady, "database not opened correctly: loading state")
            await launched.waitForSessionStore()
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.recoveryReadsOnMain == 0, "main thread read the recovery snapshot \(result.recoveryReadsOnMain) times")
        let launched = try #require(state)
        #expect(launched.sessionStoreReady)
        #expect(launched.databaseHealthProbe.health == .blocked(.unavailable))
        #expect(launched.conversations.map(\.id) == [fixtures.recovered.id], "database open failure falls back to the recovery snapshot")
        #expect(launched.conversations.first?.messages.count == 1, "recovery snapshot carries full text")
        await TestPartitionCleanup.remove(uid)
    }
}
