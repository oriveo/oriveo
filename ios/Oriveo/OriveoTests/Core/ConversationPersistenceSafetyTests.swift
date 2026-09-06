import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("ConversationPersistenceSafety", .serialized)
struct ConversationPersistenceSafetyTests {

    @Test("debounced persist binds writes to the scheduled partition")
    @MainActor
    func debouncedPersistStaysInOriginalPartition() async throws {
        let previousUID = AppSessionStore.activeUID
        let sourceUID = "persist-source-\(UUID().uuidString)"
        let targetUID = "persist-target-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(title: "Scheduled Persist")
        let sourceSnapshotURL = AppSessionStore.snapshotPath(for: sourceUID)

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: sourceUID))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: targetUID))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: sourceUID)
        state.conversations = [conversation]

        AppSessionStore.switchToUser(targetUID)
        try await waitUntil {
            FileManager.default.fileExists(atPath: sourceSnapshotURL.path)
        }
        DatabaseManager.shared.close()

        let sourceStore = try makeStore(uid: sourceUID)
        let sourceSnapshot = try decodeSnapshot(at: sourceSnapshotURL)

        #expect(try sourceStore.fetchConversationCount() == 0)
        #expect(sourceSnapshot.selectedTab == state.selectedTab)
        #expect(sourceSnapshot.providers.isEmpty)
        #expect(sourceSnapshot.conversations == nil)
    }

    @Test("deinit cancels pending debounced persist before the scheduled write fires")
    @MainActor
    func deinitCancelsPendingDebouncedPersist() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "persist-deinit-\(UUID().uuidString)"
        let snapshotURL = AppSessionStore.snapshotPath(for: uid)
        weak var releasedState: AppState?

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: snapshotURL)

        do {
            let state = AppState(sessionUID: uid)
            releasedState = state

            state.selectedTab = .providers

            #expect(FileManager.default.fileExists(atPath: snapshotURL.path) == false)
        }

        #expect(releasedState == nil)

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path) == false)
    }

    @Test("loadSession falls back to recovery projection when SQLite becomes unreadable")
    @MainActor
    func loadSessionFallsBackToRecoveryProjection() throws {
        let uid = "persist-recovery-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(title: "Recovered Conversation")

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.conversations = [conversation]
        state.persistSessionNow()

        DatabaseManager.shared.close()
        try Data("not-a-valid-sqlite".utf8).write(
            to: AppSessionStore.databasePath(for: uid),
            options: .atomic
        )

        let recovered = AppState(sessionUID: uid)

        #expect(recovered.conversations.count == 1)
        #expect(recovered.conversations.first?.id == conversation.id)
        #expect(recovered.conversations.first?.title == "Recovered Conversation")
    }

    @Test("loadSession merges fresher recovery projection even when SQLite is readable")
    @MainActor
    func loadSessionMergesFresherRecoveryProjectionWhenSQLiteIsReadable() throws {
        let uid = "persist-recovery-merge-\(UUID().uuidString)"
        let conversationID = UUID()
        let staleMessage = TestFactories.makeMessage(role: .user, text: "stale")
        let freshUserMessage = TestFactories.makeMessage(role: .user, text: "fresh user")
        let freshAssistantMessage = TestFactories.makeMessage(role: .assistant, text: "fresh assistant")
        let staleUpdatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let freshUpdatedAt = staleUpdatedAt.addingTimeInterval(120)

        let staleConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Stale",
            messages: [staleMessage],
            updatedAt: staleUpdatedAt
        )
        let freshConversation = TestFactories.makeConversation(
            id: conversationID,
            title: "Fresh",
            messages: [staleMessage, freshUserMessage, freshAssistantMessage],
            updatedAt: freshUpdatedAt
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let bridge = ConversationRuntimeBridge()
        try bridge.persistLegacyProjection([staleConversation], for: uid)
        try bridge.persistRecoveryProjectionOnly([freshConversation], for: uid)
        DatabaseManager.shared.close()

        let recovered = AppState(sessionUID: uid)
        let restored = try #require(recovered.conversations.first(where: { $0.id == conversationID }))

        #expect(restored.title == "Fresh")
        #expect(restored.displayMessageCount == 3)
        #expect(restored.messages.count == 3)
        #expect(restored.updatedAt == freshUpdatedAt)
    }

    @Test("Conversation changes no longer trigger a full recovery snapshot write")
    @MainActor
    func conversationMutationDoesNotWriteRecoverySnapshot() async throws {
        let uid = "persist-recovery-hotpath-\(UUID().uuidString)"
        let recoveryURL = AppSessionStore.recoverySnapshotPath(for: uid)
        let conversation = TestFactories.makeConversation(
            title: "Hot Path",
            messages: [TestFactories.makeMessage(role: .user, text: "latest body")]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let snapshotURL = AppSessionStore.snapshotPath(for: uid)
        let state = AppState(sessionUID: uid)
        try? FileManager.default.removeItem(at: recoveryURL)
        try? FileManager.default.removeItem(at: snapshotURL)

        state.conversations = [conversation]

        // The mutation schedules one debounced session write. Waiting for that write to land is
        // what makes the negative assertion below meaningful: the persistence pass has run, so an
        // absent recovery snapshot means it was never part of that pass.
        try await waitUntil {
            FileManager.default.fileExists(atPath: snapshotURL.path)
        }
        #expect(
            FileManager.default.fileExists(atPath: recoveryURL.path) == false,
            "conversations changes must not trigger a full-store recovery snapshot write"
        )
    }

    @Test("Backgrounding still forces a full recovery snapshot (fallback so nothing is lost)")
    @MainActor
    func lifecyclePersistStillWritesRecoverySnapshot() async throws {
        let uid = "persist-recovery-lifecycle-\(UUID().uuidString)"
        let recoveryURL = AppSessionStore.recoverySnapshotPath(for: uid)
        let conversation = TestFactories.makeConversation(
            title: "Lifecycle Recovery",
            messages: [TestFactories.makeMessage(role: .user, text: "latest body")]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.conversations = [conversation]
        try? FileManager.default.removeItem(at: recoveryURL)

        state.persistLifecycleCriticalData(checkpoint: false)

        try await waitUntil {
            FileManager.default.fileExists(atPath: recoveryURL.path)
        }
        let recovery = try decodeRecoverySnapshot(at: recoveryURL)
        #expect(recovery.conversations.contains { $0.id == conversation.id })
    }

    @Test("loadSession sanitizes stale .generating assistant messages into .interrupted on relaunch")
    @MainActor
    func loadSessionSanitizesStaleGeneratingMessages() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "sanitize-stale-\(UUID().uuidString)"
        let conversationID = UUID()
        let assistantMessageID = UUID()
        let userMessageID = UUID()

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        do {
            let state = AppState(sessionUID: uid)
            let userMessage = TestFactories.makeMessage(
                id: userMessageID, role: .user, text: "Hello", state: .delivered
            )
            let assistantMessage = TestFactories.makeMessage(
                id: assistantMessageID, role: .assistant, text: "Partial reply before crash", state: .generating
            )
            state.upsertConversationProjection(
                TestFactories.makeConversation(id: conversationID, messages: [userMessage, assistantMessage])
            )
            state.persistSessionNow()
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)

        let conversation = try #require(state.conversations.first(where: { $0.id == conversationID }))
        let recoveredAssistant = try #require(conversation.messages.first(where: { $0.id == assistantMessageID }))
        let recoveredUser = try #require(conversation.messages.first(where: { $0.id == userMessageID }))

        #expect(recoveredAssistant.state == .interrupted)
        #expect(recoveredAssistant.text == "Partial reply before crash")
        #expect(recoveredUser.state == .delivered)
    }

    @Test("queueAssistantResponse persists previous streaming partial as .interrupted before starting new send")
    @MainActor
    func queueAssistantResponsePersistsPreviousPartialAsInterrupted() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let oldAssistantMID = UUID()
        let oldAssistant = TestFactories.makeMessage(
            id: oldAssistantMID, role: .assistant, text: "", state: .generating
        )
        state.conversations = [
            TestFactories.makeConversation(id: conversationID, messages: [oldAssistant])
        ]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversationID,
            messageID: oldAssistantMID,
            text: "previous partial reply"
        )

        let newAssistantMID = UUID()
        state.chatManager.debugInvokePartialPreservationGuardForTesting(
            conversationID: conversationID,
            newMessageID: newAssistantMID
        )

        let oldMsg = state.conversations[0].messages.first { $0.id == oldAssistantMID }
        #expect(oldMsg?.state == .interrupted)
        #expect(oldMsg?.text == "previous partial reply")
    }

    @Test("continueMessage path keeps streaming state intact when same message ID is reused")
    @MainActor
    func continueMessagePathKeepsStreamingStateIntact() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let assistantMID = UUID()
        let assistant = TestFactories.makeMessage(
            id: assistantMID, role: .assistant, text: "", state: .generating
        )
        state.conversations = [
            TestFactories.makeConversation(id: conversationID, messages: [assistant])
        ]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversationID,
            messageID: assistantMID,
            text: "partial"
        )

        state.chatManager.debugInvokePartialPreservationGuardForTesting(
            conversationID: conversationID,
            newMessageID: assistantMID
        )

        let msg = state.conversations[0].messages.first { $0.id == assistantMID }
        #expect(msg?.state == .generating)
    }

    @Test("forceStopStreaming interrupts streaming and flushes buffered text into the message")
    @MainActor
    func forceStopStreamingInterruptsStreamingMessage() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let assistantMessageID = UUID()
        let assistantMessage = TestFactories.makeMessage(
            id: assistantMessageID,
            role: .assistant,
            text: "",
            state: .generating
        )

        state.conversations = [
            TestFactories.makeConversation(
                id: conversationID,
                messages: [assistantMessage]
            )
        ]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversationID,
            messageID: assistantMessageID,
            text: "buffered partial reply"
        )

        state.chatManager.forceStopStreaming()

        #expect(state.chatManager.isAnyStreaming == false)
        #expect(state.conversations[0].messages[0].text == "buffered partial reply")
        #expect(state.conversations[0].messages[0].state == .interrupted)
    }

    @Test("forceStopStreaming interrupts the tracked streaming message even if another assistant is also generating")
    @MainActor
    func forceStopStreamingInterruptsTrackedStreamingMessage() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let streamingMessageID = UUID()
        let otherGeneratingMessageID = UUID()
        let firstAssistant = TestFactories.makeMessage(
            id: streamingMessageID,
            role: .assistant,
            text: "",
            state: .generating
        )
        let secondAssistant = TestFactories.makeMessage(
            id: otherGeneratingMessageID,
            role: .assistant,
            text: "",
            state: .generating
        )

        state.conversations = [
            TestFactories.makeConversation(
                id: conversationID,
                messages: [firstAssistant, secondAssistant]
            )
        ]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversationID,
            messageID: streamingMessageID,
            text: "tracked partial reply"
        )

        state.chatManager.forceStopStreaming()

        let updatedConversation = try? #require(state.conversations.first(where: { $0.id == conversationID }))
        let interruptedMessage = updatedConversation?.messages.first(where: { $0.id == streamingMessageID })
        let untouchedMessage = updatedConversation?.messages.first(where: { $0.id == otherGeneratingMessageID })

        #expect(interruptedMessage?.state == .interrupted)
        #expect(interruptedMessage?.text == "tracked partial reply")
        #expect(untouchedMessage?.state == .generating)
        #expect(untouchedMessage?.text.isEmpty == true)
    }

    @Test("stale non-streaming completion cannot overwrite an interrupted message after forceStopStreaming")
    @MainActor
    func staleNonStreamingCompletionIsIgnoredAfterForceStop() {
        let state = AppState(seedDemoData: true)
        let conversationID = UUID()
        let assistantMessageID = UUID()
        let staleTaskID = UUID()
        let assistantMessage = TestFactories.makeMessage(
            id: assistantMessageID,
            role: .assistant,
            text: "",
            state: .generating
        )

        state.conversations = [
            TestFactories.makeConversation(
                id: conversationID,
                messages: [assistantMessage]
            )
        ]

        state.chatManager.debugInstallStreamingStateForTesting(
            conversationID: conversationID,
            messageID: assistantMessageID,
            text: ""
        )
        state.chatManager.debugInstallActiveSendTaskIDForTesting(
            conversationID: conversationID,
            messageID: assistantMessageID,
            taskID: staleTaskID
        )

        state.chatManager.forceStopStreaming()
        state.chatManager.debugApplyNonStreamingCompletionForTesting(
            taskID: staleTaskID,
            conversationID: conversationID,
            messageID: assistantMessageID,
            result: ProviderChatResult(
                text: "late image result",
                promptTokens: 10,
                completionTokens: 20,
                estimatedCost: 0.42
            )
        )

        #expect(state.conversations[0].messages[0].state == .interrupted)
        #expect(state.conversations[0].messages[0].text.isEmpty)
        #expect(state.conversations[0].messages[0].estimatedCost == 0)
    }

    @Test("upsertConversationProjection writes through store and updates the in-memory mirror")
    @MainActor
    func upsertConversationProjectionWritesThroughStore() throws {
        let uid = "projection-upsert-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(
            title: "Original",
            messages: [TestFactories.makeMessage(role: .user, text: "projection prompt", estimatedCost: 0.2)]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.upsertConversationProjection(conversation)

        #expect(state.conversations.first?.id == conversation.id)
        #expect(state.conversations.first?.title == "projection prompt")

        state.flushConversationPersistQueue()

        let stored = try #require(try makeStore(uid: uid).fetchConversationThread(id: conversation.id))
        #expect(stored.summary.title == "projection prompt")
        #expect(abs(stored.summary.estimatedCost - 0.2) < 0.000_001)
    }

    @Test("upsertConversationProjection stays bound to the AppState partition after activeUID changes")
    @MainActor
    func upsertConversationProjectionStaysBoundToOriginalPartition() throws {
        let previousUID = AppSessionStore.activeUID
        let sourceUID = "projection-bound-source-\(UUID().uuidString)"
        let targetUID = "projection-bound-target-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(
            title: "Bound Projection",
            messages: [TestFactories.makeMessage(role: .user, text: "bound body", estimatedCost: 0.3)]
        )

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: sourceUID))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: targetUID))
        }

        DatabaseManager.shared.close()
        let state = AppState(sessionUID: sourceUID)

        AppSessionStore.switchToUser(targetUID)
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()

        let sourceStore = try makeStore(uid: sourceUID)
        let targetStore = try makeStore(uid: targetUID)
        let stored = try #require(try sourceStore.fetchConversationThread(id: conversation.id))

        #expect(stored.summary.title == "bound body")
        #expect(try targetStore.fetchConversationCount() == 0)
    }

    @Test("setConversationUseMemory writes through store and updates the in-memory mirror")
    @MainActor
    func setConversationUseMemoryWritesThroughStore() throws {
        let uid = "projection-memory-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(
            title: "Memory Projection",
            messages: [TestFactories.makeMessage(role: .user, text: "remember this", estimatedCost: 0.1)]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()

        state.setConversationUseMemory(conversation.id, useMemory: false)

        let stored = try #require(try makeStore(uid: uid).fetchConversationThread(id: conversation.id))
        #expect(state.conversations.first?.id == conversation.id)
        #expect(state.conversations.first?.useMemory == false)
        #expect(stored.summary.useMemory == false)
    }

    @Test("setConversationUseMemory reads authoritative store when the mirror cache is empty")
    @MainActor
    func setConversationUseMemoryReadsAuthoritativeStoreWhenMirrorIsEmpty() throws {
        let uid = "projection-memory-authoritative-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(
            title: "Authoritative Memory Projection",
            messages: [TestFactories.makeMessage(role: .user, text: "store only memory toggle", estimatedCost: 0.1)]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        try makeStore(uid: uid).replaceAllConversations([conversation])

        #expect(state.conversations.isEmpty)

        state.setConversationUseMemory(conversation.id, useMemory: false)

        let stored = try #require(try makeStore(uid: uid).fetchConversationThread(id: conversation.id))
        #expect(state.conversations.first?.id == conversation.id)
        #expect(state.conversations.first?.useMemory == false)
        #expect(stored.summary.useMemory == false)
    }

    @Test("selectModel writes through fine-grained model update and preserves thread content")
    @MainActor
    func selectModelWritesThroughFineGrainedModelUpdate() throws {
        let uid = "projection-select-model-\(UUID().uuidString)"
        let provider = TestFactories.makeProvider(
            models: [
                TestFactories.makeModel(id: "gpt-4o", isDefault: true),
                TestFactories.makeModel(id: "gpt-4o-mini")
            ]
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id,
            modelID: "gpt-4o",
            messages: [TestFactories.makeMessage(role: .user, text: "keep thread intact")]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()

        let originalUpdatedAt = try #require(state.conversations.first?.updatedAt)
        let storedBefore = try #require(try makeStore(uid: uid).fetchConversationThread(id: conversation.id))

        state.selectModel(modelID: "gpt-4o-mini", providerID: provider.id, for: conversation.id)
        state.flushConversationPersistQueue()

        let stored = try #require(try makeStore(uid: uid).fetchConversationThread(id: conversation.id))
        let updatedConversation = try #require(state.conversations.first(where: { $0.id == conversation.id }))

        #expect(updatedConversation.modelID == "gpt-4o-mini")
        #expect(updatedConversation.updatedAt == originalUpdatedAt)
        #expect(stored.summary.updatedAt == storedBefore.summary.updatedAt)
        #expect(updatedConversation.messages.map(\.id) == conversation.messages.map(\.id))

        #expect(stored.summary.modelID == "gpt-4o-mini")
        #expect(stored.messages.map(\.id) == conversation.messages.map(\.id))
    }

    @Test("v25/v26 local tool-call columns round-trip through ConversationStore")
    @MainActor
    func toolCallLocalColumnsRoundTrip() throws {
        let uid = "toolcall-columns-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid)) }
        var assistant = TestFactories.makeMessage(role: .assistant, text: "", estimatedCost: 0)
        assistant.unhandledToolCalls = [
            UnhandledToolCall(id: "call_r2_weather", name: "get_weather", arguments: #"{"city":"Melbourne"}"#),
            UnhandledToolCall(id: nil, name: "get_time", arguments: ""),
        ]
        let conversation = TestFactories.makeConversation(
            title: "Tool columns",
            messages: [TestFactories.makeMessage(role: .user, text: "weather", estimatedCost: 0), assistant]
        )

        let store = try makeStore(uid: uid)
        try store.upsertConversation(conversation)
        let stored = try #require(try store.fetchConversationThread(id: conversation.id))
        let restored = try #require(stored.messages.first { $0.id == assistant.id })
        #expect(restored.unhandledToolCalls == assistant.unhandledToolCalls)

        var cleared = conversation
        cleared.messages[1].unhandledToolCalls = nil
        try store.upsertConversation(cleared)
        let clearedStored = try #require(try store.fetchConversationThread(id: conversation.id))
        #expect(clearedStored.messages.first { $0.id == assistant.id }?.unhandledToolCalls == nil)
    }

    @Test("replaceConversationProjection stays bound to the AppState partition after activeUID changes")
    @MainActor
    func replaceConversationProjectionStaysBoundToOriginalPartition() throws {
        let previousUID = AppSessionStore.activeUID
        let sourceUID = "projection-replace-source-\(UUID().uuidString)"
        let targetUID = "projection-replace-target-\(UUID().uuidString)"
        let conversation = TestFactories.makeConversation(
            title: "Replace Projection",
            messages: [TestFactories.makeMessage(role: .user, text: "replace body", estimatedCost: 0.4)]
        )

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: sourceUID))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: targetUID))
        }

        DatabaseManager.shared.close()
        let state = AppState(sessionUID: sourceUID)

        AppSessionStore.switchToUser(targetUID)
        state.replaceConversationProjection([conversation])
        state.flushConversationPersistQueue()

        let sourceStore = try makeStore(uid: sourceUID)
        let targetStore = try makeStore(uid: targetUID)
        let stored = try #require(try sourceStore.fetchConversationThread(id: conversation.id))

        #expect(stored.summary.title == "Replace Projection")
        #expect(stored.messages.first?.text == "replace body")
        #expect(try targetStore.fetchConversationCount() == 0)
    }

    @Test("persistSessionNow does not overwrite the authoritative store from a stale legacy mirror")
    @MainActor
    func persistSessionNowDoesNotOverwriteAuthoritativeStoreFromStaleMirror() throws {
        let uid = "persist-no-backwrite-\(UUID().uuidString)"
        let authoritativeConversation = TestFactories.makeConversation(
            title: "Authoritative",
            messages: [TestFactories.makeMessage(role: .user, text: "authoritative body", estimatedCost: 1.2)]
        )
        let staleMirrorConversation = TestFactories.makeConversation(
            id: authoritativeConversation.id,
            title: "Stale Mirror",
            messages: [TestFactories.makeMessage(role: .user, text: "stale body", estimatedCost: 0.1)]
        )

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.upsertConversationProjection(authoritativeConversation)
        state.conversations = [staleMirrorConversation]

        state.persistSessionNow()

        let stored = try #require(try makeStore(uid: uid).fetchConversationThread(id: authoritativeConversation.id))
        #expect(stored.summary.title == "authoritative body")
        #expect(stored.messages.first?.text == "authoritative body")
        #expect(state.conversations.first?.title == "Stale Mirror")
    }

    @Test("lifecycle persistence drains queued conversation writes before relaunch")
    @MainActor
    func lifecyclePersistenceDrainsQueuedConversationWritesBeforeRelaunch() throws {
        let uid = "persist-lifecycle-\(UUID().uuidString)"
        let message = TestFactories.makeMessage(role: .user, text: "today message")
        var conversation = TestFactories.makeConversation(
            title: "Before Relaunch",
            messages: [message]
        )
        conversation.updatedAt = Date()

        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.upsertConversationProjection(conversation)

        state.persistLifecycleCriticalData(checkpoint: true)
        state.flushConversationPersistQueue()
        DatabaseManager.shared.close()

        let reloaded = AppState(sessionUID: uid)
        let restored = try #require(reloaded.conversations.first(where: { $0.id == conversation.id }))

        #expect(restored.title == "today message")
        #expect(
            abs(restored.updatedAt.timeIntervalSince(conversation.updatedAt)) < 0.001,
            "After lifecycle persistence, updatedAt read back on restart must keep the same sort time"
        )
        #expect(restored.displayMessageCount == 1)
    }

    @Test("makeConfiguration waits on SQLITE_BUSY instead of failing immediately")
    func busyTimeoutAllowsContendedWrite() throws {
        let configuration = DatabaseSchema.makeConfiguration()
        guard case .timeout(let seconds) = configuration.busyMode else {
            Issue.record("expected busyMode.timeout, got \(String(describing: configuration.busyMode))")
            return
        }
        #expect(seconds == 5)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-busy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("busy.sqlite").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let holder = try DatabasePool(path: path, configuration: configuration)
        let contender = try DatabasePool(path: path, configuration: configuration)
        try holder.write { db in
            try db.execute(sql: "CREATE TABLE t(id INTEGER PRIMARY KEY)")
        }

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            _ = holderFinished.wait(timeout: .now() + 2)
            try? holder.close()
            try? contender.close()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { holderFinished.signal() }
            do {
                try holder.write { db in
                    try db.execute(sql: "INSERT INTO t(id) VALUES (1)")
                    started.signal()
                    release.wait()
                }
            } catch {
                started.signal()
            }
        }
        #expect(started.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            release.signal()
        }
        try contender.write { db in
            try db.execute(sql: "INSERT INTO t(id) VALUES (2)")
        }

        let ids = try contender.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM t ORDER BY id")
        }
        #expect(ids == [1, 2])
    }

    @Test("SQLitePersistRetry succeeds after SQLITE_BUSY")
    func sqlitePersistRetrySucceedsAfterBusy() throws {
        let busy = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        var attempts = 0
        var slept: [TimeInterval] = []
        try SQLitePersistRetry.run(sleep: { slept.append($0) }) {
            attempts += 1
            if attempts < 3 { throw busy }
        }
        #expect(attempts == 3)
        #expect(slept == [
            SQLitePersistRetry.delay(beforeAttempt: 2),
            SQLitePersistRetry.delay(beforeAttempt: 3)
        ])
    }

    @Test("SQLitePersistRetry fails immediately on a non-retryable error")
    func sqlitePersistRetryDoesNotRetryConstraint() throws {
        let constraint = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE")
        var attempts = 0
        do {
            try SQLitePersistRetry.run(sleep: { _ in Issue.record("should not sleep") }) {
                attempts += 1
                throw constraint
            }
            Issue.record("expected throw")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_CONSTRAINT)
        }
        #expect(attempts == 1)
        #expect(SQLitePersistRetry.isRetryable(DatabaseError(resultCode: .SQLITE_BUSY)))
        #expect(SQLitePersistRetry.isRetryable(DatabaseError(resultCode: .SQLITE_LOCKED)))
        #expect(SQLitePersistRetry.isRetryable(DatabaseError(resultCode: .SQLITE_INTERRUPT)))
        #expect(!SQLitePersistRetry.isRetryable(constraint))
    }

    private func makeStore(uid: String) throws -> ConversationStore {
        let dbPool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let attachmentFileStore = AttachmentFileStore(rootDirectory: AppSessionStore.userDir(for: uid).appendingPathComponent("Files", isDirectory: true))
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(dbPool)
        return ConversationStore(
            dbPool: dbPool,
            attachmentFileStore: attachmentFileStore
        )
    }

    private func decodeSnapshot(at url: URL) throws -> AppSessionSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSessionSnapshot.self, from: data)
    }

    private func decodeRecoverySnapshot(at url: URL) throws -> LegacyConversationRecoverySnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LegacyConversationRecoverySnapshot.self, from: data)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        intervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for persistence")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}
