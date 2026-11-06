import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The production first open (connect and migrate) never runs on the main thread: cold start and partition switches prepare in the background, the home screen shows a loading skeleton until it is open, and sessions are installed afterwards.
/// The test process allows a synchronous main-thread first open by default (test host entry); it is turned off here to take the production path.
@MainActor
@Suite("Partition database background prepare: zero opens on the main thread", .serialized, .sharedProcessState)
struct DatabasePrepareOffMainTests {
    /// Turns off the test host's synchronous first open and collects main-thread requests for unprepared databases and write-gate violations.
    private func productionOpening(_ body: () async throws -> Void) async rethrows -> (misses: [String], violations: [String]) {
        var misses: [String] = []
        var violations: [String] = []
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        let previousMiss = DatabaseManager.mainThreadMissHandler
        let previousViolation = MainThreadDatabaseWriteGuard.violationHandler
        DatabaseManager.allowsMainThreadFirstOpen = false
        DatabaseManager.mainThreadMissHandler = { uid in
            misses.append("\(uid) <- " + Thread.callStackSymbols.dropFirst(2).prefix(6).joined(separator: " | "))
        }
        MainThreadDatabaseWriteGuard.violationHandler = { violations.append($0) }
        defer {
            DatabaseManager.allowsMainThreadFirstOpen = previousAllows
            DatabaseManager.mainThreadMissHandler = previousMiss
            MainThreadDatabaseWriteGuard.violationHandler = previousViolation
        }
        try await body()
        MainThreadDatabaseWriteGuard.drain()
        return (misses, violations)
    }

    private static func seed(uid: String, _ conversations: [Conversation]) throws {
        let pool = try DatabaseManager.shared.openIfNeeded(for: uid)
        try ConversationStore(
            dbPool: pool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        ).replaceAllConversations(conversations)
    }

