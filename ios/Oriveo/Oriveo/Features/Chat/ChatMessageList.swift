import Combine
import SwiftUI
import UIKit

/// The answer a cross-check was started from. Being `Identifiable` is what drives the cover.
private struct ChatCrosscheckTarget: Identifiable {
    let conversationID: UUID
    let message: ChatMessage
    let prompt: String?
    var id: UUID { message.id }
}

/// Target of the "Memory used" sheet: the item ids recorded for this reply.
private struct ChatMemoryUsedTarget: Identifiable, Equatable {
    let messageID: UUID
    let memoryItemIds: [String]

    var id: UUID { messageID }
}

enum ChatNoteReferences {
    nonisolated static func groupByMessageID(
        _ summaries: [NoteSummary],
        conversationID: UUID?
    ) -> [UUID: [NoteSummary]] {
        guard let conversationID else { return [:] }
        return Dictionary(grouping: summaries.compactMap { summary -> (UUID, NoteSummary)? in
            guard summary.sourceConversationId == conversationID,
                  let messageID = summary.sourceMessageId
            else { return nil }
            return (messageID, summary)
        }, by: \.0)
        .mapValues { pairs in
            pairs
                .map(\.1)
                .sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        }
    }

    nonisolated static func canReplaceCurrentNote(
        returnToNoteID: UUID?,
        activeNotes: [NoteSummary],
        currentMessageID: UUID?
    ) -> Bool {
        replacementNoteID(
            returnToNoteID: returnToNoteID,
            activeNotes: activeNotes,
            currentMessageID: currentMessageID
        ) != nil
    }

    nonisolated static func replacementNoteID(
        returnToNoteID: UUID?,
        activeNotes: [NoteSummary],
        currentMessageID: UUID?
    ) -> UUID? {
        if let returnToNoteID, activeNotes.contains(where: { $0.id == returnToNoteID }) {
            return returnToNoteID
        }
        guard let currentMessageID else { return nil }
        return activeNotes
            .filter { $0.sourceMessageId == currentMessageID }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first?.id
    }

    nonisolated static func canShowReplaceSelection(
        canReplaceCurrentNoteSelection: Bool,
        noteReferences: [NoteSummary]
    ) -> Bool {
        canReplaceCurrentNoteSelection || !noteReferences.isEmpty
    }
}

enum NoteSourceJumpConsumption {
    struct Decision: Equatable {
        let shouldConsume: Bool
        let scrollMessageID: UUID?
    }

    nonisolated static func resolve(
        jump: NoteSourceJump,
        activeConversationID: UUID?,
        messages: [ChatMessage],
        failedAnchorMessageID: UUID?
    ) -> Decision {
        guard jump.conversationID == activeConversationID else {
            return Decision(shouldConsume: false, scrollMessageID: nil)
        }
        guard let messageID = jump.messageID else {
            return Decision(shouldConsume: true, scrollMessageID: nil)
        }
        if messages.contains(where: { $0.id == messageID }) {
            return Decision(shouldConsume: true, scrollMessageID: messageID)
        }
        if failedAnchorMessageID == messageID {
            return Decision(shouldConsume: true, scrollMessageID: nil)
        }
        return Decision(shouldConsume: false, scrollMessageID: nil)
    }
}

struct ChatMessageList: View, Equatable {
    nonisolated struct RowsCacheKey: Equatable, Sendable {
        let conversationID: UUID?
        let messageRevision: UInt
        let providerMetadataVersion: UInt
        let notesVersion: UInt
    }

    nonisolated static func makeRowsCacheKey(
        conversationID: UUID?,
        messageRevision: UInt,
        providerMetadataVersion: UInt,
        notesVersion: UInt = 0
    ) -> RowsCacheKey {
        RowsCacheKey(
            conversationID: conversationID,
            messageRevision: messageRevision,
            providerMetadataVersion: providerMetadataVersion,
            notesVersion: notesVersion
        )
    }

    nonisolated static func shouldEnableAutoScrollWhenSendingStarts(isAtBottom: Bool) -> Bool {
        isAtBottom
    }

    nonisolated static func shouldRevealLatestWhenComposerFocuses(
        oldFocused: Bool,
        newFocused: Bool,
        isAtBottom: Bool,
        hasMessages: Bool,
        hasMoreBelow: Bool
    ) -> Bool {
        !oldFocused && newFocused && isAtBottom && hasMessages && !hasMoreBelow
    }

    let projection: ChatScreenProjection
    let conversationID: UUID?
    let isSendingMessage: Bool
    let capabilitySelection: ChatCapabilitySelection
    /// Vision input projection of the current model: when it changes the rows are rebuilt (the "not sent to this model" caption on user bubbles with images).
    var currentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil
    let bottomOverlayInset: CGFloat
    let scrollButtonBottomInset: CGFloat
    let windowLoader: MessageWindowLoader

