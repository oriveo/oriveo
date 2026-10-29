import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Runtime half of the main-thread database write gate: stack frame parsing, verdicts, and real stacks through the trace
/// installed by `DatabaseSchema.makeConfiguration`.
@MainActor
@Suite("Main-thread database write gate", .serialized)
struct MainThreadDatabaseWriteGuardTests {
    // MARK: - Stack frame parsing

    @Test func frame_parsing_attributes_closures_and_grdb_entries() {
        let closure = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "closure #1 (GRDB.Database) throws -> [Swift.String] in Oriveo.ContextCompactionStore.invalidate(conversationId: Swift.String, historyIds: [Swift.String], affectedIds: [Swift.String]) throws -> [Swift.String]"
        )
        #expect(closure == .init(module: "Oriveo", owner: "ContextCompactionStore.invalidate", isWriteEntry: false))

        let staticMethod = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "static Oriveo.RecipeContinuationRuntime.markInterrupted(messageID: Foundation.UUID) throws -> ()"
        )
        #expect(staticMethod.owner == "RecipeContinuationRuntime.markInterrupted")

        let generic = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "Oriveo.ConversationStore.write<A>((GRDB.Database) throws -> A) throws -> A"
        )
        #expect(generic.owner == "ConversationStore.write")

        let entry = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "(extension in GRDB):GRDB.DatabaseWriter.write<A>((GRDB.Database) throws -> A) throws -> A"
        )
        #expect(entry.module == "GRDB")
        #expect(entry.isWriteEntry)

        let initializer = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "Oriveo.RecipeContinuationStore.__allocating_init(dbPool: GRDB.DatabasePool) -> Oriveo.RecipeContinuationStore"
        )
        #expect(initializer.owner == "RecipeContinuationStore.init")

        let getter = MainThreadDatabaseWriteGuard.frame(fromDemangled: "Oriveo.AppState.conversations.getter : [Oriveo.Conversation]")
        #expect(getter.module == "Oriveo")
        #expect(getter.owner == nil)

        #expect(MainThreadDatabaseWriteGuard.frame(fromDemangled: "_dispatch_sync_f_slow").module != "Oriveo")
        #expect(MainThreadDatabaseWriteGuard.demangle("$s6Oriveo8AppStateC5stuffyyF") == "Oriveo.AppState.stuff() -> ()")
    }

    /// Frames of an async function resumed after a suspension must still resolve to their module: a direct test caller is
    /// exempt rather than an app path with caller "?".
    @Test func async_resume_frames_are_attributed() {
        let frame = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "(1) await resume partial function for OriveoTests.ContextCompactionStoreTests.prunes() async throws -> ()"
        )
        #expect(frame.module == "OriveoTests")
        #expect(frame.owner == "ContextCompactionStoreTests.prunes")
        let app = MainThreadDatabaseWriteGuard.frame(fromDemangled:
            "(2) suspend resume partial function for Oriveo.ChatManager.recordMcpToolStep(_: Oriveo.McpToolStepUpdate) async -> ()"
        )
        #expect(app.owner == "ChatManager.recordMcpToolStep")
    }

    // MARK: - Verdicts

    private static let writeEntry = [
        "GRDB.SerializedDatabase.sync<A>((GRDB.Database) throws -> A) throws -> A",
        "GRDB.DatabasePool.writeWithoutTransaction<A>((GRDB.Database) throws -> A) throws -> A",
        "(extension in GRDB):GRDB.DatabaseWriter.write<A>((GRDB.Database) throws -> A) throws -> A",
    ]

    private func classify(_ outer: [String]) -> MainThreadDatabaseWriteGuard.Verdict {
        let frames = (["_dispatch_sync_f_slow"] + Self.writeEntry + outer).map(MainThreadDatabaseWriteGuard.frame(fromDemangled:))
        return MainThreadDatabaseWriteGuard.classify(frames: frames)
    }

    @Test func known_method_called_from_app_code_on_main_is_a_violation() {
        let verdict = classify([
            "Oriveo.ContextCompactionStore.invalidate(conversationId: Swift.String) throws -> [Swift.String]",
            "Oriveo.ContextCompactionStore.invalidateAndPropagate(conversationId: Swift.String) -> [Swift.String]",
            "Oriveo.AppState.retryMessage(messageID: Foundation.UUID) async -> ()",
        ])
        #expect(verdict == .violation(key: "ContextCompactionStore.invalidate", caller: "AppState.retryMessage"))
    }

    @Test func store_api_called_directly_by_tests_is_exempt() {
        let verdict = classify([
            "Oriveo.ContextLedgerStore.appendManifest(OriveoProviderKit.ContextManifest) throws -> ()",
            "OriveoTests.ContextLedgerStoreTests.prunes() throws -> ()",
        ])
        #expect(verdict == .exemptTestCaller)
    }

    /// ConversationRuntimeBridge only resolves the store by uid and forwards: a test seeding through the bridge is a test
    /// caller, while the app calling through the bridge is still judged by the app caller.
    @Test func conversation_bridge_is_skipped_when_attributing_callers() {
        let store = "Oriveo.ConversationStore.replaceAllConversations(_: [Oriveo.Conversation], keepingUnlistedIDs: Swift.Set<Foundation.UUID>) throws -> ()"
        let bridge = "Oriveo.ConversationRuntimeBridge.replaceAllConversations(_: [Oriveo.Conversation], uid: Swift.String, keepingUnlistedIDs: Swift.Set<Foundation.UUID>) throws -> [Oriveo.Conversation]"
        #expect(classify([store, bridge, "OriveoTests.SomeTests.seeds() throws -> ()"]) == .exemptTestCaller)
        #expect(classify([store, bridge, "Oriveo.AppState.loadSession(boundTo: Swift.String?, startsAttachmentCleanup: Swift.Bool) -> ()"])
            == .violation(key: "ConversationStore.replaceAllConversations", caller: "AppState.loadSession"))
    }

    /// The debt is empty: every known synchronous write method is a violation on the main thread; the forwarding wrapper
    /// (ConversationStore.write) is skipped when taking the key.
    @Test func debt_is_empty_and_wrappers_are_skipped() {
        #expect(MainThreadDatabaseWriteAllowlist.mainThreadDebt.isEmpty, "Debt may only shrink; new synchronous writes are forbidden on the main thread")
        let verdict = classify([
            "Oriveo.ConversationStore.write<A>((GRDB.Database) throws -> A) throws -> A",
            "Oriveo.ConversationStore.updateTitle(id: Foundation.UUID, title: Swift.String, hasCustomTitle: Swift.Bool) throws -> ()",
            "Oriveo.AppState.something() -> ()",
        ])
        #expect(verdict == .violation(key: "ConversationStore.updateTitle", caller: "AppState.something"))
    }

    /// Unregistered methods are judged by the call chain too: reached through an `xxxForTesting` seam, or forwarded to a
    /// test through ConversationStore / the bridge, they are test callers and are not logged.
    @Test func unregistered_method_reached_only_from_tests_is_exempt() {
        let sidecar = "Oriveo.RecipeContinuationStore.purgeOrphans(for: Swift.String, parentPool: GRDB.DatabasePool) throws -> ()"
        let store = "Oriveo.ConversationStore.replaceAllConversations(_: [Oriveo.Conversation], keepingUnlistedIDs: Swift.Set<Foundation.UUID>) throws -> ()"
        #expect(classify([sidecar, store, "OriveoTests.SomeTests.seeds() throws -> ()"]) == .exemptTestCaller)
        let seam = "Oriveo.ChatManager.debugInvokePartialPreservationGuardForTesting(messageID: Foundation.UUID) -> ()"
        #expect(classify([
            "Oriveo.RecipeContinuationStore.init() throws -> Oriveo.RecipeContinuationStore",
            "static Oriveo.RecipeContinuationRuntime.markInterrupted(messageID: Foundation.UUID) throws -> ()", seam,
        ]) == .exemptTestCaller)
        #expect(classify([sidecar, store, "Oriveo.AppState.loadSession(boundTo: Swift.String?, startsAttachmentCleanup: Swift.Bool) -> ()"])
            == .unknown("RecipeContinuationStore.purgeOrphans"), "App paths are still logged")
    }

    @Test func unregistered_method_is_reported_not_failed() {
        let verdict = classify(["Oriveo.SomeNewStore.save() throws -> ()", "Oriveo.AppState.something() -> ()"])
        #expect(verdict == .unknown("SomeNewStore.save"))
    }

    @Test func forbidden_keys_are_known_and_not_debt() {
        for key in [
            "ContextCompactionStore.invalidate", "ContextLedgerStore.appendManifest", "ContextLedgerStore.saveRho",
            "RecipeContinuationStore.discard", "MemoryItemRepository.performIfWritten", "ContextShots.buildIsolatedPartition",
        ] {
            #expect(MainThreadDatabaseWriteAllowlist.known.contains(key), "\(key)")
            #expect(!MainThreadDatabaseWriteAllowlist.mainThreadDebt.contains(key), "\(key)")
        }
    }

    // MARK: - Real stacks (the trace sits on the write connections from DatabaseSchema.makeConfiguration)

    /// Swaps the assertion for a collector; restores it afterwards.
    private func capturingViolations(_ body: () async throws -> Void) async rethrows -> [String] {
        var captured: [String] = []
        let previous = MainThreadDatabaseWriteGuard.violationHandler
        MainThreadDatabaseWriteGuard.violationHandler = { captured.append($0) }
        defer { MainThreadDatabaseWriteGuard.violationHandler = previous }
        try await body()
        MainThreadDatabaseWriteGuard.drain()
        return captured
    }

    @Test func real_stack_async_and_direct_test_calls_pass() async throws {
        #expect(Thread.isMainThread)
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let ids = (0..<4).map { "m\($0)" }
        let store = ContextCompactionStore(dbPool: database.pool)
        let violations = try await capturingViolations {
            _ = try store.invalidate(conversationId: conversation, historyIds: ids, affectedIds: ["m2"])
            _ = await store.invalidateAndPropagateAsync(conversationId: conversation, historyIds: ids, affectedIds: ["m2"])
        }
        #expect(violations.isEmpty)
    }

    /// Streaming interrupts and explicit-continuation acknowledgements run on the main thread: their sidecar writes are
    /// queued or awaited, never synchronous.
    @Test func recipe_continuation_main_thread_paths_do_not_write_synchronously() async throws {
        #expect(!MainThreadDatabaseWriteAllowlist.mainThreadDebt.contains("RecipeContinuationStore.discard"))
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let parent = try database.insertConversation(messageCount: 1)
        let messageID = try #require(parent.messages.first)
        let orphanID = UUID()
        let sidecar = try DatabasePool(
            path: database.directory.appendingPathComponent("sidecar.sqlite").path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let store = try RecipeContinuationStore(dbPool: sidecar, parentPool: database.pool)
        let state: [String: MetadataClient.JSONValue] = ["previousResponseId": .string("resp_1")]
        try store.save(messageID: messageID, kind: "previous_id", state: state)
        try store.save(messageID: orphanID, kind: "previous_id", state: state)

        var acknowledged = false
        let violations = try await capturingViolations {
            let (orphan, token) = await RecipeContinuationRuntime.withStore(store) {
                // The parent message is gone: the read reports nil and the cleanup is queued on the writer.
                await MainActor.run {
                    (
                        RecipeContinuationRuntime.explicitConsumptionToken(explicitMessageID: orphanID),
                        RecipeContinuationRuntime.explicitConsumptionToken(explicitMessageID: messageID)
                    )
                }
            }
            #expect(orphan == nil)
            let consumed = try #require(token)
            acknowledged = try await RecipeContinuationRuntime.withStore(store) {
                try await RecipeContinuationRuntime.acknowledgeExplicitConsumption(consumed)
            }
        }
        #expect(violations.isEmpty, "\(violations)")
        #expect(acknowledged)

        // The interrupt mark is queued on the writer: enqueueing fixes the order, so it has landed once a later write lands.
        try store.save(messageID: messageID, kind: "previous_id", state: state)
        let interruptViolations = try await capturingViolations {
            try await RecipeContinuationRuntime.withStore(store) {
                try await MainActor.run { try RecipeContinuationRuntime.markInterrupted(messageID: messageID) }
            }
        }
        #expect(interruptViolations.isEmpty, "\(interruptViolations)")
        try await sidecar.write { _ in }
        #expect(try store.load(messageID: messageID)?.interrupted == true)
        let orphanRows = try await sidecar.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message_recipe_continuation WHERE messageID = ?",
                arguments: [orphanID.uuidString]
            )
        }
        #expect(orphanRows == 0, "The continuation row of a deleted parent message is removed by the queued cleanup")
        try sidecar.close()
    }
}
