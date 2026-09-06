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

struct ChatMessageList: View {
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
    let bottomOverlayInset: CGFloat
    let scrollButtonBottomInset: CGFloat
    let windowLoader: MessageWindowLoader

    @Binding var isAtBottom: Bool
    @Binding var autoScrollEnabled: Bool
    @Binding var composerText: String
    @Binding var pendingQuoteContext: QuoteContext?
    @Binding var showModelSwitcher: Bool
    var composerFocused: FocusState<Bool>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState

    @State private var emptyStateAppeared = false
    @State private var greetingHeadline = ""
    @State private var scrollToBottomRequest: UInt = 0
    @State private var outlineState = ChatOutlineState()
    @State private var outlineScrollRequest: UInt = 0
    @State private var outlineScrollMessageID: UUID?
    @State private var outlineScrollShouldFlash = false
    @State private var crosscheckTarget: ChatCrosscheckTarget?
    @State private var noteReferenceChoices: [NoteSummary] = []
    @State private var showNoteReferenceChoices = false
    @State private var cachedRowsKey = RowsCacheKey(
        conversationID: nil,
        messageRevision: .max,
        providerMetadataVersion: .max,
        notesVersion: .max
    )
    @State private var cachedRows: [ChatCollectionProjectionBuilder.MessageRow] = []
    @State private var cachedMetadata = ChatCollectionProviderMetadata.empty
    @State private var cachedMetadataVersion: UInt = .max

    private var preferredAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var rowsCacheKey: RowsCacheKey {
        Self.makeRowsCacheKey(
            conversationID: projection.activeConversationID,
            messageRevision: projection.messageRevision,
            providerMetadataVersion: appState.providersVersion,
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

    private var messageRows: [ChatCollectionProjectionBuilder.MessageRow] {
        if cachedRowsKey == rowsCacheKey {
            return cachedRows
        }

        return ChatCollectionProjectionBuilder.makeRows(
            from: projection.messages,
            metadata: ChatCollectionProviderMetadata.resolve(from: appState.providers),
            noteReferencesByMessageID: noteReferencesByMessageID()
        )
    }

    private var outlineTicks: [OutlineTick] {
        ChatOutline.ticks(
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
            retryCapabilitySelection: capabilitySelection
        )
    }

    var body: some View {
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
                    providerMetadataVersion: appState.providersVersion,
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
                    onSaveSelectionMessage: handleSaveSelection,
                    onAskSelectionMessage: handleAskSelection,
                    canReplaceCurrentNoteSelection: canReplaceCurrentNote,
                    onReplaceSelectionMessage: replaceSelectionHandler,
                    onSaveCodeBlockMessage: handleSaveCode,
                    onRegenerateMessage: handleRegenerateMessage,
                    onEditMessage: handleEditMessage,
                    onSwitchModelRequested: { showModelSwitcher = true },
                    onPendingSearchTargetHandled: clearPendingSearchTargetIfNeeded,
                    onDismissComposer: dismissKeyboardIfNeeded,
                    onAnchorUserMessageConsumed: { userMessageID in
                        guard let conversationID = projection.activeConversationID else { return }
                        appState.consumePendingChatAnchorUserMessageID(userMessageID, in: conversationID)
                    },
                    outlineScrollRequest: outlineScrollRequest,
                    outlineScrollMessageID: outlineScrollMessageID,
                    outlineScrollShouldFlash: outlineScrollShouldFlash,
                    onVisibleTopUserMessageChanged: { outlineState.currentUserMessageID = $0 }
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
        .onAppear {
            refreshCachedRows()
            finishEmptyStateOpenTraceIfNeeded()
            consumeNoteSourceJumpIfNeeded()
        }
        .onChange(of: projection.activeConversationID) { _, _ in
            isAtBottom = true
            autoScrollEnabled = true
            refreshCachedRows()
            finishEmptyStateOpenTraceIfNeeded()
        }
        .onChange(of: projection.messageRevision) { _, _ in
            refreshCachedRows()
            consumeNoteSourceJumpIfNeeded()
        }
        .onChange(of: windowLoader.failedAnchorMessageID) { _, _ in
            consumeNoteSourceJumpIfNeeded()
        }
        .onChange(of: appState.providersVersion) { _, _ in
            refreshCachedRows()
        }
        .onChange(of: appState.notesVersion) { _, _ in
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

    private func openNoteReferences(_ notes: [NoteSummary]) {
        guard notes.isEmpty == false else { return }
        if notes.count == 1, let note = notes.first {
            appState.openNoteDetail(noteID: note.id)
            return
        }
        noteReferenceChoices = notes
        showNoteReferenceChoices = true
    }

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
                // A structured upstream rejection is already dormant in the exact-pointer cache;
                // include the surviving custom fragment so retry omits only that located setting.
                // Local validation failures have no cache entry and still require omit-all.
                localCustomFragmentDisposition: message.errorTitle == "Custom request fields error"
                    && message.capabilityExecution?.recoveryDescriptors?.count != 1
                    ? .omitForExplicitRetry
                    : .include
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

        let restoredText: String?
        if message.role == .user {
            guard isSendingMessage == false else { return }
            restoredText = appState.editUserMessage(messageID: message.id, in: conversationID)
        } else {
            restoredText = appState.editPromptingMessage(for: message.id, in: conversationID)
        }

        guard let restoredText else { return }
        withAnimation(preferredAnimation) {
            composerText = restoredText
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

    private func refreshCachedRows() {
        let currentVersion = appState.providersVersion
        if cachedMetadataVersion != currentVersion {
            cachedMetadata = ChatCollectionProviderMetadata.resolve(from: appState.providers)
            cachedMetadataVersion = currentVersion
        }
        cachedRowsKey = rowsCacheKey
        cachedRows = ChatCollectionProjectionBuilder.makeRows(
            from: projection.messages,
            metadata: cachedMetadata,
            noteReferencesByMessageID: noteReferencesByMessageID()
        )
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
                    .foregroundStyle(.white)
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