    @Binding var isAtBottom: Bool
    @Binding var autoScrollEnabled: Bool
    /// Edit restore pushes text back to the composer; the list does not own input state.
    var onRestoreComposerText: (String) -> Void
    /// Editing puts the original message's attachments back into the composer (through the composer's own capability filtering and file count limit).
    var onRestoreComposerAttachments: ([Attachment]) -> Void = { _ in }
    /// Tapping the compaction separator row in the transcript: the host presents the compaction detail.
    var onOpenCompactionDetail: () -> Void = {}
    @Binding var pendingQuoteContext: QuoteContext?
    @Binding var showModelSwitcher: Bool
    var composerFocused: Binding<Bool>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(\.windowNavigation) private var windowNavigation
    /// This window's navigation state (one per window); a host without one injected (tests) falls back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }

    @State private var emptyStateAppeared = false
    @State private var greetingHeadline = ""
    @State private var scrollToBottomRequest: UInt = 0
    @State private var outlineState = ChatOutlineState()
    @State private var outlineScrollRequest: UInt = 0
    @State private var outlineScrollMessageID: UUID?
    @State private var outlineScrollShouldFlash = false
    @State private var crosscheckTarget: ChatCrosscheckTarget?
    /// Sheet for switching to another key after a message failed.
    @State private var switchKeyOffer: RelaySwitchKey.Offer?
    @State private var noteReferenceChoices: [NoteSummary] = []
    @State private var showNoteReferenceChoices = false
    @State private var memoryUsedTarget: ChatMemoryUsedTarget?
    /// Item picked with "This is wrong": open the memory page only after the sheet dismisses, so navigation does not race the dismiss animation.
    @State private var pendingMemoryFixItemID: String?
    /// Memory bar "Edit": the item editor in new-item mode, prefilled from the candidate.
    @State private var memorySuggestionEditTarget: MemorySuggestionEdit?
    @State private var cachedRowsKey = RowsCacheKey(
        conversationID: nil,
        messageRevision: .max,
        providerMetadataVersion: .max,
        notesVersion: .max
    )
    @State private var cachedRows: [ChatCollectionProjectionBuilder.MessageRow] = []
    /// Separator row for the latestValid compaction row (computed from the full history, not the paged window); refreshed by notification when compaction rows are added or removed.
    @State private var compactionSeparator: ContextCompactionSeparator?
    /// Separator refresh in flight; a newer refresh cancels it.
    @State private var compactionSeparatorTask: Task<Void, Never>?
    /// A reference box: reading and writing it in body does not invalidate the view.
    @State private var outlineTicksMemo = ChatOutlineTicksMemo()

    private var preferredAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var rowsCacheKey: RowsCacheKey {
        Self.makeRowsCacheKey(
            conversationID: projection.activeConversationID,
            messageRevision: projection.messageRevision,
            providerMetadataVersion: providerMetadataVersion,
            notesVersion: appState.notesVersion
        )
    }

    private var streamingPublisher: AnyPublisher<Void, Never> {
        guard let convID = projection.activeConversationID else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return appState.streamingTextDidChange(in: convID)
    }

    private var streamingReasoningPublisher: AnyPublisher<ReasoningStreamDelta, Never> {
        guard let convID = projection.activeConversationID else {
            return Empty<ReasoningStreamDelta, Never>().eraseToAnyPublisher()
        }
        return appState.streamingReasoningDidChange(in: convID)
    }

    private var streamingActivityPublisher: AnyPublisher<StreamActivityState, Never> {
        guard let convID = projection.activeConversationID else {
            return Empty<StreamActivityState, Never>().eraseToAnyPublisher()
        }
        return appState.streamingActivityDidChange(in: convID)
    }

    private var messageRows: [ChatCollectionProjectionBuilder.MessageRow] {
        if cachedRowsKey == rowsCacheKey {
            return cachedRows
        }

        return ChatCollectionProjectionBuilder.makeRows(
            from: projection.messages,
            metadata: Self.providerMetadata(in: appState),
            noteReferencesByMessageID: noteReferencesByMessageID(),
            replyNotices: appState.chatManager.relayWebReplyNotices,
            compactionSeparator: compactionSeparator,
            directiveSuggestionMessageID: directiveSuggestionMessageID,
            memorySuggestion: memorySuggestionBar,
            currentVisionInput: currentVisionInput
        )
    }

    /// The user message that the pending "Set as instruction" suggestion of the current conversation is attached to (the controller is @Observable, so rows refresh on change).
    private var directiveSuggestionMessageID: UUID? {
        appState.directiveSuggestions.pending(in: projection.activeConversationID)?.messageID
    }

    /// The pending "Save to memory?" bar of the current conversation (the controller is @Observable, so rows refresh on change).
    private var memorySuggestionBar: MemorySuggestionBar? {
        appState.memorySuggestions.pending(in: projection.activeConversationID)?.bar
    }

