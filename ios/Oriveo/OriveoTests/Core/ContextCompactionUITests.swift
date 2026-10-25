import Foundation
import OriveoProviderKit
import SwiftUI
import Testing
@testable import Oriveo

/// Pure presentation models for the divider row and the detail; a production fallback row feeds the presentation model.
@Suite("Context compaction presentation", .serialized, .sharedProcessState)
@MainActor
struct ContextCompactionUITests {
    // The detail sheet's bottom action bar squeezes out the summary at the medium detent: it opens at large by default, and medium can still be dragged to.
    @Test("detail_sheet_opens_at_large_detent")
    func detailSheetOpensAtLargeDetent() {
        #expect(ContextCompactionDetailSheet.initialDetent == .large)
        #expect(ContextCompactionDetailSheet.detents == [.medium, .large])
    }

    private static let rhoHi = 0.5

    private func messages(_ count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            TestFactories.makeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "message \(index) " + String(repeating: "x", count: 40 * (index + 1))
            )
        }
    }

    private func record(
        coversTo index: Int,
        in messages: [ChatMessage],
        kind: ContextCheckpointRecord.Kind,
        summary: String? = nil,
        cost: Double? = nil,
        userMessageIds: [String] = []
    ) -> ContextCheckpointRecord {
        let covered = messages.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        let coversTo = messages[index].id.uuidString
        return ContextCheckpointRecord(
            conversationId: "conversation",
            checkpointId: ContextCheckpoint.checkpointId(conversationId: "conversation", coversTo: coversTo),
            kind: kind,
            coversFrom: covered[0].id,
            coversTo: coversTo,
            coversDigest: ContextCheckpoint.coversDigest(Array(covered[0...index])),
            messagesCovered: index + 1,
            userMessageIds: userMessageIds,
            text: "<oriveo-context-checkpoint>\n" + (summary ?? "kept user words") + "\n</oriveo-context-checkpoint>",
            summary: summary,
            language: summary == nil ? nil : "en",
            model: "gpt-x",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: 1_700_000_000_123,
            cost: cost
        )
    }

    @Test func separator_summary_fields() throws {
        let history = messages(6)
        let row = record(coversTo: 3, in: history, kind: .summary, summary: "## Goal\nship", cost: 0.01,
                         userMessageIds: [history[0].id.uuidString, history[2].id.uuidString])

        let separator = try #require(ContextCompactionSeparator.make(latest: row, messages: history, rhoHi: Self.rhoHi))

        let expectedBefore = history[0...3].reduce(0) { $0 + ContextBudget.estimateMessage($1.text, rhoHi: Self.rhoHi) }
        #expect(separator.kind == .summary)
        #expect(separator.count == 4)
        #expect(separator.before == expectedBefore)
        #expect(separator.after == ContextBudget.estimateMessage(row.text, rhoHi: Self.rhoHi))
        #expect(separator.kept == 2)
        #expect(separator.model == "gpt-x")
        #expect(separator.anchorMessageId == history[3].id.uuidString)
        #expect(ContextCompactionSeparator.compactCount(1_234_567, locale: Locale(identifier: "en_US")) == "1.2M")
    }

    /// Aligned across platforms: after and before use the same measure, estimated per message (including per-message overhead), consistent with Android / Web.
    @Test func separator_after_uses_message_estimate() throws {
        let history = messages(4)
        let row = record(coversTo: 1, in: history, kind: .summary, summary: "## Goal\nship")

        let separator = try #require(ContextCompactionSeparator.make(latest: row, messages: history, rhoHi: Self.rhoHi))

        #expect(separator.after == ContextBudget.estimateText(row.text, rhoHi: Self.rhoHi) + ContextBudget.messageOverheadTokens)
    }

    @Test func separator_fallback_counts() throws {
        let history = messages(8)
        let row = record(coversTo: 4, in: history, kind: .fallback,
                         userMessageIds: [history[0].id.uuidString, history[2].id.uuidString, history[4].id.uuidString])

        let separator = try #require(ContextCompactionSeparator.make(latest: row, messages: history, rhoHi: Self.rhoHi))

        // Among the first 5 (u a u a u) there are 2 assistant messages.
        #expect(separator.kind == .fallback)
        #expect(separator.count == 2)
        #expect(separator.kept == 3)
        #expect(separator.before == nil)
        #expect(separator.after == nil)
        #expect(separator.anchorMessageId == history[4].id.uuidString)
    }

    @Test func separator_hidden_without_visible_checkpoint() {
        let history = messages(6)
        let row = record(coversTo: 3, in: history, kind: .summary, summary: "## Goal")

        #expect(ContextCompactionSeparator.make(latest: nil, messages: history, rhoHi: Self.rhoHi) == nil)
        // Not drawn when coversTo is not among the loaded messages.
        #expect(ContextCompactionSeparator.make(latest: row, messages: Array(history[4...]), rhoHi: Self.rhoHi) == nil)
        #expect(ContextCompactionSeparator.make(latest: row, messages: [], rhoHi: Self.rhoHi) == nil)
    }

    @Test func detail_cost_unavailable_when_null() {
        let history = messages(4)
        let paid = record(coversTo: 1, in: history, kind: .summary, summary: "## Goal", cost: 0.25,
                          userMessageIds: [history[0].id.uuidString])
        var unpaid = paid
        unpaid.cost = nil
        var emptySummary = paid
        emptySummary.summary = ""
        let fallback = record(coversTo: 1, in: history, kind: .fallback, cost: 0.5)

        let unpaidDetail = ContextCompactionDetail(record: unpaid)
        #expect(unpaidDetail.cost == .unavailable)
        #expect(unpaidDetail.summary == "## Goal")
        #expect(unpaidDetail.kept == 1)
        #expect(unpaidDetail.model == "gpt-x")
        #expect(Int64((unpaidDetail.createdAt.timeIntervalSince1970 * 1_000).rounded()) == 1_700_000_000_123)
        #expect(ContextCompactionDetail(record: paid).cost == .amount(0.25))
        #expect(ContextCompactionDetail(record: fallback).cost == .noExtraCost)
        #expect(ContextCompactionDetail(record: fallback).summary == nil)
        #expect(ContextCompactionDetail(record: fallback).kind == .fallback)
        #expect(ContextCompactionDetail(record: paid).kind == .summary)
        #expect(ContextCompactionDetail(record: emptySummary).summary == nil)
    }

    @Test func separator_from_production_fallback_row() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {},
          "runtimeConfig": { "featureFlags": { "\(ContextCompactionCoordinator.remoteFlagKey)": false } }
        }
        """)
        let (state, conversationID, history) = makeFixture()

        let result = await state.chatManager.compactConversationNow(conversationId: conversationID)
        await MetadataClient.shared.resetForTesting()

        #expect(result.outcome == .fallback)
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let separator = try #require(try ContextCompactionSeparator.resolve(
            store: store, conversationId: conversationID.uuidString, messages: history, rhoHi: Self.rhoHi
        ))
        let row = try #require(result.row)
        let anchor = try #require(history.firstIndex { $0.id.uuidString == row.coversTo })
        let assistants = history[0...anchor].filter { $0.role == .assistant }.count
        #expect(separator.kind == .fallback)
        #expect(separator.anchorMessageId == row.coversTo)
        #expect(separator.count == assistants)
        #expect(separator.count > 0)
        #expect(separator.kept == row.userMessageIds.count)
        #expect(separator.kept > 0)
    }

    // MARK: - Clear / recompact / manual / third hint / quoting the summary

    private func loadRemoteCompactionOff() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "providers": {},
          "runtimeConfig": { "featureFlags": { "\(ContextCompactionCoordinator.remoteFlagKey)": false } }
        }
        """)
    }

    /// Writes a row matching the history summary under the real conversation id.
    @discardableResult
    private func seed(
        _ store: ContextCompactionStore,
        conversationID: UUID,
        history: [ChatMessage],
        coversTo index: Int,
        createdAt: Int64,
        summary: String? = nil,
        userMessageIds: [String] = []
    ) throws -> ContextCheckpointRecord {
        var row = record(coversTo: index, in: history, kind: summary == nil ? .fallback : .summary,
                         summary: summary, userMessageIds: userMessageIds)
        row.conversationId = conversationID.uuidString
        row.checkpointId = ContextCheckpoint.checkpointId(conversationId: row.conversationId, coversTo: row.coversTo)
        row.createdAt = createdAt
        try store.save(row)
        return row
    }

    @Test func clear_deletes_all() throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 1, createdAt: 1_000)
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 2_000)

        #expect(state.chatManager.clearCompaction(conversationId: conversationID) == .cleared)

        #expect(try store.list(conversationId: conversationID.uuidString).isEmpty)

        // No row to delete: still report cleared.
        #expect(state.chatManager.clearCompaction(conversationId: conversationID) == .cleared)
    }

    @Test func recompact_drops_latest_then_manual() async throws {
        try await loadRemoteCompactionOff()
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let latest = try seed(store, conversationID: conversationID, history: history, coversTo: 1, createdAt: 1_000)

        let toast = await state.chatManager.recompact(conversationId: conversationID)
        await MetadataClient.shared.resetForTesting()

        #expect(toast == .fallback)
        let rows = try store.list(conversationId: conversationID.uuidString)
        #expect(!rows.contains { $0.checkpointId == latest.checkpointId })
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .fallback)
    }

    @Test func manual_result_toasts() async throws {
        #expect(ChatManager.ContextCompactionToast.forManual(.summary) == nil)
        #expect(ChatManager.ContextCompactionToast.forManual(.fallback) == .fallback)
        #expect(ChatManager.ContextCompactionToast.forManual(.noop) == .noop)

        try await loadRemoteCompactionOff()
        let (state, conversationID, _) = makeFixture()
        let fallback = await state.chatManager.manualCompact(conversationId: conversationID)
        let noop = await state.chatManager.manualCompact(conversationId: UUID())
        await MetadataClient.shared.resetForTesting()

        #expect(fallback == .fallback)
        #expect(noop == .noop)
    }

    @Test func third_compaction_hint_once() async throws {
        try await loadRemoteCompactionOff()
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        try seed(store, conversationID: conversationID, history: history, coversTo: 1, createdAt: 1_000)
        try seed(store, conversationID: conversationID, history: history, coversTo: 2, createdAt: 2_000)
        #expect(state.chatManager.pendingCompactionHint == nil)

        let first = await state.chatManager.manualCompact(conversationId: conversationID)
        #expect(first == .fallback)
        #expect(try store.list(conversationId: conversationID.uuidString).count == 3)
        #expect(state.chatManager.pendingCompactionHint == conversationID)

        state.chatManager.dismissCompactionHint()
        #expect(state.chatManager.pendingCompactionHint == nil)

        // Land once more with the count still 3: this process already hinted for this conversation, so no further hint.
        _ = await state.chatManager.recompact(conversationId: conversationID)
        await MetadataClient.shared.resetForTesting()
        #expect(try store.list(conversationId: conversationID.uuidString).count == 3)
        #expect(state.chatManager.pendingCompactionHint == nil)
    }

    @Test func new_chat_quote_from_summary() throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let row = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                           summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        let conversation = try #require(state.conversations.first { $0.id == conversationID })

        #expect(state.startNewChatWithSummary(conversationId: conversationID, label: "From summary"))

        let quote = try #require(state.pendingComposerQuote)
        #expect(quote.sourceMessageId == row.coversTo)
        #expect(quote.sourceRole == .assistant)
        #expect(quote.leadingText == "From summary")
        #expect(quote.selectedText == "## Goal\nship")
        #expect(quote.isValid)
        #expect(state.activeModel?.provider.id == conversation.providerID)
        #expect(state.activeModel?.model.id == conversation.modelID)

        // An over-long summary is truncated at the tail, so the total length including the label stays within 8000 graphemes.
        var long = row
        long.summary = String(repeating: "s", count: 9_000)
        let truncated = try #require(ContextCompactionQuote.make(record: long, messages: history, label: "label"))
        #expect(truncated.selectedText.count == QuoteContext.maximumGraphemeCount - 5)
        #expect(truncated.contextTruncated)
        #expect(truncated.isValid)
    }

    /// With missing connection credentials, starting a new chat with the summary cannot open the chat page: it returns false, leaves no quote behind, and does not write last used.
    @Test func new_chat_quote_from_summary_missing_credential_returns_false() throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                     summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        state.providers = state.providers.map { provider in
            var provider = provider
            provider.apiKey = ""
            provider.apiKeyPreview = ""
            return provider
        }
        state.lastUsedModelRef = nil

        #expect(!state.startNewChatWithSummary(conversationId: conversationID, label: "From summary"))
        #expect(state.pendingComposerQuote == nil)
        #expect(state.lastUsedModelRef == nil)
        #expect(state.navigation.path.last != .chat(conversationID: nil))
    }

    /// The conversation modelID is empty: a new chat with the summary reuses the model resolved from currentModel instead of opening with an empty id.
    @Test func new_chat_quote_from_summary_uses_current_model() throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                     summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        var conversation = try #require(state.conversations.first { $0.id == conversationID })
        conversation.modelID = ""
        state.upsertConversationProjection(conversation)
        state.lastUsedModelRef = nil

        #expect(state.startNewChatWithSummary(conversationId: conversationID, label: "From summary"))
        #expect(state.pendingComposerQuote != nil)
        #expect(state.lastUsedModelRef?.providerID == conversation.providerID)
        #expect(state.lastUsedModelRef?.modelID == "relay-window")
    }

    /// The conversation model is retired: a new chat with the summary does not reuse the retired model, does not write the fallback model into last used, and opens along this connection's new-chat chain.
    @Test func new_chat_quote_from_summary_skips_retired_model() async throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                     summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        var conversation = try #require(state.conversations.first { $0.id == conversationID })
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let fallback = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", canonicalModelId: "gpt-5.4")
        state.providers = [TestFactories.makeProvider(
            id: conversation.providerID, kind: .openAI, models: [retired, fallback], catalogModels: [retired, fallback]
        )]
        conversation.modelID = "gpt-4-legacy"
        state.upsertConversationProjection(conversation)
        state.lastUsedModelRef = nil
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let opened = state.startNewChatWithSummary(conversationId: conversationID, label: "From summary")
        let draft = resolveChatScreenContext(projection: Self.draftProjection, appState: state)
        await MetadataClient.shared.resetForTesting()

        #expect(opened)
        #expect(state.pendingComposerQuote != nil)
        #expect(state.lastUsedModelRef == nil)
        #expect(state.pendingNewChatProviderID == conversation.providerID)
        #expect(draft?.provider.id == conversation.providerID)
        #expect(draft?.model?.id == "gpt-5.4")
    }

    /// The conversation model cannot be sent and last used is on another connection: last used is unchanged, and the draft still opens along the new-chat chain of the conversation's connection.
    @Test func new_chat_quote_from_summary_unsendable_keeps_last_used_on_other_connection() async throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        _ = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                     summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        var conversation = try #require(state.conversations.first { $0.id == conversationID })
        let retired = TestFactories.makeModel(id: "gpt-4-legacy", name: "GPT-4 Legacy", canonicalModelId: "gpt-4-legacy")
        let fallback = TestFactories.makeModel(id: "gpt-5.4", name: "GPT-5.4", canonicalModelId: "gpt-5.4")
        let otherModel = TestFactories.makeModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", canonicalModelId: "claude-sonnet-4-5")
        let other = TestFactories.makeProvider(kind: .anthropic, models: [otherModel], catalogModels: [otherModel])
        state.providers = [
            TestFactories.makeProvider(
                id: conversation.providerID, kind: .openAI, models: [retired, fallback], catalogModels: [retired, fallback]
            ),
            other
        ]
        conversation.modelID = "gpt-4-legacy"
        state.upsertConversationProjection(conversation)
        let lastUsed = LastUsedModelRef(providerID: other.id, modelID: "claude-sonnet-4-5")
        state.lastUsedModelRef = lastUsed
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: ChatScreenProjectionTests.retiredMetadataJSON)

        let opened = state.startNewChatWithSummary(conversationId: conversationID, label: "From summary")
        let draft = resolveChatScreenContext(projection: Self.draftProjection, appState: state)
        await MetadataClient.shared.resetForTesting()

        #expect(opened)
        #expect(state.lastUsedModelRef == lastUsed)
        #expect(draft?.provider.id == conversation.providerID)
        #expect(draft?.model?.id == "gpt-5.4")

        // A plain new chat no longer keeps the pinned connection: it goes back to last used.
        #expect(state.startNewChat())
        #expect(state.pendingNewChatProviderID == nil)
        #expect(resolveChatScreenContext(projection: Self.draftProjection, appState: state)?.provider.id == other.id)
    }

    /// A draft projection for a conversation that has not been created yet.
    private static let draftProjection = ChatScreenProjection(
        requestedConversationID: nil,
        summary: nil,
        messages: [],
        hasLoadedSummary: true,
        messageRevision: 0
    )

    @Test func new_chat_quote_from_fallback() throws {
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let kept = [history[0], history[2], history[4]]
        let row = try seed(store, conversationID: conversationID, history: history, coversTo: 5, createdAt: 1_000,
                           userMessageIds: kept.map(\.id.uuidString))
        let label = "Kept words"

        #expect(state.startNewChatWithSummary(conversationId: conversationID, label: label))

        // Each over 8000 graphemes: drop from the oldest until only the newest remains, and truncate its tail if it is still too long.
        let quote = try #require(state.pendingComposerQuote)
        #expect(quote.sourceMessageId == row.coversTo)
        #expect(quote.sourceRole == .assistant)
        #expect(quote.selectedText == String(history[4].text.prefix(QuoteContext.maximumGraphemeCount - label.count)))
        #expect(quote.contextTruncated)
        #expect(quote.isValid)

        // Within the limit, one section per entry in time order; beyond it, drop from the oldest.
        let small = messages(6).enumerated().map { index, message in
            var message = message
            message.text = "u\(index) " + String(repeating: "w", count: 3_000)
            return message
        }
        var fallback = record(coversTo: 4, in: small, kind: .fallback,
                              userMessageIds: [small[4].id.uuidString, small[0].id.uuidString])
        let two = try #require(ContextCompactionQuote.make(record: fallback, messages: small, label: label))
        #expect(two.selectedText == small[0].text + "\n\n" + small[4].text)
        #expect(!two.contextTruncated)
        fallback.userMessageIds = [small[0].id.uuidString, small[2].id.uuidString, small[4].id.uuidString]
        let dropped = try #require(ContextCompactionQuote.make(record: fallback, messages: small, label: label))
        #expect(dropped.selectedText == small[2].text + "\n\n" + small[4].text)
        #expect(dropped.contextTruncated)
    }

    // MARK: - Transcript divider row

    /// The projection attaches the divider row to the first message after coversTo; it adds no row and does not change the cell kind; the row-height estimate includes the divider row.
    @Test func transcript_separator_anchor() throws {
        let history = messages(6)
        let row = record(coversTo: 3, in: history, kind: .summary, summary: "## Goal",
                         userMessageIds: [history[0].id.uuidString])
        let separator = try #require(ContextCompactionSeparator.make(latest: row, messages: history, rhoHi: Self.rhoHi))

        let rows = ChatCollectionProjectionBuilder.makeRows(
            from: history, metadata: .empty, compactionSeparator: separator
        )
        #expect(rows.count == history.count)
        #expect(rows.map(\.compactionSeparator) == [nil, nil, nil, nil, separator, nil])

        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: rows, providerMetadataVersion: 0)
        #expect(plan.items.map(\.id) == history.map(\.id))
        #expect(plan.items[4].presentationKind == .user)
        #expect(plan.renderModelsByID[history[4].id]?.compactionSeparator == separator)
        #expect(plan.renderModelsByID[history[3].id]?.compactionSeparator == nil)

        let plain = ChatCollectionProjectionBuilder.makeRows(from: history, metadata: .empty)
        #expect(ChatListViewController.estimatedRowHeight(for: rows[4], width: 393)
            == ChatListViewController.estimatedRowHeight(for: plain[4], width: 393)
            + ChatListViewController.compactionSeparatorHeight)

        // coversTo is the last loaded message, or is not within the loaded window: not drawn.
        let head = ChatCollectionProjectionBuilder.makeRows(
            from: Array(history[0...3]), metadata: .empty, compactionSeparator: separator
        )
        #expect(head.allSatisfy { $0.compactionSeparator == nil })
        let window = ChatCollectionProjectionBuilder.makeRows(
            from: Array(history[4...]), metadata: .empty, compactionSeparator: separator
        )
        #expect(window.allSatisfy { $0.compactionSeparator == nil })
    }

    /// Production compaction persists -> notification -> the divider row is fetched from the full history; after clearing, the notification arrives again, the divider row disappears and the render model changes with it.
    @Test func transcript_separator_refreshes_on_change() async throws {
        try await loadRemoteCompactionOff()
        let (state, conversationID, history) = makeFixture()
        let log = CheckpointNotificationLog()
        let token = NotificationCenter.default.addObserver(
            forName: .contextCheckpointsDidChange, object: nil, queue: nil
        ) { note in log.append(note) }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(await ContextCompactionSeparator.current(in: state, conversationID: conversationID) == nil)

        let result = await state.chatManager.compactConversationNow(conversationId: conversationID)
        await MetadataClient.shared.resetForTesting()
        let row = try #require(result.row)

        let saved = try #require(log.notes.last)
        #expect(ChatMessageList.isCheckpointChange(saved, conversationID: conversationID))
        #expect(!ChatMessageList.isCheckpointChange(saved, conversationID: UUID()))
        #expect(!ChatMessageList.isCheckpointChange(saved, conversationID: nil))

        let separator = try #require(await ContextCompactionSeparator.current(in: state, conversationID: conversationID))
        #expect(separator.anchorMessageId == row.coversTo)
        let anchor = try #require(history.firstIndex { $0.id.uuidString == row.coversTo })
        #expect(anchor + 1 < history.count)
        let shown = ChatCollectionProjectionBuilder.makeRows(
            from: history, metadata: .empty, compactionSeparator: separator
        )
        #expect(shown[anchor + 1].compactionSeparator == separator)

        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let before = log.notes.count
        _ = try store.deleteAll(conversationId: conversationID.uuidString)
        #expect(log.notes.count == before + 1)
        #expect(ChatMessageList.isCheckpointChange(try #require(log.notes.last), conversationID: conversationID))
        #expect(await ContextCompactionSeparator.current(in: state, conversationID: conversationID) == nil)

        let cleared = ChatCollectionProjectionBuilder.makeRows(from: history, metadata: .empty, compactionSeparator: nil)
        let next = history[anchor + 1].id
        let shownModel = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: shown, providerMetadataVersion: 0)
            .renderModelsByID[next]
        let clearedModel = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: cleared, providerMetadataVersion: 0)
            .renderModelsByID[next]
        #expect(shownModel != clearedModel)
        #expect(clearedModel?.compactionSeparator == nil)
    }

    /// When the divider-row refresh fills in an unloaded thread, it does not read file attachment bodies (only message text).
    @Test func separator_refresh_skips_file_payloads() async throws {
        let (state, conversationID, history) = makeFixture(bytes: 200)
        let payload = Data("separator-sidecar".utf8).base64EncodedString()
        let index = try #require(state.conversations.firstIndex { $0.id == conversationID })
        var conversation = state.conversations[index]
        conversation.messages[0].attachments = [TestFactories.makeFileAttachment(base64Data: payload)]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let row = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1)

        // Positive control: the database does contain a readable attachment body.
        let hydrated = try state.conversationRuntimeBridge.fetchConversationProjections(
            ids: [conversationID], uid: state.sessionPartitionUID, hydrateFilePayloads: true
        )
        #expect(hydrated.first?.messages.first?.attachments?.first?.base64Data == payload)

        let unloadedIndex = try #require(state.conversations.firstIndex { $0.id == conversationID })
        state.conversations[unloadedIndex].messages = []
        state.conversations[unloadedIndex].messagesAreLoaded = false

        let separator = try #require(await ContextCompactionSeparator.current(in: state, conversationID: conversationID))
        #expect(separator.anchorMessageId == row.coversTo)
        let loaded = try #require(state.conversations.first { $0.id == conversationID })
        #expect(loaded.messagesAreLoaded)
        let attachment = try #require(loaded.messages.first?.attachments?.first)
        #expect(attachment.base64Data == nil)
    }

    // MARK: - Wiring of the detail buttons and the composer quote

    /// The detail model takes the latestValid row; each of the three buttons reaches a production action in ChatManager / AppState, and the toast key follows the action result.
    @Test func detail_actions_wired() async throws {
        try await loadRemoteCompactionOff()
        let (state, conversationID, history) = makeFixture()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let row = try seed(store, conversationID: conversationID, history: history, coversTo: 3, createdAt: 1_000,
                           summary: "## Goal\nship", userMessageIds: [history[0].id.uuidString])
        let actions = ContextCompactionActions(appState: state, conversationID: conversationID)

        let detail = try #require(ContextCompactionDetail.current(in: state, conversationID: conversationID))
        #expect(detail == ContextCompactionDetail(record: row))
        #expect(detail.summary == "## Goal\nship")

        // Start a new chat with the summary: the quote label uses a localized key, and the third-time hint is dismissed with it.
        state.pendingCompactionHint = conversationID
        #expect(await actions.perform(.newChatWithSummary) == nil)
        let quote = try #require(state.pendingComposerQuote)
        #expect(quote.leadingText == L10n.tr("context_compaction_quote_label", table: .chat))
        #expect(quote.selectedText == "## Goal\nship")
        #expect(quote.sourceMessageId == row.coversTo)
        #expect(state.pendingCompactionHint == nil)
        #expect(state.consumePendingComposerQuote() == quote)

        // Recompact: delete latestValid and then compact manually (remote switch off -> fallback).
        let recompacted = await actions.perform(.recompact)
        #expect(recompacted == .fallback)
        #expect(try store.list(conversationId: conversationID.uuidString).map(\.kind) == [.fallback])

        // Clear compaction: delete everything, and the detail disappears with it.
        let cleared = await actions.perform(.clear)
        await MetadataClient.shared.resetForTesting()
        #expect(cleared == .cleared)
        #expect(try store.list(conversationId: conversationID.uuidString).isEmpty)
        #expect(ContextCompactionDetail.current(in: state, conversationID: conversationID) == nil)

        #expect(ContextCompactionActions.toastKey(.cleared) == "context_compaction_toast_cleared")
        #expect(ContextCompactionActions.toastKey(.fallback) == "context_compaction_toast_fallback")
        #expect(ContextCompactionActions.toastKey(.noop) == "context_compaction_toast_noop")
    }

    /// When ChatView appears it takes the pending quote once: nil after taking, and empty on a second take.
    @Test func new_chat_consumes_pending_quote() throws {
        let (state, _, _) = makeFixture()
        let quote = QuoteContext(
            sourceMessageId: UUID().uuidString,
            sourceRole: .assistant,
            contentKind: .prose,
            leadingText: "label",
            selectedText: "summary",
            trailingText: "",
            contextTruncated: false
        )
        #expect(state.consumePendingComposerQuote() == nil)
        state.pendingComposerQuote = quote

        #expect(state.consumePendingComposerQuote() == quote)
        #expect(state.pendingComposerQuote == nil)
        #expect(state.consumePendingComposerQuote() == nil)
    }

    // MARK: Compaction in progress, cancel and stop

    /// Polls until the condition holds or times out (the summary request starts on the URLProtocol thread).
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A preSend summary in progress is observable; after cancel it counts as no failure, lands a fallback row and carries on sending this message. Cancelling a manual compaction: noop, nothing persisted, no toast.
    @Test func compacting_state_and_cancel_falls_back() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        HangingSummaryURLProtocol.reset()
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            HangingSummaryURLProtocol.reset()
        }

        let (state, conversationID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let coordinator = try #require(
            state.chatManager.debugCompactionCoordinatorForTesting(uid: state.sessionPartitionUID)
        )
        #expect(state.chatManager.aiCompactingConversationIDs.isEmpty)
        let sending = Task { await state.sendMessage("Next", in: conversationID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)
        #expect(state.chatManager.aiCompactingConversationIDs == [conversationID])

        state.chatManager.cancelCompaction(conversationId: conversationID)
        _ = await sending.value
        try await waitUntil { HangingSummaryURLProtocol.chatRequests == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(HangingSummaryURLProtocol.chatRequests == 1)
        #expect(state.chatManager.aiCompactingConversationIDs.isEmpty)
        #expect(try store.list(conversationId: conversationID.uuidString).map(\.kind) == [.fallback])
        let breaker = coordinator.breakerState(conversationId: conversationID.uuidString)
        #expect(breaker.mode == .llm)
        #expect(breaker.failures == 0)

        // Manual: cancel is a noop, nothing persisted, no toast.
        HangingSummaryURLProtocol.reset()
        let (manualState, manualID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let manualStore = try #require(ContextCompactionStore.forPartition(manualState.sessionPartitionUID))
        let manual = Task { await manualState.chatManager.manualCompact(conversationId: manualID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }
        #expect(manualState.chatManager.aiCompactingConversationIDs == [manualID])

        manualState.chatManager.cancelCompaction(conversationId: manualID)
        let toast = await manual.value

        #expect(toast == nil)
        #expect(manualState.chatManager.aiCompactingConversationIDs.isEmpty)
        #expect(try manualStore.list(conversationId: manualID.uuidString).isEmpty)
        #expect(HangingSummaryURLProtocol.chatRequests == 0)
    }

    /// Tapping stop during compaction: the whole send is cancelled, nothing is persisted, no chat request is sent, and the in-progress state is cleared.
    @Test func stop_during_compaction_saves_nothing() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        HangingSummaryURLProtocol.reset()
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            HangingSummaryURLProtocol.reset()
        }

        let (state, conversationID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let sending = Task { await state.sendMessage("Next", in: conversationID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }
        #expect(state.chatManager.aiCompactingConversationIDs == [conversationID])

        state.cancelGeneration(in: conversationID)
        _ = await sending.value
        try await waitUntil { state.chatManager.aiCompactingConversationIDs.isEmpty }
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(state.chatManager.aiCompactingConversationIDs.isEmpty)
        #expect(HangingSummaryURLProtocol.chatRequests == 0)
        #expect(try store.list(conversationId: conversationID.uuidString).isEmpty)
    }

    /// Tapping stop during compaction: the placeholder assistant message finishes as "stopped before the first token" and does not stay in "generating".
    @Test func stop_during_compaction_finalizes_placeholder() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        HangingSummaryURLProtocol.reset()
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            HangingSummaryURLProtocol.reset()
        }

        let (state, conversationID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let sending = Task { await state.sendMessage("Next", in: conversationID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }

        state.cancelGeneration(in: conversationID)
        _ = await sending.value
        try await waitUntil { state.chatManager.aiCompactingConversationIDs.isEmpty }
        try? await Task.sleep(nanoseconds: 500_000_000)

        let conversation = try #require(state.conversations.first(where: { $0.id == conversationID }))
        let assistants = conversation.messages.filter { $0.role == .assistant }
        #expect(!assistants.contains { $0.state == .generating })
        #expect(HangingSummaryURLProtocol.chatRequests == 0)
    }

    /// In AI mode with P̂ ≥ 0.75·B, pre-compaction sends one summary request and lands a summary row;
    /// it sends nothing when the preference is off, P̂ is insufficient or one is already in progress; a cancelled in-progress one lands no fallback row.
    @Test func precompaction_on_focus_ai_only() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        HangingSummaryURLProtocol.reset()
        HangingSummaryURLProtocol.summaryReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            HangingSummaryURLProtocol.reset()
        }

        // AI mode, P̂ over 0.75·B: one summary request, a summary row lands, no chat is sent.
        let (state, conversationID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let landed = await state.chatManager.precompactIfNeeded(conversationId: conversationID)
        #expect(landed.outcome == .summary)
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)
        #expect(HangingSummaryURLProtocol.chatRequests == 0)
        #expect(try store.list(conversationId: conversationID.uuidString).map(\.kind) == [.summary])

        // P̂ insufficient: nothing is sent.
        HangingSummaryURLProtocol.reset()
        HangingSummaryURLProtocol.summaryReply = "unused"
        let (smallState, smallID, _) = makeFixture(bytes: 200, protocolClass: HangingSummaryURLProtocol.self)
        let small = await smallState.chatManager.precompactIfNeeded(conversationId: smallID)
        #expect(small.outcome == .noop)
        #expect(HangingSummaryURLProtocol.summaryStarts == 0)
        let smallStore = try #require(ContextCompactionStore.forPartition(smallState.sessionPartitionUID))
        #expect(try smallStore.list(conversationId: smallID.uuidString).isEmpty)

        // Preference off (fallback mode): nothing is sent and no fallback row lands.
        AppPreferencesStore.savedContextAISummaryEnabled = false
        let (offState, offID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let off = await offState.chatManager.precompactIfNeeded(conversationId: offID)
        #expect(off.outcome == .noop)
        #expect(HangingSummaryURLProtocol.summaryStarts == 0)
        let offStore = try #require(ContextCompactionStore.forPartition(offState.sessionPartitionUID))
        #expect(try offStore.list(conversationId: offID.uuidString).isEmpty)
        AppPreferencesStore.savedContextAISummaryEnabled = true

        // Already in progress: the second one is not sent; after cancel no fallback row lands.
        HangingSummaryURLProtocol.reset()
        let (busyState, busyID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let busyStore = try #require(ContextCompactionStore.forPartition(busyState.sessionPartitionUID))
        let first = Task { await busyState.chatManager.precompactIfNeeded(conversationId: busyID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)
        let second = await busyState.chatManager.precompactIfNeeded(conversationId: busyID)
        #expect(second.outcome == .noop)
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)
        busyState.chatManager.cancelCompaction(conversationId: busyID)
        let cancelled = await first.value
        #expect(cancelled.outcome == .noop)
        #expect(cancelled.row == nil)
        #expect(try busyStore.list(conversationId: busyID.uuidString).isEmpty)
        #expect(HangingSummaryURLProtocol.chatRequests == 0)
    }

    /// Single-flight compaction per conversation: when a send arrives while a pre-compaction summary is pending, the send waits for it to land its row and then re-decides from the database rows, sending only 1 summary request, landing 1 row and sending chat as usual.
    @Test func send_waits_for_inflight_precompaction() async throws {
        let previous = AppPreferencesStore.savedContextAISummaryEnabled
        AppPreferencesStore.savedContextAISummaryEnabled = true
        HangingSummaryURLProtocol.reset()
        HangingSummaryURLProtocol.summaryReply = ContextCheckpoint.headings
            .map { "## \($0)\n(none)" }
            .joined(separator: "\n")
        HangingSummaryURLProtocol.holdSummaries()
        defer {
            AppPreferencesStore.savedContextAISummaryEnabled = previous
            HangingSummaryURLProtocol.reset()
        }

        let (state, conversationID, _) = makeFixture(bytes: 3_500, protocolClass: HangingSummaryURLProtocol.self)
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let precompacting = Task { await state.chatManager.precompactIfNeeded(conversationId: conversationID) }
        try await waitUntil { HangingSummaryURLProtocol.summaryStarts == 1 }
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)

        let sending = Task { await state.sendMessage("Next", in: conversationID) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(HangingSummaryURLProtocol.summaryStarts == 1)

        HangingSummaryURLProtocol.releaseHeldSummaries()
        let landed = await precompacting.value
        #expect(landed.outcome == .summary)
        _ = await sending.value
        try await waitUntil { HangingSummaryURLProtocol.chatRequests == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(HangingSummaryURLProtocol.summaryStarts == 1)
        #expect(HangingSummaryURLProtocol.chatRequests == 1)
        let rows = try store.list(conversationId: conversationID.uuidString)
        #expect(rows.map(\.kind) == [.summary])
        #expect(rows.first?.checkpointId == landed.row?.checkpointId)
    }

    /// W=40000, O=4000 -> B=36000; by default each message is 8000 bytes, so 20 messages far exceed the budget.
    private func makeFixture(
        bytes: Int = 8_000,
        protocolClass: AnyClass? = nil,
        kind: ProviderKind = .relay
    ) -> (AppState, UUID, [ChatMessage]) {
        let providerID = UUID()
        let modelID = "relay-window"
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.contextLength = 40_000
        model.maxOutputTokens = 4_000
        let provider = Provider(
            id: providerID,
            kind: kind,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClass { configuration.protocolClasses = [protocolClass] }
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-compaction-ui-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        var history: [ChatMessage] = []
        for turn in 0..<10 {
            for (role, prefix) in [(ChatRole.user, "Question"), (.assistant, "Answer")] {
                var message = TestFactories.makeMessage(
                    role: role, text: "\(prefix) \(turn): " + String(repeating: "z", count: bytes)
                )
                message.providerID = providerID
                message.providerKind = kind
                message.modelID = modelID
                history.append(message)
            }
        }
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: kind,
            modelID: modelID,
            messages: history
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        return (state, conversation.id, history)
    }
}

/// Notifications may be delivered on a background thread (the thread where the store writes).
private final class CheckpointNotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Notification] = []

    var notes: [Notification] { lock.withLock { storage } }

    func append(_ note: Notification) { lock.withLock { storage.append(note) } }
}

/// A summary request (its last message contains the compaction instruction) never responds until cancelled; other requests are counted as chat and answered with an empty stream.
private final class HangingSummaryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var summaryCount = 0
    nonisolated(unsafe) private static var chatCount = 0
    /// When non-nil, summary requests are answered with this text over OpenAI SSE; when nil they never respond (until cancelled).
    nonisolated(unsafe) static var summaryReply: String?

    static var summaryStarts: Int { lock.withLock { summaryCount } }
    static var chatRequests: Int { lock.withLock { chatCount } }

    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) private static var held: [(HangingSummaryURLProtocol, String, CFRunLoop)] = []

    static func reset() {
        lock.withLock {
            summaryCount = 0
            chatCount = 0
            summaryReply = nil
            holding = false
            held = []
        }
    }

    /// Later summary requests are held (no response) until releaseHeldSummaries.
    static func holdSummaries() {
        lock.withLock { holding = true }
    }

    /// Releases the held summary requests (they respond on their own loading threads); later summary requests respond directly.
    static func releaseHeldSummaries() {
        let pending = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        for (loader, reply, runLoop) in pending {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { loader.respondSummary(reply) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = String(decoding: Self.bodyData(of: request), as: UTF8.self)
        if body.contains("CONTEXT CHECKPOINT") {
            let runLoop = CFRunLoopGetCurrent()!
            let reply: String? = Self.lock.withLock {
                Self.summaryCount += 1
                guard let reply = Self.summaryReply else { return nil }
                if Self.holding {
                    Self.held.append((self, reply, runLoop))
                    return nil
                }
                return reply
            }
            guard let reply else { return }
            respondSummary(reply)
        } else {
            Self.lock.withLock { Self.chatCount += 1 }
            respond(with: "data: [DONE]\n\n")
        }
    }

    private func respondSummary(_ reply: String) {
        let chunk: [String: Any] = [
            "id": "chatcmpl-summary",
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": ["content": reply]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
        respond(with: "data: " + String(decoding: data, as: UTF8.self) + "\n\ndata: [DONE]\n\n")
    }

    private func respond(with payload: String) {
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { pointer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(pointer, maxLength: 4_096)
            if count <= 0 { break }
            buffer.append(pointer, count: count)
        }
        return buffer
    }
}
