import Foundation
import Testing
@testable import Oriveo

/// When the production path reloads the same partition, the recovery snapshot must be read only after the write queue drains,
/// so a recovery snapshot write still pending in the queue is never missed.
/// Retries with the database already open also read in the background; the main thread reads no recovery snapshot.
@MainActor
@Suite("Recovery snapshot: read after the write queue drains, read in background", .serialized)
struct RecoverySnapshotOrderingTests {
    /// Turns off the test host's synchronous first open to take the production path (same as DatabasePrepareOffMainTests.productionOpening).
    private func productionOpening(_ body: () async throws -> Void) async rethrows {
        let previousAllows = DatabaseManager.allowsMainThreadFirstOpen
        DatabaseManager.allowsMainThreadFirstOpen = false
        defer { DatabaseManager.allowsMainThreadFirstOpen = previousAllows }
        try await body()
    }

    private static func message(_ text: String) -> ChatMessage {
        TestFactories.makeMessage(text: text)
    }

    @Test("Reloading the session for the same uid: a recovery snapshot write delayed in the write queue is visible in the session once ready")
    func recoveryReadWaitsForPendingPersistDrain() async throws {
        let uid = "recovery-order-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let stale = TestFactories.makeConversation(title: "Stale", hasCustomTitle: true, messages: [Self.message("old")])
        let fresh = TestFactories.makeConversation(title: "Fresh", hasCustomTitle: true, messages: [Self.message("new")])
        try ConversationRuntimeBridge().persistRecoveryProjectionOnly([stale], for: uid)

        var state: AppState?
        try await productionOpening {
            let launched = AppState(sessionUID: uid)
            state = launched
            await launched.waitForSessionStore()
            await ConversationRuntimeBridge.waitForRecoverySnapshotsForTesting()
            #expect(launched.conversations.map(\.id).contains(stale.id), "first load installs the stale recovery snapshot")

            // Queue a "delayed persist" on the write queue: later queue items proceed only after the recovery snapshot write finishes.
            let gate = launched._testingBlockConversationPersistQueue()
            launched.loadSession(boundTo: uid, startsAttachmentCleanup: false)
            let writer = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                try ConversationRuntimeBridge().persistRecoveryProjectionOnly([stale, fresh], for: uid)
                gate.signal()
            }
            await launched.waitForSessionStore()
            try await writer.value
            #expect(launched.sessionStoreReady)
            #expect(launched.conversations.map(\.id).contains(fresh.id), "recovery snapshot is read only after the write queue drains")
            launched.flushConversationPersistQueue()
            await ConversationRuntimeBridge.waitForRecoverySnapshotsForTesting()
        }
        withExtendedLifetime(state) {}
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Retrying loadSession with the database already open: the recovery snapshot is not read on the main thread")
    func retryWithOpenDatabaseReadsRecoveryOffMain() async throws {
        let uid = "recovery-retry-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let stored = TestFactories.makeConversation(title: "Recovered", hasCustomTitle: true, messages: [Self.message("hi")])
        try ConversationRuntimeBridge().persistRecoveryProjectionOnly([stored], for: uid)

        var state: AppState?
        let readsBefore = ConversationRuntimeBridge.debugRecoveryReadOnMainCount
        await productionOpening {
            let launched = AppState(sessionUID: uid)
            state = launched
            await launched.waitForSessionStore()
            #expect(DatabaseManager.shared.openedPool(for: uid) != nil, "database is open after the first load")
            launched.loadSession(boundTo: uid, startsAttachmentCleanup: false)
            await launched.waitForSessionStore()
            #expect(launched.sessionStoreReady)
            #expect(launched.conversations.map(\.id).contains(stored.id))
            launched.flushConversationPersistQueue()
            await ConversationRuntimeBridge.waitForRecoverySnapshotsForTesting()
        }
        #expect(ConversationRuntimeBridge.debugRecoveryReadOnMainCount - readsBefore == 0, "recovery snapshot is not read on the main thread")
        withExtendedLifetime(state) {}
        await TestPartitionCleanup.remove(uid)
    }
}