    /// Whether compaction rows of this conversation were added or removed (userInfo carries the conversation id).
    nonisolated static func isCheckpointChange(_ note: Notification, conversationID: UUID?) -> Bool {
        guard let conversationID,
              let changed = note.userInfo?[ContextCompactionStore.conversationIdKey] as? String
        else { return false }
        return changed == conversationID.uuidString
    }

    /// Outline rail ticks (one per user question).
    private var outlineTicks: [OutlineTick] {
        outlineTicksMemo.ticks(
            from: projection.messages,
            attachmentLabel: L10n.tr("(Attachment)", table: .chat)
        )
    }

    private var controllerViewModel: ChatCollectionViewModel {
        ChatCollectionViewModel(
            conversationID: projection.activeConversationID,
            messageRevision: projection.messageRevision,
            rows: messageRows,
            isSendingMessage: isSendingMessage,
            streamingMessageID: projection.activeConversationID.flatMap { appState.streamingMessageID(in: $0) },
            streamingText: projection.activeConversationID.map { appState.streamingText(in: $0) } ?? "",
            pendingAnchorUserMessageID: projection.activeConversationID.flatMap {
                appState.pendingChatAnchorUserMessageID(in: $0)
            },
            pendingSearchScrollTarget: appState.pendingSearchScrollTarget,
            isBootstrappingPersistedConversation: projection.isBootstrappingPersistedConversation,
            retryCapabilitySelection: capabilitySelection,
            compactionSeparator: compactionSeparator,
            directiveSuggestionMessageID: directiveSuggestionMessageID,
            memorySuggestion: memorySuggestionBar,
            currentVisionInput: currentVisionInput
        )
    }

    #if DEBUG
    nonisolated(unsafe) static var bodyEvaluationCount = 0
    /// When non-nil, only this conversation's body evaluations are counted: the counter is a process-wide static, so instances mounted by other tests
    /// (indirectly through AppRootView and the like, or late renders) must not be counted.
    nonisolated(unsafe) static var bodyCountConversationID: UUID?
    static func resetBodyEvaluationCount(countingOnly conversationID: UUID? = nil) {
        bodyEvaluationCount = 0
        bodyCountConversationID = conversationID
    }
    #endif

    static func == (lhs: ChatMessageList, rhs: ChatMessageList) -> Bool {
        // Do not compare the full `projection` (it walks every message body),
        // and do not compare insets (the keyboard would jitter).
        lhs.conversationID == rhs.conversationID
            && lhs.projection.messageRevision == rhs.projection.messageRevision
            && lhs.projection.loadState == rhs.projection.loadState
            && lhs.isSendingMessage == rhs.isSendingMessage
            && lhs.capabilitySelection == rhs.capabilitySelection
            && lhs.currentVisionInput == rhs.currentVisionInput
            && lhs.windowLoader.hasMoreAbove == rhs.windowLoader.hasMoreAbove
            && lhs.windowLoader.hasMoreBelow == rhs.windowLoader.hasMoreBelow
    }