    /// Seeds a session snapshot with one provider (the API key goes to the Keychain, as in production).
    private static func seedSessionSnapshot(uid: String) -> Provider {
        let provider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4.1", isDefault: true)],
            apiKey: "sk-prepare-\(uid.suffix(4))"
        )
        // The deterministic-id migration rewrites random ids: this asserts the snapshot is restored as-is and marks this partition as already migrated.
        UserDefaults.standard.set(true, forKey: "oriveo.providers.deterministicIDMigrated.\(uid)")
        AppSessionStore.save(
            AppSessionSnapshot(
                selectedTab: .home, hasCompletedOnboarding: true, providers: [provider],
                conversations: nil, lastUsedModelRef: nil, folders: nil
            ),
            for: uid
        )
        return provider
    }

    @Test("Cold start: the partition database is not read or written before the background open finishes, sessions are installed after it opens, and the main thread has zero opens and zero migrations")
    func coldStartOpensOffMain() async throws {
        #expect(!MainThreadDatabaseWriteAllowlist.mainThreadDebt.contains("DatabaseManager.makePool"))
        let uid = "prepare-cold-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let stored = TestFactories.makeConversation(title: "Stored", hasCustomTitle: true)
        try Self.seed(uid: uid, [stored])
        DatabaseManager.shared.close()
        let seededProvider = Self.seedSessionSnapshot(uid: uid)

        var state: AppState?
        let recoveryReadsBefore = ConversationRuntimeBridge.debugRecoveryReadOnMainCount
        let result = await productionOpening {
            let launched = AppState(sessionUID: uid)
            state = launched
            #expect(!launched.sessionStoreReady, "database not open yet: loading state")
            #expect(launched.conversations.isEmpty)
            await launched.waitForSessionStore()
            #expect(launched.providers.map(\.id) == [seededProvider.id], "session snapshot installed when ready")
            #expect(launched.debugSessionSnapshotReadsOnMain == 0, "session snapshot is not read on the main thread")
            launched.flushConversationPersistQueue()
        }
        #expect(ConversationRuntimeBridge.debugRecoveryReadOnMainCount - recoveryReadsBefore == 0, "recovery snapshot is not read on the main thread")
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.violations.isEmpty, "\(result.violations)")
        let launched = try #require(state)
        #expect(launched.sessionStoreReady)
        #expect(launched.conversations.map(\.id) == [stored.id], "sessions installed after opening")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Demo data launch (sample and store images): the partition database is also prepared in the background, shows loading until it is open, and has zero main-thread opens")
    func seedDemoDataOpensOffMain() async throws {
        let uid = "prepare-seed-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        var state: AppState?
        let result = await productionOpening {
            let launched = AppState(seedDemoData: true, sessionUID: uid)
            state = launched
            #expect(!launched.sessionStoreReady, "database not open yet: loading state")
            await launched.waitForSessionStore()
            // The note-mirror reload queued at bind only reads after the database opens: wait for one reload round to finish before deleting the partition (otherwise the read races the deleted database).
            await launched.noteManager.reloadFromStore()?.value
            launched.flushConversationPersistQueue()
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.violations.isEmpty, "\(result.violations)")
        let launched = try #require(state)
        #expect(launched.sessionStoreReady)
        #expect(!launched.conversations.isEmpty, "demo sessions still in memory")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("The main thread is not blocked during a slow migration of a large database")
    func slowMigrationDoesNotBlockMainThread() async throws {
        let uid = "prepare-slow-\(UUID().uuidString)"
        defer {
            DatabaseManager.migrationDelayForTesting = 0
            DatabaseManager.shared.close()
        }
        DatabaseManager.shared.close()
        DatabaseManager.migrationDelayForTesting = 1.5
        let seededProvider = Self.seedSessionSnapshot(uid: uid)
        var worstGap: TimeInterval = 0
        // Hold until cleanup: if the instance were released early, cleanup could neither find it nor wait for its ledger cleanup queued behind writes (which would hit the deleted database).
        var launchedState: AppState?
        let result = await productionOpening {
            let started = Date()
            let launched = AppState(sessionUID: uid)
            launchedState = launched
            #expect(Date().timeIntervalSince(started) < 1.0, "init does not wait for migration")
            // The main thread keeps running during migration: it hops every 20ms and records the largest gap.
            var last = Date()
            while !launched.sessionStoreReady {
                try? await Task.sleep(nanoseconds: 20_000_000)
                worstGap = max(worstGap, Date().timeIntervalSince(last))
                last = Date()
            }
            #expect(Date().timeIntervalSince(started) >= 1.4, "migration really ran in the background for this long")
            await launched.waitForSessionStore()
            #expect(launched.providers.map(\.id) == [seededProvider.id], "session snapshot installed when ready")
            #expect(launched.debugSessionSnapshotReadsOnMain == 0, "session snapshot is not read on the main thread")
        }
        #expect(worstGap < 0.5, "longest main-thread stall during migration \(worstGap)s")
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.violations.isEmpty, "\(result.violations)")
        await TestPartitionCleanup.remove(uid)
        withExtendedLifetime(launchedState) {}
    }

    @Test("Partition switch (for example logging out back to guest): the next partition is prepared in the background with zero main-thread opens, and a queued write from the old partition does not replace the new partition's database")
    func partitionSwitchOpensOffMain() async throws {
        let uidA = "prepare-switch-a-\(UUID().uuidString)"
        let uidB = "prepare-switch-b-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let inB = TestFactories.makeConversation(title: "In B", hasCustomTitle: true)
        try Self.seed(uid: uidB, [inB])
        DatabaseManager.shared.close()
        let state = AppState(sessionUID: uidA)
        let pending = TestFactories.makeConversation(title: "Queued on A", hasCustomTitle: true)

        let result = await productionOpening {
            state.upsertConversationProjection(pending)
            state.closeSessionStoreForPartitionSwitch()
            state.loadSession(boundTo: uidB)
            #expect(!state.sessionStoreReady)
            await state.waitForSessionStore()
            state.flushConversationPersistQueue()
            #expect(DatabaseManager.shared.openedPool()?.path == AppSessionStore.databasePath(for: uidB).path,
                    "a queued write from the old partition reopening A does not replace the current partition")
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.violations.isEmpty, "\(result.violations)")
        #expect(state.conversations.map(\.id) == [inB.id])
        let poolA = try DatabaseManager.shared.openIfNeeded(for: uidA)
        let storedA = try ConversationStore(
            dbPool: poolA, attachmentFileStore: AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uidA))
        ).fetchConversationList()
        #expect(storedA.map(\.id) == [pending.id], "in-flight writes from the old partition land in the old partition")
        await TestPartitionCleanup.remove(uidA, uidB)
    }

    /// The outgoing view tree still gets one update (and `.task` continuations still land) after the mirror is cleared
    /// and the partition store is closed, before the root swaps to the loading state. Production stacks:
    /// `SettingsView.syncMcpEntry` and `HomeView.topBarTrailing`. Every fallback that reads the store when the mirror
    /// is empty has to stay off it until `sessionStoreReady`.
    @Test("Partition switch window: list, folder and MCP reads stay off the closed store, then see the new partition")
    func partitionSwitchWindowReadsStayOffTheStore() async throws {
        let uidA = "prepare-window-a-\(UUID().uuidString)"
        let uidB = "prepare-window-b-\(UUID().uuidString)"
        defer {
            DatabaseOpenDiagnostics.sink = Observability.sink
            DatabaseOpenDiagnostics.resetForTesting()
            DatabaseManager.shared.close()
        }
        DatabaseManager.shared.close()
        let folderID = UUID()
        let inB = TestFactories.makeConversation(title: "In B", hasCustomTitle: true)
        let inFolder = TestFactories.makeConversation(title: "In B folder", hasCustomTitle: true, folderID: folderID)
        try Self.seed(uid: uidB, [inB, inFolder])
        let serverInB = McpTestRecords.record(slug: "window")
        try McpServerStore(dbPool: DatabaseManager.shared.openIfNeeded(for: uidB)).insertServer(serverInB)
        DatabaseManager.shared.close()
        let sink = RecordingObservabilitySink()
        DatabaseOpenDiagnostics.sink = sink
        DatabaseOpenDiagnostics.resetForTesting()

        let state = AppState(sessionUID: uidA)
        let originalPreferences = state.preferences
        defer { state.preferences = originalPreferences }
        let result = await productionOpening {
            state.closeSessionStoreForPartitionSwitch()
            state.loadSession(boundTo: uidB)
            #expect(!state.sessionStoreReady)
            state.preferences.pinnedConversationIDs = [inB.id]

            #expect(state.recentConversations.isEmpty)
            #expect(state.recentConversationSections.isEmpty)
            let homeConversations = state.homeConversationSections(earlierLimit: 10).flatMap { $0.conversations }
            #expect(homeConversations.isEmpty)
            #expect(state.conversationManager.pinnedConversations.isEmpty)
            #expect(state.folderManager.conversations(in: folderID).isEmpty)
            #expect(state.folderManager.conversationCount(in: folderID) == 0)
            #expect(state.folderManager.searchConversations(in: folderID, matching: "In B").isEmpty)
            #expect(throws: McpServerDirectoryError.sessionStoreNotReady) {
                try state.mcpServerDirectory.overview(uid: state.sessionPartitionUID)
            }
            _ = await state.searchConversations(matching: "In B")

            await state.waitForSessionStore()
            #expect(state.recentConversations.map(\.id) == [inB.id])
            #expect(state.conversationManager.pinnedConversations.map(\.id) == [inB.id])
            #expect(state.folderManager.conversations(in: folderID).map(\.id) == [inFolder.id])
            #expect(state.folderManager.conversationCount(in: folderID) == 1)
            let overview = try? state.mcpServerDirectory.overview(uid: state.sessionPartitionUID)
            #expect(overview?.map(\.record.id) == [serverInB.id], "The settings entry reads the new partition once ready")
            state.flushConversationPersistQueue()
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(result.violations.isEmpty, "\(result.violations)")
        #expect(sink.issues.isEmpty, "\(sink.issues.map(\.fingerprint))")
        await TestPartitionCleanup.remove(uidA, uidB)
    }

    /// Puts a non-SQLite database file in the partition: the prepare necessarily fails.
    private static func corruptDatabase(uid: String) throws {
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        try Data("not-a-valid-sqlite".utf8).write(to: AppSessionStore.databasePath(for: uid), options: .atomic)
    }

    @Test("After a failed prepare, a main-thread request throws \"database unavailable\" without recording a miss or reopening; the background thread still opens on demand; close clears the failure record")
    func failedPrepareShortCircuitsMainThreadRequestsWithoutMiss() async throws {
        let uid = "prepare-failed-\(UUID().uuidString)"
        defer {
            DatabaseOpenDiagnostics.resetForTesting()
            DatabaseManager.shared.close()
        }
        DatabaseManager.shared.close()
        try Self.corruptDatabase(uid: uid)
        DatabaseOpenDiagnostics.resetForTesting()
        var thrown: [Error] = []
        var backgroundError: Error?
        let result = await productionOpening {
            await #expect(throws: (any Error).self) { _ = try await DatabaseManager.shared.prepare(for: uid) }
            for _ in 0..<2 {
                do { _ = try DatabaseManager.shared.openIfNeeded(for: uid) } catch { thrown.append(error) }
            }
            backgroundError = await Task.detached {
                do { _ = try DatabaseManager.shared.openIfNeeded(for: uid); return nil } catch { return error }
            }.value
        }
        #expect(thrown.map { $0 as? DatabaseManager.DatabaseUnavailable } == [.init(uid: uid), .init(uid: uid)])
        #expect(result.misses.isEmpty, "\(result.misses)")
        #expect(DatabaseManager.shared.openedPool(for: uid) == nil, "no database was opened on the main thread")
        let background = try #require(backgroundError, "the background thread still opens on demand, and a broken database still throws the open error")
        #expect(!(background is DatabaseManager.DatabaseUnavailable))

        DatabaseManager.shared.close()
        let afterClose = await productionOpening {
            #expect(throws: DatabaseManager.NotPreparedOnMainThread(uid: uid)) {
                _ = try DatabaseManager.shared.openIfNeeded(for: uid)
            }
        }
        #expect(afterClose.misses.count == 1, "close clears the failure record: an unprepared partition still records a miss")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("A retry after a failed prepare succeeds: it clears the failure record and the main thread gets the database as usual")
    func successfulRetryClearsFailedState() async throws {
        let uid = "prepare-retry-\(UUID().uuidString)"
        defer { DatabaseManager.shared.close() }
        DatabaseManager.shared.close()
        try Self.corruptDatabase(uid: uid)
        var reopened: DatabasePool?
        let result = await productionOpening {
            await #expect(throws: (any Error).self) { _ = try await DatabaseManager.shared.prepare(for: uid) }
            #expect(throws: DatabaseManager.DatabaseUnavailable(uid: uid)) {
                _ = try DatabaseManager.shared.openIfNeeded(for: uid)
            }
            // Repair the database file (an empty file means an empty database), then retry the prepare.
            try? Data().write(to: AppSessionStore.databasePath(for: uid), options: .atomic)
            let prepared = try? await DatabaseManager.shared.prepare(for: uid)
            #expect(prepared != nil, "retry prepare succeeded")
            reopened = try? DatabaseManager.shared.openIfNeeded(for: uid)
        }
        #expect(result.misses.isEmpty, "\(result.misses)")
        let pool = try #require(reopened, "after a successful retry the main thread gets the database as usual")
        #expect(pool.path == AppSessionStore.databasePath(for: uid).path)
        await TestPartitionCleanup.remove(uid)
    }
}
