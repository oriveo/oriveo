import Foundation
import Testing
@testable import Oriveo

/// Production-path session snapshot (JSON decode + Keychain API key read) is not read on the main thread: it is read in the background in `sessionStoreReadyTask`,
/// then handed back to the main thread and installed in memory; before install no snapshot write entry writes, so an empty providers state cannot overwrite the disk snapshot.
/// Test processes default to the sync branch (test host); here `allowsMainThreadFirstOpen` is turned off to take the production path.
@MainActor
@Suite("Session snapshot background read: no main-thread snapshot read, no write before install", .serialized, .sharedProcessState)
struct SessionSnapshotOffMainLoadTests {
    private func production<T>(snapshotDelay: Duration? = nil, _ body: () async throws -> T) async rethrows -> T {
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        let previousDelay = AppState.sessionSnapshotLoadDelayForTesting
        DatabaseManager.allowsMainThreadFirstOpen = false
        AppState.sessionSnapshotLoadDelayForTesting = snapshotDelay
        defer {
            DatabaseManager.allowsMainThreadFirstOpen = previousAllows
            AppState.sessionSnapshotLoadDelayForTesting = previousDelay
        }
        return try await body()
    }

    private static func provider(key: String) -> Provider {
        TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4.1", isDefault: true)],
            apiKey: key,
            apiKeyPreview: "sk-...\(key.suffix(4))"
        )
    }

    /// Seed a session snapshot on disk (API key goes to Keychain, same as production).
    @discardableResult
    private static func seedSnapshot(uid: String, providers: [Provider]) -> AppSessionSnapshot {
        let model = providers.first?.models.first
        let snapshot = AppSessionSnapshot(
            selectedTab: .settings,
            hasCompletedOnboarding: true,
            providers: providers,
            conversations: nil,
            lastUsedModelRef: model.map { LastUsedModelRef(providerID: providers[0].id, modelID: $0.id) },
            folders: [TestFactories.makeFolder(name: "Seeded folder")]
        )
        // Deterministic id migration rewrites random ids; this asserts the snapshot is restored as-is, so mark this partition as already migrated.
        UserDefaults.standard.set(true, forKey: "oriveo.providers.deterministicIDMigrated.\(uid)")
        AppSessionStore.save(snapshot, for: uid)
        return snapshot
    }

    private static func diskSnapshot(_ uid: String) -> AppSessionSnapshot? {
        AppSessionStore.load(for: uid)
    }

    @Test("Production shape: snapshot is not read on the main thread; after ready, each field equals the sync branch field by field (API Key already fetched from Keychain)")
    func productionShapeLoadsOffMainAndMatchesSync() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uid = "snapshot-offmain-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        Self.seedSnapshot(uid: uid, providers: [Self.provider(key: "sk-offmain-1111")])
        defer { DatabaseManager.shared.close() }

        let launched = await production {
            let launched = AppState(sessionUID: uid)
            #expect(!launched.sessionStoreReady, "First frame is still the skeleton")
            #expect(launched.providers.isEmpty, "Snapshot not installed yet: carries no stale values")
            await launched.waitForSessionStore()
            return launched
        }
        #expect(launched.debugSessionSnapshotReadsOnMain == 0, "Production path: zero snapshot reads on the main thread")
        #expect(launched.sessionSnapshotApplied)
        #expect(launched.providers.map(\.apiKey) == ["sk-offmain-1111"], "API Key from Keychain is fetched in the background")
        launched.persistSessionNow()
        DatabaseManager.shared.close()

        // The same disk snapshot goes through the test host sync branch: both paths install the same applySessionSnapshot, field-by-field identical.
        let sync = AppState(sessionUID: uid)
        #expect(sync.debugSessionSnapshotReadsOnMain == 1, "Sync branch does read on the main thread (control group)")
        #expect(launched.providers == sync.providers)
        // Color backfill refreshes updatedAt (in memory with milliseconds, on disk ISO8601 to seconds), so compare by semantic fields.
        #expect(launched.folders.map(\.id) == sync.folders.map(\.id))
        #expect(launched.folders.map(\.colorTag) == sync.folders.map(\.colorTag))
        #expect(launched.folders.map(\.name) == ["Seeded folder"])
        #expect(launched.lastUsedModelRef == sync.lastUsedModelRef)
        #expect(launched.lastUsedModelRef != nil)
        #expect(launched.selectedTab == sync.selectedTab)
        #expect(launched.selectedTab == .settings)
        #expect(launched.hasCompletedOnboarding == sync.hasCompletedOnboarding)
        #expect(launched.hasCompletedOnboarding)
        await TestPartitionCleanup.remove(uid)
        withExtendedLifetime(sync) {}
    }

    @Test("Background / immediate flush / debounced flush before snapshot install: none write the snapshot, the disk snapshot's providers are not overwritten by empty values; checkpoint still runs")
    func backgroundingBeforeApplyDoesNotOverwriteDiskSnapshot() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uid = "snapshot-background-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let seededProvider = Self.provider(key: "sk-background-2222")
        Self.seedSnapshot(uid: uid, providers: [seededProvider])
        defer { DatabaseManager.shared.close() }

        let launched = await production(snapshotDelay: .milliseconds(600)) {
            let launched = AppState(sessionUID: uid)
            #expect(!launched.sessionSnapshotApplied)
            #expect(launched.providers.isEmpty)
            launched.persistLifecycleCriticalData(checkpoint: true)
            launched.enqueueSessionPersist()
            launched.triggerPersistSession()
            await launched.persistSessionNowOffMainThread()
            // Wait out the debounce window (0.3 s); if a debounced write slipped past the guard it would already be on disk.
            try? await Task.sleep(for: .milliseconds(450))
            launched.flushConversationPersistQueue()
            #expect(!launched.sessionSnapshotApplied, "Still reading the snapshot")
            let disk = Self.diskSnapshot(uid)
            #expect(disk?.providers.map(\.id) == [seededProvider.id], "Disk snapshot was not overwritten by empty providers")
            #expect(disk?.folders?.map(\.name) == ["Seeded folder"])
            await launched.waitForSessionStore()
            return launched
        }
        #expect(launched.providers.map(\.id) == [seededProvider.id])
        launched.persistSessionNow()
        #expect(Self.diskSnapshot(uid)?.providers.map(\.apiKey) == ["sk-background-2222"], "Written as usual after install")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Partition switch: no old-partition providers remain while reading the new partition snapshot; old-partition snapshot is not overwritten by empty values; new partition does not mix in old data")
    func partitionSwitchDoesNotLeakOldProviders() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uidA = "snapshot-switch-a-\(UUID().uuidString)"
        let uidB = "snapshot-switch-b-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let providerA = Self.provider(key: "sk-partition-aaaa")
        let providerB = Self.provider(key: "sk-partition-bbbb")
        Self.seedSnapshot(uid: uidA, providers: [providerA])
        Self.seedSnapshot(uid: uidB, providers: [providerB])
        defer { DatabaseManager.shared.close() }

        let state = await production {
            let state = AppState(sessionUID: uidA)
            await state.waitForSessionStore()
            return state
        }
        #expect(state.providers.map(\.id) == [providerA.id])

        await production(snapshotDelay: .milliseconds(400)) {
            state.closeSessionStoreForPartitionSwitch()
            state.loadSession(boundTo: uidB)
            #expect(state.providers.isEmpty, "No old-partition providers shown while reading the new partition snapshot")
            #expect(state.folders.isEmpty)
            #expect(state.lastUsedModelRef == nil)
            #expect(!state.sessionSnapshotApplied)
            state.persistLifecycleCriticalData(checkpoint: false)
            await state.waitForSessionStore()
        }
        #expect(state.debugSessionSnapshotReadsOnMain == 0)
        #expect(state.providers.map(\.id) == [providerB.id])
        #expect(state.providers.map(\.apiKey) == ["sk-partition-bbbb"])
        state.flushConversationPersistQueue()
        #expect(Self.diskSnapshot(uidA)?.providers.map(\.id) == [providerA.id], "Old-partition snapshot intact")
        state.persistSessionNow()
        #expect(Self.diskSnapshot(uidB)?.providers.map(\.id) == [providerB.id], "New-partition snapshot does not mix in old-partition data")
        await TestPartitionCleanup.remove(uidA)
        await TestPartitionCleanup.remove(uidB)
    }

    @Test("Retry with the database already open (blocking page retry) also reads the snapshot in the background: zero main-thread reads, complete data after install")
    func retryWithOpenDatabaseAlsoReadsOffMain() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uid = "snapshot-retry-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let seededProvider = Self.provider(key: "sk-retry-5555")
        Self.seedSnapshot(uid: uid, providers: [seededProvider])
        defer { DatabaseManager.shared.close() }

        let state = await production {
            let state = AppState(sessionUID: uid)
            await state.waitForSessionStore()
            #expect(DatabaseManager.shared.openedPool(for: uid) != nil, "Database is open")
            state.loadSession(boundTo: uid)
            #expect(!state.sessionSnapshotApplied, "Database already open still does not read the snapshot synchronously on the main thread")
            await state.waitForSessionStore()
            return state
        }
        #expect(state.debugSessionSnapshotReadsOnMain == 0)
        #expect(state.sessionStoreReady)
        #expect(state.providers.map(\.id) == [seededProvider.id])
        #expect(state.providers.map(\.apiKey) == ["sk-retry-5555"])
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Same-partition reload: a snapshot write inside the debounce window (0.3 s) is flushed before reading; a just-added provider is not lost (in memory and on disk)")
    func sameUIDReloadSeesPendingDebouncedProviderWrite() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uid = "snapshot-reload-debounce-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let seededProvider = Self.provider(key: "sk-reload-6666")
        let addedProvider = Self.provider(key: "sk-reload-7777")
        Self.seedSnapshot(uid: uid, providers: [seededProvider])
        defer { DatabaseManager.shared.close() }

        let state = await production {
            let state = AppState(sessionUID: uid)
            await state.waitForSessionStore()
            // Adding a provider only schedules a debounced write (flushed after 0.3 s); reload with the same uid immediately within the window (blocking page retry).
            state.providers.append(addedProvider)
            state.loadSession(boundTo: uid)
            await state.waitForSessionStore()
            return state
        }
        #expect(state.providers.map(\.id) == [seededProvider.id, addedProvider.id], "Reloaded snapshot includes the just-added provider")
        #expect(state.providers.last?.apiKey == "sk-reload-7777")
        state.flushConversationPersistQueue()
        #expect(Self.diskSnapshot(uid)?.providers.map(\.id) == [seededProvider.id, addedProvider.id], "Disk snapshot also includes it")
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Same-partition reload: when an immediate write is still queued, drain first, then read the snapshot; a just-added provider is not lost (in memory and on disk)")
    func sameUIDReloadSeesQueuedImmediateWrite() async throws {
        // The unsigned test host cannot access Keychain: API keys go through an in-memory table, everything else follows the production path.
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        let uid = "snapshot-reload-queued-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let seededProvider = Self.provider(key: "sk-reload-8888")
        let addedProvider = Self.provider(key: "sk-reload-9999")
        Self.seedSnapshot(uid: uid, providers: [seededProvider])
        defer { DatabaseManager.shared.close() }

        let state = await production {
            let state = AppState(sessionUID: uid)
            await state.waitForSessionStore()
            // The DB write queue is occupied: the immediate write is queued but not executed; reload with the same uid now.
            let gate = state._testingBlockConversationPersistQueue()
            state.providers.append(addedProvider)
            state.enqueueSessionPersist()
            state.loadSession(boundTo: uid)
            try? await Task.sleep(for: .milliseconds(200))
            gate.signal()
            await state.waitForSessionStore()
            return state
        }
        #expect(state.providers.map(\.id) == [seededProvider.id, addedProvider.id], "Reloaded snapshot includes the just-added provider")
        #expect(state.providers.last?.apiKey == "sk-reload-9999")
        state.flushConversationPersistQueue()
        #expect(Self.diskSnapshot(uid)?.providers.map(\.id) == [seededProvider.id, addedProvider.id], "Disk snapshot also includes it")
        await TestPartitionCleanup.remove(uid)
    }
}