    var body: some View {
        #if DEBUG
        let _ = {
            if Self.bodyCountConversationID == nil || Self.bodyCountConversationID == conversationID {
                Self.bodyEvaluationCount += 1
            }
        }()
        #endif
        let canReplaceCurrentNote = ChatNoteReferences.canReplaceCurrentNote(
            returnToNoteID: appState.activeReturnToNoteID,
            activeNotes: appState.noteSummaries,
            currentMessageID: nil
        )
        let replaceSelectionHandler: (ChatMessage, String) -> Void = { message, text in
            handleReplaceSelection(message, text)
        }

        ZStack(alignment: .bottomTrailing) {
            if projection.messages.isEmpty {
                emptyStateContent
                    .padding(.bottom, bottomOverlayInset)
            } else {
                ChatListViewControllerRepresentable(
                    viewModel: controllerViewModel,
                    requestedAutoScrollEnabled: autoScrollEnabled,
                    providerMetadataVersion: providerMetadataVersion,
                    scrollToBottomRequest: scrollToBottomRequest,
                    streamingTextPublisher: streamingPublisher,
                    streamingReasoningPublisher: streamingReasoningPublisher,
                    streamingTextProvider: { [appState, conversationID = projection.activeConversationID] in
                        guard let id = conversationID else { return "" }
                        return appState.streamingText(in: id)
                    },
                    streamingReasoningSnapshotProvider: { [appState, conversationID = projection.activeConversationID] in
                        guard let id = conversationID else { return nil }
                        return appState.streamingReasoningSnapshot(in: id)
                    },
                    streamingActivityPublisher: streamingActivityPublisher,
                    streamingActivityProvider: { [appState, conversationID = projection.activeConversationID] in
                        guard let id = conversationID else { return nil }
                        return appState.streamingActivity(in: id)
                    },
                    hasMoreAbove: windowLoader.hasMoreAbove,
                    hasMoreBelow: windowLoader.hasMoreBelow,
                    onRequestExtendUpward: { [windowLoader] in
                        windowLoader.extendUpward()
                    },
                    isAtBottom: $isAtBottom,
                    autoScrollEnabled: $autoScrollEnabled,
                    onRetryMessage: { handleRetryMessage($0) },
                    onContinueMessage: handleContinueMessage,
                    onSaveNoteMessage: handleSaveNote,
                    onOpenNoteReferences: openNoteReferences,
                    onCrosscheckMessage: handleCrosscheck,
                    onMcpStepAction: handleMcpStepAction,
                    onOpenMemoryUsed: handleOpenMemoryUsed,
                    onSaveSelectionMessage: handleSaveSelection,
                    onAskSelectionMessage: handleAskSelection,
                    canReplaceCurrentNoteSelection: canReplaceCurrentNote,
                    onReplaceSelectionMessage: replaceSelectionHandler,
                    onSaveCodeBlockMessage: handleSaveCode,
                    onOpenCompactionDetail: onOpenCompactionDetail,
                    onAcceptDirectiveSuggestion: {
                        guard let conversationID = projection.activeConversationID else { return }
                        appState.directiveSuggestions.acceptWithUndoToast(conversationID: conversationID, appState: appState)
                    },
                    onIgnoreDirectiveSuggestion: {
                        guard let conversationID = projection.activeConversationID else { return }
                        appState.directiveSuggestions.ignore(conversationID: conversationID)
                    },
                    onSaveMemorySuggestion: {
                        guard let conversationID = projection.activeConversationID else { return }
                        appState.memorySuggestions.saveWithUndoToast(conversationID: conversationID, appState: appState)
                    },
                    onEditMemorySuggestion: {
                        guard let conversationID = projection.activeConversationID else { return }
                        memorySuggestionEditTarget = appState.memorySuggestions.edit(conversationID: conversationID)
                    },
                    onIgnoreMemorySuggestion: {
                        guard let conversationID = projection.activeConversationID else { return }
                        Task { await appState.memorySuggestions.ignore(conversationID: conversationID, appState: appState) }
                    },
                    onRegenerateMessage: handleRegenerateMessage,
                    onEditMessage: handleEditMessage,
                    onSwitchModelRequested: { showModelSwitcher = true },
                    offersSwitchKey: { RelaySwitchKey.offer(for: $0, providers: appState.providers) != nil },
                    onSwitchKeyRequested: { message in
                        switchKeyOffer = RelaySwitchKey.offer(for: message, providers: appState.providers)
                    },
                    onPendingSearchTargetHandled: clearPendingSearchTargetIfNeeded,
                    onDismissComposer: dismissKeyboardIfNeeded,
                    onAnchorUserMessageConsumed: { userMessageID in
                        guard let conversationID = projection.activeConversationID else { return }
                        appState.consumePendingChatAnchorUserMessageID(userMessageID, in: conversationID)
                    },
                    outlineScrollRequest: outlineScrollRequest,
                    outlineScrollMessageID: outlineScrollMessageID,
                    outlineScrollShouldFlash: outlineScrollShouldFlash,
                    onVisibleTopUserMessageChanged: { outlineState.currentUserMessageID = $0 },
                    carrierHandoff: navigation.chatHandoff
                )
            }

            if outlineTicks.count > ChatOutline.minUserTurns {
                ChatOutlineRail(
                    ticks: outlineTicks,
                    outlineState: outlineState,
                    onJumpTo: { id in
                        outlineScrollShouldFlash = false
                        outlineScrollMessageID = id
                        outlineScrollRequest &+= 1
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }

            scrollToBottomButton(hasMessages: projection.messages.isEmpty == false) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                autoScrollEnabled = true
                isAtBottom = true
                if windowLoader.hasMoreBelow {
                    windowLoader.jumpToLatest()
                }
                scrollToBottomRequest &+= 1
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(item: $crosscheckTarget) { target in
            CrosscheckSheet(origin: .chatMessage(
                conversationID: target.conversationID,
                message: target.message,
                prompt: target.prompt
            ))
            .environment(appState)
            .interactiveDismissDisabled(true)
        }
        .sheet(item: $switchKeyOffer) { offer in
            // Picking a key only rebinds and closes the sheet; it never resends on its own (the user taps the existing retry).
            RelaySwitchKeySheet(offer: offer) { keyID in
                let manager = appState.providerManager
                Task { await RelaySwitchKey.select(offer, keyID: keyID, manager: manager) }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            L10n.tr("Saved notes", table: .notes),
            isPresented: $showNoteReferenceChoices,
            titleVisibility: .visible
        ) {
            ForEach(noteReferenceChoices, id: \.id) { note in
                Button(NoteText.displayTitle(note.title)) {
                    appState.openNoteDetail(noteID: note.id)
                }
            }
            Button(L10n.tr("Cancel", table: .notes), role: .cancel) {}
        }
        .sheet(item: $memorySuggestionEditTarget) { target in
            // Cancel just closes the sheet and keeps the bar.
            MemoryItemEditorSheet(state: target.state) { saved in
                appState.memorySuggestions.saveEditedWithUndoToast(saved, for: target, appState: appState)
            }
        }
        .sheet(item: $memoryUsedTarget, onDismiss: {
            guard let itemID = pendingMemoryFixItemID else { return }
            pendingMemoryFixItemID = nil
            appState.openMemory(editItemId: itemID)
        }) { target in
            MemoryUsedSheet(
                rows: MemoryUsedPresentation.rows(
                    ids: target.memoryItemIds, items: appState.memoryItemsCache.items
                ),
                onFix: { itemID in
                    pendingMemoryFixItemID = itemID
                    memoryUsedTarget = nil
                },
                onDismiss: { memoryUsedTarget = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            refreshConversationModelLookup()
            refreshCompactionSeparator()
            refreshCachedRows()
            finishEmptyStateOpenTraceIfNeeded()
            consumeNoteSourceJumpIfNeeded()
        }
        .onChange(of: projection.activeConversationID) { _, _ in
            isAtBottom = true
            autoScrollEnabled = true
            refreshCompactionSeparator()
            refreshCachedRows()
            finishEmptyStateOpenTraceIfNeeded()
        }
        .onChange(of: projection.messageRevision) { _, _ in
            // Editing or deleting a message invalidates the compaction row, so recompute with the message revision.
            refreshCompactionSeparator()
            refreshCachedRows()
            consumeNoteSourceJumpIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .contextCheckpointsDidChange)
                .receive(on: DispatchQueue.main)
        ) { note in
            guard Self.isCheckpointChange(note, conversationID: projection.activeConversationID) else { return }
            refreshCompactionSeparator()
        }
        .onChange(of: windowLoader.failedAnchorMessageID) { _, _ in
            consumeNoteSourceJumpIfNeeded()
        }
        .onChange(of: appState.providersVersion) { _, _ in
            refreshConversationModelLookup()
            refreshCachedRows()
        }
        .onChange(of: appState.conversationModelLookupStore.revision) { _, _ in
            refreshCachedRows()
        }
        // A relay avatar changed: rebuild the lookup; once merged, message headers refresh by revision above.
        .onChange(of: RelayAvatarChoiceStore.shared.revision) { _, _ in
            refreshConversationModelLookup()
        }
        .onChange(of: appState.notesVersion) { _, _ in
            refreshCachedRows()
        }
        .onChange(of: directiveSuggestionMessageID) { _, _ in
            refreshCachedRows()
        }
        .onChange(of: currentVisionInput) { _, _ in
            refreshCachedRows()
        }
        .onChange(of: memorySuggestionBar) { _, _ in
            refreshCachedRows()
        }
        .onChange(of: isSendingMessage) { oldValue, newValue in
            if !oldValue && newValue && Self.shouldEnableAutoScrollWhenSendingStarts(isAtBottom: isAtBottom) {
                autoScrollEnabled = true
            }
        }
        .onChange(of: composerFocused.wrappedValue) { oldValue, newValue in
            guard Self.shouldRevealLatestWhenComposerFocuses(
                oldFocused: oldValue,
                newFocused: newValue,
                isAtBottom: isAtBottom,
                hasMessages: projection.messages.isEmpty == false,
                hasMoreBelow: windowLoader.hasMoreBelow
            ) else { return }
            autoScrollEnabled = true
            scrollToBottomRequest &+= 1
        }
        .onDisappear {
            clearPendingSearchTargetIfNeeded()
        }
    }

    private func handleAskSelection(_ message: ChatMessage, _ content: QuoteSelectionContent) {
        switch QuoteContext.capture(
            sourceMessageID: message.id,
            sourceRole: message.role,
            contentKind: content.contentKind,
            leadingText: content.leadingText,
            selectedText: content.selectedText,
            trailingText: content.trailingText
        ) {
        case .success(let quote):
            pendingQuoteContext = quote
            composerFocused.wrappedValue = true
        case .failure(.selectionTooLong):
            ToastManager.shared.show(
                L10n.tr("Selection is too long. Select a shorter passage.", table: .chat)
            )
        case .failure(.emptySelection):
            break
        }
    }

    private var emptyStateContent: some View {
        Group {
            if projection.isBootstrappingPersistedConversation {
                ScrollView {
                    persistedConversationBootstrapState
                        .padding(.horizontal, OriveoTheme.Spacing.xl)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                GeometryReader { geo in
                    ScrollView {
                        emptyConversationState
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
    }

    private func handleSaveNote(_ message: ChatMessage) {
        guard let conversationID else { return }
        let draft: NoteDraft
        if message.role == .user {
            draft = NoteCaptureBuilder.userMessage(message: message, conversationID: conversationID)
        } else {
            let prompt = NoteSourceResolver.previousUserPrompt(before: message.id, in: projection.messages)
            draft = NoteCaptureBuilder.fullAnswer(message: message, conversationID: conversationID, prompt: prompt)
        }
        saveDraftWithToast(draft)
    }

    private func handleSaveSelection(_ message: ChatMessage, _ text: String) {
        guard let conversationID else { return }
        let prompt = NoteSourceResolver.previousUserPrompt(before: message.id, in: projection.messages)
        saveDraftWithToast(NoteCaptureBuilder.selection(text: text, message: message, conversationID: conversationID, prompt: prompt))
    }

    private func handleReplaceSelection(_ message: ChatMessage, _ text: String) {
        guard let conversationID,
              let noteID = ChatNoteReferences.replacementNoteID(
                returnToNoteID: appState.activeReturnToNoteID,
                activeNotes: appState.noteSummaries,
                currentMessageID: message.id
              ),
              appState.noteManager.note(id: noteID) != nil else { return }
        let prompt = NoteSourceResolver.previousUserPrompt(before: message.id, in: projection.messages)
        let draft = NoteCaptureBuilder.selection(text: text, message: message, conversationID: conversationID, prompt: prompt)
        guard let note = appState.noteManager.replaceNote(id: noteID, with: draft) else { return }
        ToastManager.shared.show(
            L10n.tr("Note replaced", table: .notes),
            style: .success,
            duration: 4,
            actionTitle: L10n.tr("View", table: .notes)
        ) {
            appState.openNoteDetail(noteID: note.id)
        }
    }

    private func handleSaveCode(_ message: ChatMessage, _ code: String, _ lang: String?) {
        guard let conversationID else { return }
        let prompt = NoteSourceResolver.previousUserPrompt(before: message.id, in: projection.messages)
        saveDraftWithToast(NoteCaptureBuilder.codeBlock(code: code, language: lang, message: message, conversationID: conversationID, prompt: prompt))
    }

    private func saveDraftWithToast(_ draft: NoteDraft) {
        guard let note = appState.noteManager.createNote(from: draft) else { return }
        ToastManager.shared.show(
            NoteText.displayTitle(note.title),
            style: .success,
            duration: 4,
            actionTitle: L10n.tr("View", table: .notes)
        ) {
            appState.openNoteDetail(noteID: note.id)
        }
    }

    private func noteReferencesByMessageID() -> [UUID: [NoteSummary]] {
        ChatNoteReferences.groupByMessageID(appState.noteSummaries, conversationID: conversationID)
    }

    private func handleCrosscheck(_ message: ChatMessage) {
        guard let conversationID else { return }
        let prompt = NoteSourceResolver.previousUserPrompt(before: message.id, in: projection.messages)
        crosscheckTarget = ChatCrosscheckTarget(conversationID: conversationID, message: message, prompt: prompt)
    }

    /// The two buttons of an MCP step block stopped at "sign in again".
    /// Skip: that step is fed back as `auth_skipped` and the answer goes on. Re-authorize: opens that
    /// server's detail page to sign in; after a successful sign-in the page calls
    /// `mcpReauthorizationCoordinator.serverReauthorized` and the loop resumes from this step.
    private func handleMcpStepAction(_ message: ChatMessage, _ action: McpToolStepAction) {
        switch action {
        case let .skip(step):
            guard let conversationID else { return }
            appState.mcpReauthorizationCoordinator.skip(conversationID: conversationID, stepID: step.id)
        case let .reauthorize(step):
            guard let serverID = UUID(uuidString: step.serverId) else {
                navigation.path.append(.mcpServers)
                return
            }
            navigation.path.append(.mcpServerDetail(serverID: serverID, intent: .reauthorize))
        }
    }

    private func openNoteReferences(_ notes: [NoteSummary]) {
        guard notes.isEmpty == false else { return }
        if notes.count == 1, let note = notes.first {
            appState.openNoteDetail(noteID: note.id)
            return
        }
        noteReferenceChoices = notes
        showNoteReferenceChoices = true
    }

    private func handleOpenMemoryUsed(_ message: ChatMessage) {
        guard !message.memoryItemIds.isEmpty else { return }
        memoryUsedTarget = ChatMemoryUsedTarget(messageID: message.id, memoryItemIds: message.memoryItemIds)
    }

    /// Back from a note to the conversation: once the window is loaded around the target, locate sourceMessageId with the outline scroll mechanism and show the "Back to note" bar at the top.
    private func consumeNoteSourceJumpIfNeeded() {
        guard let jump = appState.pendingNoteSourceJump,
              jump.conversationID == projection.activeConversationID else { return }
        let decision = NoteSourceJumpConsumption.resolve(
            jump: jump,
            activeConversationID: projection.activeConversationID,
            messages: projection.messages,
            failedAnchorMessageID: windowLoader.failedAnchorMessageID
        )
        guard decision.shouldConsume else { return }
        if let messageID = decision.scrollMessageID {
            outlineScrollShouldFlash = true
            outlineScrollMessageID = messageID
            outlineScrollRequest &+= 1
        }
        appState.activeReturnToNoteID = jump.fromNoteID
        appState.pendingNoteSourceJump = nil
    }


    private func handleRetryMessage(
        _ message: ChatMessage,
        fundingPreference: Int = 0
    ) {
        guard let conversationID else { return }
        Task {
            await appState.retryMessage(
                messageID: message.id,
                in: conversationID,
                capabilitySelection: capabilitySelection,
                localCustomFragmentDisposition: .forExplicitRetry(
                    errorTitle: message.errorTitle,
                    recoveryDescriptorCount: message.capabilityExecution?.recoveryDescriptors?.count
                )
            )
        }
    }

    private func handleContinueMessage(_ message: ChatMessage) {
        guard let conversationID else { return }
        Task {
            await appState.continueMessage(
                messageID: message.id,
                in: conversationID,
                capabilitySelection: capabilitySelection
            )
        }
    }

    private func handleRegenerateMessage(_ message: ChatMessage) {
        guard let conversationID else { return }
        Task {
            await appState.regenerateMessage(
                messageID: message.id,
                in: conversationID,
                capabilitySelection: capabilitySelection
            )
        }
    }

    private func handleEditMessage(_ message: ChatMessage) {
        guard let conversationID else { return }

        let restoredQuoteContext: QuoteContext? = {
            if message.role == .user { return message.quoteContext }
            guard let index = projection.messages.firstIndex(where: { $0.id == message.id }), index > 0 else {
                return nil
            }
            return projection.messages[..<index].last(where: { $0.role == .user })?.quoteContext
        }()

        let draft: ComposerEditDraft?
        if message.role == .user {
            guard isSendingMessage == false else { return }
            draft = appState.beginEditingUserMessage(messageID: message.id, in: conversationID)
        } else {
            draft = appState.beginEditingPromptingMessage(for: message.id, in: conversationID)
        }

        guard let draft else { return }
        withAnimation(preferredAnimation) {
            onRestoreComposerText(draft.text)
            onRestoreComposerAttachments(draft.attachments)
            pendingQuoteContext = restoredQuoteContext?.isValid == true ? restoredQuoteContext : nil
            composerFocused.wrappedValue = true
        }
    }

    private func clearPendingSearchTargetIfNeeded() {
        if appState.pendingSearchScrollTarget?.conversationID == projection.activeConversationID {
            appState.pendingSearchScrollTarget = nil
        }
    }

    private func dismissKeyboardIfNeeded() {
        guard composerFocused.wrappedValue else { return }
        composerFocused.wrappedValue = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// Provider / model display metadata for this screen's message rows: reads the lookup Home also uses, built in
    /// the background, instead of building one on the main thread. Building it per message revision and per
    /// provider change took hundreds of milliseconds with a 22k-model relay catalog.
    static func providerMetadata(in appState: AppState) -> ChatCollectionProviderMetadata {
        ChatCollectionProviderMetadata.current(from: appState.conversationModelLookupStore)
    }

    /// Row metadata version: rows are rebuilt and visible cells refreshed when providers change (other provider state
    /// in the cell) or when the shared lookup merges a new build (names changed). Both counters only go up, so their
    /// sum only goes up too.
    private var providerMetadataVersion: UInt {
        appState.providersVersion &+ appState.conversationModelLookupStore.revision
    }

    private func refreshConversationModelLookup() {
        appState.conversationModelLookupStore.refresh(providers: appState.providers)
    }

    private func refreshCachedRows() {
        cachedRowsKey = rowsCacheKey
        cachedRows = ChatCollectionProjectionBuilder.makeRows(
            from: projection.messages,
            metadata: Self.providerMetadata(in: appState),
            noteReferencesByMessageID: noteReferencesByMessageID(),
            replyNotices: appState.chatManager.relayWebReplyNotices,
            compactionSeparator: compactionSeparator,
            directiveSuggestionMessageID: directiveSuggestionMessageID,
            memorySuggestion: memorySuggestionBar,
            currentVisionInput: currentVisionInput
        )
    }

    /// The separator is computed in the background and only assigned back on the main thread; a newer refresh cancels the older one. Rows are rebuilt only when the separator changed (it is not part of the row cache key).
    private func refreshCompactionSeparator() {
        compactionSeparatorTask?.cancel()
        let conversationID = projection.activeConversationID
        compactionSeparatorTask = Task { @MainActor in
            let next = await ContextCompactionSeparator.current(in: appState, conversationID: conversationID)
            guard !Task.isCancelled, conversationID == projection.activeConversationID,
                  next != compactionSeparator
            else { return }
            compactionSeparator = next
            refreshCachedRows()
        }
    }

    private func finishEmptyStateOpenTraceIfNeeded() {
        guard projection.messages.isEmpty else { return }
        guard projection.isBootstrappingPersistedConversation == false else { return }
    }

    @ViewBuilder
    private func scrollToBottomButton(hasMessages: Bool, onTap: @escaping () -> Void) -> some View {
        let isStreamingHere = projection.activeConversationID
            .flatMap { appState.streamingMessageID(in: $0) } != nil
        let effectivelyAtBottom = isAtBottom || (autoScrollEnabled && isStreamingHere)
        if !effectivelyAtBottom && hasMessages {
            Button(action: onTap) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(
                        Capsule()
                            .fill(OriveoTheme.Palette.primaryGradient)
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
                            )
                            .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 18, y: 8)
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, OriveoTheme.Spacing.lg)
            .padding(.bottom, scrollButtonBottomInset)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.86).combined(with: .opacity)
                        .animation(.spring(response: 0.32, dampingFraction: 0.78)),
                    removal: .opacity.animation(.easeOut(duration: 0.18))
                )
            )
            .accessibilityLabel(L10n.tr("Jump to latest"))
        }
    }

    private var activeSkill: Skill? {
        projection.skillID.flatMap { appState.skillManager.skill(by: $0) }
    }

    private var emptyStateSubtitle: String {
        if let skill = activeSkill {
            let description = skill.localizedDescription
            if !description.isEmpty { return description }
        }
        return L10n.tr("Ask anything, or just start typing.", table: .chat)
    }

    private var emptyConversationState: some View {
        VStack(spacing: OriveoTheme.Spacing.xl) {
            ZStack {
                if let skill = activeSkill {
                    Text(skill.icon)
                        .font(.system(size: 60))
                } else {
                    Circle()
                        .fill(OriveoTheme.Palette.primaryGlow)
                        .frame(width: 120, height: 120)
                        .blur(radius: 26)
                        .opacity(emptyStateAppeared ? 0.85 : 0)
                        .scaleEffect(emptyStateAppeared ? 1.06 : 0.92)

                    Image("OriveoLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                }
            }
            .scaleEffect(emptyStateAppeared ? 1 : 0.86)
            .opacity(emptyStateAppeared ? 1 : 0)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                Text(greetingHeadline.isEmpty ? L10n.tr("What should we explore?", table: .chat) : greetingHeadline)
                    .font(OriveoTheme.Typography.hero)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .opacity(emptyStateAppeared ? 1 : 0)

                Text(emptyStateSubtitle)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .opacity(emptyStateAppeared ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.xxl)
        .onAppear {
            if greetingHeadline.isEmpty {
                greetingHeadline = Self.greetingOptions.randomElement() ?? L10n.tr("What should we explore?", table: .chat)
            }
            withAnimation(preferredAnimation) {
                emptyStateAppeared = true
            }
        }
    }

    private static let greetingOptions: [String] = [
        L10n.tr("What should we explore?", table: .chat),
        L10n.tr("Where should we begin?", table: .chat),
        L10n.tr("What's on your mind?", table: .chat),
        L10n.tr("What can we figure out together?", table: .chat)
    ]

    private var persistedConversationBootstrapState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            if projection.loadState == .bootstrapping {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(L10n.tr("Loading conversation…", table: .chat))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            bootstrapBubble(alignment: .leading, width: 0.44, minHeight: 58)
            bootstrapBubble(alignment: .trailing, width: 0.58, minHeight: 72, tinted: true)
            bootstrapBubble(alignment: .leading, width: 0.36, minHeight: 48)
            bootstrapBubble(alignment: .trailing, width: 0.52, minHeight: 64, tinted: true)
        }
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .bottom)
        .padding(.top, OriveoTheme.Spacing.xl)
        .padding(.bottom, OriveoTheme.Spacing.xl)
    }

    @ViewBuilder
    private func bootstrapBubble(
        alignment: HorizontalAlignment,
        width: CGFloat,
        minHeight: CGFloat,
        tinted: Bool = false
    ) -> some View {
        HStack {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                bootstrapLine(width: 0.68)
                bootstrapLine(width: 0.92)
                bootstrapLine(width: 0.54)
            }
            .frame(maxWidth: 560 * width, minHeight: minHeight, alignment: .leading)
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        tinted
                        ? OriveoTheme.Palette.primary.opacity(0.08)
                        : OriveoTheme.Palette.surfaceElevated
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(OriveoTheme.Palette.hairline, lineWidth: 1)
            )
            .shadow(color: OriveoTheme.Palette.shadow.opacity(0.04), radius: 16, y: 8)
            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
    }

    private func bootstrapLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(OriveoTheme.Palette.textTertiary.opacity(0.12))
            .frame(maxWidth: 360 * width, minHeight: 10, maxHeight: 10)
    }
}
