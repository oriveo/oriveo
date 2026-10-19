import SwiftUI
import OriveoProviderKit

/// Actions offered by the checkpoint detail sheet and the third-compaction hint (P3·U4 contract items 3–7).
@MainActor
struct ContextCompactionActions {
    enum Action: Hashable, Sendable {
        case recompact
        case clear
        case newChatWithSummary
    }

    let appState: AppState
    let conversationID: UUID

    /// Runs the action and returns the toast to show (nil = no toast).
    func perform(_ action: Action) async -> ChatManager.ContextCompactionToast? {
        switch action {
        case .recompact:
            return await appState.chatManager.recompact(conversationId: conversationID)
        case .clear:
            return appState.chatManager.clearCompaction(conversationId: conversationID)
        case .newChatWithSummary:
            startNewChatWithSummary()
            return nil
        }
    }

    /// Opens a new chat with the latest checkpoint quoted in the composer; also dismisses this conversation's hint.
    @discardableResult
    func startNewChatWithSummary() -> Bool {
        if appState.pendingCompactionHint == conversationID {
            appState.chatManager.dismissCompactionHint()
        }
        return appState.startNewChatWithSummary(
            conversationId: conversationID,
            label: L10n.tr("context_compaction_quote_label", table: .chat)
        )
    }

    static func toastKey(_ toast: ChatManager.ContextCompactionToast) -> String {
        switch toast {
        case .cleared: "context_compaction_toast_cleared"
        case .fallback: "context_compaction_toast_fallback"
        case .noop: "context_compaction_toast_noop"
        }
    }

    static func showToast(_ toast: ChatManager.ContextCompactionToast?) {
        guard let toast else { return }
        ToastManager.shared.show(L10n.tr(toastKey(toast), table: .chat))
    }
}

extension ContextCompactionDetail {
    /// Detail of the latestValid row for the conversation's full history; nil when there is none.
    @MainActor
    static func current(in appState: AppState, conversationID: UUID) -> Self? {
        guard let store = ContextCompactionStore.forPartition(appState.sessionPartitionUID),
              let rows = try? store.list(conversationId: conversationID.uuidString),
              !rows.isEmpty,
              appState.hydrateConversationMessagesIfNeeded(id: conversationID),
              let conversation = appState.conversations.first(where: { $0.id == conversationID })
        else { return nil }
        let history = conversation.messages.map {
            ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text)
        }
        guard let latest = try? store.latestValid(conversationId: conversationID.uuidString, history: history) else {
            return nil
        }
        return Self(record: latest)
    }
}

extension AppState {
    /// Takes the pending composer quote once (ChatView appear); later calls return nil.
    func consumePendingComposerQuote() -> QuoteContext? {
        guard let quote = pendingComposerQuote else { return nil }
        pendingComposerQuote = nil
        return quote
    }
}

/// Sheet item for the checkpoint detail.
struct ContextCompactionDetailPresentation: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let detail: ContextCompactionDetail
}

/// Read-only checkpoint detail with recompact / clear / new-chat-with-summary (P3·U4 contract item 2).
struct ContextCompactionDetailSheet: View {
    let detail: ContextCompactionDetail
    let conversationID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = false

    private var actions: ContextCompactionActions {
        ContextCompactionActions(appState: appState, conversationID: conversationID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    if detail.kind == .fallback {
                        // Fallback rows have no summary; explain what was dropped in its place (same as Web).
                        Text(L10n.tr("context_compaction_detail_fallback_note", table: .chat))
                            .font(OriveoTheme.Typography.body)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let summary = detail.summary {
                        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                            sectionTitle(L10n.tr("context_compaction_detail_summary", table: .chat))
                            MarkdownMessageView(text: summary, typography: .notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Text(L10n.format(L10n.tr("context_compaction_detail_kept", table: .chat), detail.kept))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                        infoRow(L10n.tr("context_compaction_detail_model", table: .chat), value: detail.model)
                        infoRow(L10n.tr("context_compaction_detail_cost", table: .chat), value: costText)
                        infoRow(L10n.tr("context_compaction_detail_time", table: .chat), value: timeText)
                    }
                }
                .padding(OriveoTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .navigationTitle(L10n.tr("context_compaction_detail_title", table: .chat))
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var actionBar: some View {
        VStack(spacing: OriveoTheme.Spacing.sm) {
            Button {
                actions.startNewChatWithSummary()
                dismiss()
            } label: {
                Text(L10n.tr("context_compaction_action_new_chat_with_summary", table: .chat))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OriveoPrimaryButtonStyle())

            HStack(spacing: OriveoTheme.Spacing.sm) {
                Button {
                    recompact()
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(L10n.tr("context_compaction_action_recompact", table: .chat))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(OriveoSecondaryButtonStyle())

                Button {
                    let toast = appState.chatManager.clearCompaction(conversationId: conversationID)
                    ContextCompactionActions.showToast(toast)
                    dismiss()
                } label: {
                    Text(L10n.tr("context_compaction_action_clear", table: .chat))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OriveoSecondaryButtonStyle())
            }
        }
        .disabled(isRunning)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background(.bar)
    }

    private func recompact() {
        guard !isRunning else { return }
        isRunning = true
        let actions = actions
        Task {
            let toast = await actions.perform(.recompact)
            isRunning = false
            ContextCompactionActions.showToast(toast)
            dismiss()
        }
    }

    private var costText: String {
        switch detail.cost {
        case .noExtraCost:
            L10n.tr("context_compaction_detail_no_extra_cost", table: .chat)
        case .unavailable:
            L10n.tr("context_compaction_detail_cost_unavailable", table: .chat)
        case .amount(let value):
            CostFormatter.format(value).isEmpty
                ? L10n.tr("context_compaction_detail_cost_unavailable", table: .chat)
                : CostFormatter.format(value)
        }
    }

    private var timeText: String {
        detail.createdAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.currentLocale)
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.md) {
            Text(title)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
