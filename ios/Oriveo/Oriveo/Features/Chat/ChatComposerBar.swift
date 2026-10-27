import SwiftUI

func formatProviderResetAt(
    _ resetAt: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")

    return formatter.string(from: resetAt)
}

private struct NoteRecallTaskID: Hashable {
    let draftSample: String
    let notesVersion: UInt
    let isSendingMessage: Bool
}

/// ChatView pushes clear-after-send / send-fail restore / edit restore into the bar.
/// The token is the trigger so typing does not live in ChatView `@State` and rebuild the page.
/// The stored draft does not come through here; the bar reconciles it against `storeDraft`
/// itself (see `ChatComposerDraftSession`).
struct ChatComposerTextPush: Equatable {
    var token: UInt = 0
    var text: String = ""

    mutating func push(_ text: String) {
        token += 1
        self.text = text
    }
}

/// Reconciliation state between the composer and the conversation's stored draft. It changes only
/// on discrete events (conversation switch, focus loss, disappear, background, store echo).
///
/// Deduplication uses only the stored value this bar knows about (read on entry, last written, or
/// an external change), never ChatView's live projection: the two onDisappear callbacks run in no
/// guaranteed order, and once the observation stops first the projected draft reads "".
struct ChatComposerDraftSession: Equatable {
    struct Write: Equatable {
        let conversationID: UUID
        let text: String
    }

    private(set) var isBound = false
    private(set) var conversationID: UUID?
    /// Known stored draft; nil means the bar has not read the store yet (new conversation or
    /// observation not ready) and counts as "" when deduplicating.
    private(set) var persistedText: String?
    /// The last observed store value. When the conversation is not in memory, it tells a real store
    /// change apart from the same value being read again after the observation restarts.
    private var lastStoreDraft: String?

    /// Binds to a conversation and returns the text the composer should show. The caller commits the
    /// previous conversation first.
    mutating func bind(conversationID: UUID?, storeDraft: String?) -> String {
        isBound = true
        self.conversationID = conversationID
        persistedText = storeDraft
        lastStoreDraft = storeDraft
        return storeDraft ?? ""
    }

    /// Writes only when the text differs from the known stored value. A write counts as stored right
    /// away; its asynchronous echo is filtered by `reconcile`.
    mutating func commit(_ text: String) -> Write? {
        guard isBound, let conversationID, text != (persistedText ?? "") else { return nil }
        persistedText = text
        return Write(conversationID: conversationID, text: text)
    }

    /// Reconciles a change of the stored draft and returns the text to put in the composer
    /// (nil leaves the composer alone).
    /// - Parameter latestDraft: The conversation's latest draft in memory. Store writes are
    ///   asynchronous and memory is synchronous, so a mismatch means this is the echo of an older write.
    mutating func reconcile(
        storeDraft: String?,
        latestDraft: String?,
        composerText: String,
        isFocused: Bool
    ) -> String? {
        guard isBound, let storeDraft else { return nil }
        let previousStoreDraft = lastStoreDraft
        lastStoreDraft = storeDraft

        guard let persistedText else {
            // First store read: this bar has not written anything, so there is no stale echo. Keep
            // existing input (typed first, or restored after a failed first send); it is written
            // back on focus loss or when leaving.
            self.persistedText = storeDraft
            return composerText.isEmpty && !storeDraft.isEmpty ? storeDraft : nil
        }
        if let latestDraft {
            guard latestDraft == storeDraft else { return nil }
        } else {
            guard storeDraft != previousStoreDraft else { return nil }
        }
        // The echo of our own write, or already in sync.
        guard storeDraft != persistedText else { return nil }
        self.persistedText = storeDraft
        // An external change (regenerate clearing the draft, an edit restore). Do not interrupt
        // typing while focused; focus loss writes the current text back.
        guard !isFocused, storeDraft != composerText else { return nil }
        return storeDraft
    }
}

enum QuoteContextChipPresentation {
    case composer
    case sentMessage
}

struct QuoteContextChip: View {
    let quote: QuoteContext
    var allowsRemoval = false
    var presentation: QuoteContextChipPresentation = .composer
    var onRemove: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showsPreview = false
    /// Height of the hosting window; nil until measured, in which case the preview cap falls back to 420.
    @State private var hostWindowHeight: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showsPreview.toggle()
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconForeground)
                    Text(quote.summaryText)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(summaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, chipShape)
                .hoverEffect(.highlight)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsPreview, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                quotePreview
                    .presentationCompactAdaptation(.popover)
            }
            .background { HostWindowHeightReader { hostWindowHeight = $0 } }
            .accessibilityLabel("\(L10n.tr("Selected content", table: .chat)): \(quote.summaryText)")

            if allowsRemoval, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(removeForeground)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Remove quote", table: .chat))
            }
        }
        .padding(.leading, OriveoTheme.Spacing.md)
        .padding(.trailing, allowsRemoval ? 2 : OriveoTheme.Spacing.md)
        .padding(.vertical, 2)
        .background { chipBackground }
        .shadow(color: chipShadowColor, radius: chipShadowRadius, y: chipShadowYOffset)
        .accessibilityElement(children: .contain)
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    @ViewBuilder
    private var chipBackground: some View {
        switch presentation {
        case .composer:
            chipShape
                .fill(OriveoTheme.Palette.surfaceElevated.opacity(colorScheme == .dark ? 0.78 : 0.92))
                .overlay {
                    chipShape.fill(
                        OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 0.66 : 0.54)
                    )
                }
        case .sentMessage:
            chipShape.fill(Color.white.opacity(0.12))
        }
    }

    private var iconForeground: Color {
        switch presentation {
        case .composer: OriveoTheme.Palette.primary
        case .sentMessage: Color.white.opacity(0.72)
        }
    }

    private var summaryForeground: Color {
        switch presentation {
        case .composer: OriveoTheme.Palette.textSecondary
        case .sentMessage: Color.white.opacity(0.92)
        }
    }

    private var removeForeground: Color {
        switch presentation {
        case .composer: OriveoTheme.Palette.textSecondary
        case .sentMessage: Color.white.opacity(0.78)
        }
    }

    private var chipShadowColor: Color {
        guard presentation == .composer else { return .clear }
        return OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.36 : 0.45)
    }

    private var chipShadowRadius: CGFloat {
        presentation == .composer ? (colorScheme == .dark ? 12 : 9) : 0
    }

    private var chipShadowYOffset: CGFloat {
        presentation == .composer ? (colorScheme == .dark ? 4 : 3) : 0
    }

    private var quotePreview: some View {
        ScrollView {
            Text(highlightedContext)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OriveoTheme.Spacing.lg)
                .accessibilityLabel(
                    "\(L10n.tr("Selected content", table: .chat)): \(quote.selectedText). "
                    + "\(L10n.tr("Full quoted context", table: .chat)): \(quote.fullContextText)"
                )
        }
        .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
        .frame(maxHeight: quotePreviewMaxHeight)
        .background(OriveoTheme.Palette.surface)
    }

    /// The cap follows the hosting window's height: on the Duo cover screen or in a resized window
    /// the window height is not the screen height.
    private var quotePreviewMaxHeight: CGFloat {
        guard let hostWindowHeight else { return 420 }
        return min(420, hostWindowHeight * 0.6)
    }

    private var highlightedContext: AttributedString {
        var result = AttributedString()
        if quote.contextTruncated { result += AttributedString("…") }
        result += AttributedString(quote.leadingText)
        var selected = AttributedString(quote.selectedText)
        selected.backgroundColor = OriveoTheme.Palette.quoteSelectionHighlight
        selected.foregroundColor = OriveoTheme.Palette.textPrimary
        result += selected
        result += AttributedString(quote.trailingText)
        if quote.contextTruncated { result += AttributedString("…") }
        return result
    }
}

/// Chat composer: attachments, capability controls, text input, and send/cancel actions.
struct ChatComposerBar: View {
    let provider: Provider
    let currentModel: AIModel?
    /// Set when the conversation's model has been removed: a banner shows above the input and sending is disabled.
    var modelRemovedBanner: ChatModelRemovedBanner? = nil
    let visibleCapabilityKeys: Set<String>
    let capabilityEvidenceIdentity: CapabilityEvidenceRequestIdentity?
    /// Availability, disabled reasons and first-attach hints of the attachment entries (image / video / file); ChatView computes them from the facade entry and passes them in.
    var attachmentEntries: ComposerAttachmentEntries = .closed
    let generationProjection: GenerationParameterEvidenceProjection?
    let capabilityDecision: ChatCapabilityOutboundDecision
    let isSendingMessage: Bool
    var conversationID: UUID? = nil
    let generationParameterScopeID: UUID
    var isReadOnly: Bool = false
    var transparentChrome: Bool = false
    /// The conversation's stored draft; nil means the observation is not ready or has stopped (not
    /// that the draft is empty). The live input lives in this bar's `@State`.
    let storeDraft: String?
    /// External push (clear after send, restore after failure, restore from edit).
    /// Ignored while the token is unchanged.
    let textPush: ChatComposerTextPush
    /// Persists the draft on conversation switch, focus loss, disappear and entering the background.
    /// The second argument is the conversation to write to, not ChatView's current one. Not called
    /// while typing.
    let onDraftCommit: (_ text: String, _ conversationID: UUID) -> Void

    @State private var composerText = ""
    @State private var draftSession = ChatComposerDraftSession()
    /// Selection probe of the input field: dictation inserts the transcript at the selection through it.
    @State private var dictationProbe = ComposerSelectionProbe()
    @Binding var pendingAttachments: [Attachment]
    @Binding var pendingQuoteContext: QuoteContext?
    @Binding var reasoningMode: ReasoningMode
    @Binding var reasoningIntentSelection: String?
    @Binding var webEnabled: Bool
    var composerFocused: Binding<Bool>

    let onSend: (_ text: String, _ attachments: [Attachment]) -> Void
    let onChooseModel: () -> Void
    /// The "Tools" chip (remote MCP). Nil hides the entry.
    var toolsChip: ComposerToolsChipState?
    /// Opens the tool panel.
    var onOpenTools: () -> Void = {}
    /// Input text went from empty to non-empty (context precompaction trigger).
    var onComposerTextStarted: () -> Void = {}
    let onCancel: () -> Void
    let onShowPhotoPicker: () -> Void
    let onShowCamera: () -> Void
    let onShowFileImporter: () -> Void
    /// Reopens the model options panel after a carrier change: ChatView bumps it when the handoff says the panel was open.
    var modelControlsReopenToken: UInt = 0
    /// Context usage of the active conversation; the ring shows only when it displays a percent.
    var contextUsage: ContextUsageSummary? = nil
    /// Tapping the usage ring opens the context panel.
    var onOpenContextUsage: () -> Void = {}
    /// Tapping ≋ on an empty draft: the host runs the gate, then starts the voice conversation.
    var onStartVoiceConversation: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState
    @Environment(\.windowNavigation) private var windowNavigation
    /// This window's navigation state (one per window); a host without one injected (tests) falls back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }
    @State private var highlightPulse = false
    @State private var highlightPulseToken = 0
    @State private var dismissedRelatedNoteIDs: Set<UUID> = []
    @State private var recalledNotes: [NoteRecallEngine.Suggestion] = []
    @State private var noteRecallWorker = NoteRecallWorker()
    @State private var showsModelControls = false
    /// The token registered with this window's carrier handoff (on disappear only this registration is removed).
    @State private var carrierHandoffToken: ChatCarrierHandoff.Token?
    @State private var opensModelPickerAfterControls = false
    @State private var opensConnectionSettingsAfterControls = false
    /// Same idea: after "Open web search settings" is tapped on a relay's web row, push the connection's web search settings page.
    @State private var opensConnectionWebSearchAfterControls = false
    /// Same idea: when the relay web template is rejected and "Test capabilities" is tapped, open that model's Advanced page once the
    /// sheet is dismissed (the verdict stays on that row with the test button beside it; no test is started automatically).
    @State private var opensTestCapabilitiesAfterControls = false
    @State private var webPreferenceSelection: CapabilityWebPreference = .off
    @State private var voiceTapGuard = VoiceEntryTapGuard()
    @Namespace private var voiceOrbNamespace

    private var visibleRelatedNotes: [NoteRecallEngine.Suggestion] {
        guard !isSendingMessage else { return [] }
        let pinned = Set(appState.pinnedNoteIDs(for: conversationID))
        return recalledNotes
            .filter { !pinned.contains($0.id) && !dismissedRelatedNoteIDs.contains($0.id) }
    }

    private var noteRecallTaskID: NoteRecallTaskID {
        NoteRecallTaskID(
            draftSample: NoteRecallEngine.recallSample(from: composerText),
            notesVersion: appState.notesVersion,
            isSendingMessage: isSendingMessage
        )
    }

    private var pinnedNoteSummaries: [NoteSummary] {
        appState.pinnedNoteIDs(for: conversationID).compactMap { id in
            appState.noteSummaries.first { $0.id == id }
        }
    }

    private var isDarkMode: Bool { colorScheme == .dark }
    private var controlsDisabled: Bool { isSendingMessage || isReadOnly }

    private var attachmentUploadBlocked: Bool {
        false
    }

    private var hasComposerContent: Bool {
        !composerText.isEmpty && composerText.contains(where: { !$0.isWhitespace })
            || !pendingAttachments.isEmpty
    }

    private var preferredAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.84)
    }

    private var supportsImageAttachment: Bool { attachmentEntries.image.isEnabled }

    /// The photo / image entry criterion (called directly by contract tests): the vision_input projection being editable means `visibleCapabilityKeys` contains the vision key,
    /// the same source as the facade entry `attachmentImportEntry.image`.
    static func supportsImageAttachment(
        provider: Provider,
        model: AIModel?,
        visibleCapabilityKeys: Set<String>
    ) -> Bool {
        visibleCapabilityKeys.contains(CapabilityEvidenceFacade.visionInputKey)
    }

    private var supportsVideoAttachment: Bool { attachmentEntries.video.isEnabled }

    private var supportsFileAttachment: Bool { attachmentEntries.file.isEnabled }

    private var hasModelControlSelection: Bool {
        capabilityDecision.hasActiveCapabilitySelection || hasModelBehaviorOverride
    }

    private var activeCapabilityGlyphs: [String] {
        capabilityDecision.activeCapabilityGlyphs
    }

    private func syncStoredCapabilitySelection() {
        guard let currentModel, let transportIdentity = modelControlTransportIdentity else {
            if reasoningIntentSelection != nil { reasoningIntentSelection = nil }
            if webPreferenceSelection != .off { webPreferenceSelection = .off }
            return
        }
        let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: currentModel)
        let stored = GenerationParameterSettingsStore.shared.displayCapabilityPreferences(
            providerID: provider.id,
            modelID: runtimeIdentity?.canonicalModelID ?? "",
            conversationID: generationParameterScopeID,
            skillID: nil,
            transportIdentity: transportIdentity
        )
        let live = CapabilityWebPreferenceLiveness.reachesTheWire(
            provider: provider, model: currentModel, conversationID: generationParameterScopeID,
            forwardPortsStaleCustom: true
        )
        let nextWeb = live ? stored.web : .off
        if reasoningIntentSelection != stored.reasoningIntent {
            reasoningIntentSelection = stored.reasoningIntent
        }
        if webPreferenceSelection != nextWeb { webPreferenceSelection = nextWeb }
    }

    private var hasModelBehaviorOverride: Bool {
        guard let currentModel, let generationProjection else { return false }
        return !GenerationParameterSettingsStore.shared.activeOverrideParameterIDs(
            providerID: provider.id,
            modelID: currentModel.id,
            conversationID: generationParameterScopeID,
            profileFingerprint: GenerationParameterProfileFingerprint.make(provider: provider, model: currentModel),
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: provider,
                model: currentModel,
                identity: generationProjection.hasCompleteConnectionIdentity
                    ? capabilityEvidenceIdentity
                    : nil
            )
        ).isEmpty
    }

    /// Complete final-transport + catalog-runtime identity used by typed preferences/custom fields.
    private var modelControlTransportIdentity: String? {
        currentModel.flatMap { CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: $0)?.wireValue }
    }

    /// The attachment button appears when any entry is visible (enabled, or disabled with a reason).
    private var supportsAttachmentEntry: Bool {
        attachmentEntries.image.isVisible || attachmentEntries.video.isVisible || attachmentEntries.file.isVisible
    }

    /// An entry is visible but disabled: the button must use the menu so the reason can be written on the menu item.
    private var hasDisabledAttachmentEntry: Bool {
        [attachmentEntries.image, attachmentEntries.video, attachmentEntries.file]
            .contains { $0.isVisible && !$0.isEnabled }
    }

    private var showsModeControls: Bool {
        // Add context is model-independent, so the capability strip is always available.
        true
    }

    private var pendingAttachmentCount: Int { pendingAttachments.count }

    private var attachmentButtonCount: Int {
        if supportsImageAttachment && !supportsFileAttachment {
            return pendingAttachments.filter { $0.kind == .image }.count
        }
        if supportsVideoAttachment && !supportsImageAttachment && !supportsFileAttachment {
            return pendingAttachments.filter { $0.kind == .video }.count
        }
        if supportsFileAttachment && !supportsImageAttachment {
            return pendingAttachments.filter { $0.kind == .file }.count
        }
        return pendingAttachmentCount
    }

    private var attachmentButtonSystemImage: String {
        let supportedKinds = [supportsImageAttachment, supportsVideoAttachment, supportsFileAttachment].filter { $0 }.count
        guard supportedKinds == 1, !hasDisabledAttachmentEntry else { return "plus" }

        if supportsImageAttachment { return "photo" }
        if supportsVideoAttachment { return "video" }
        return "paperclip"
    }

    private var hasDraftHighlight: Bool {
        ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: hasComposerContent,
            controlsDisabled: controlsDisabled,
            banner: modelRemovedBanner
        )
    }

    private var attachmentAccessibilityLabel: String {
        if supportsImageAttachment && supportsVideoAttachment && supportsFileAttachment {
            return "\(L10n.tr("Image")), \(L10n.tr("Video")), \(L10n.tr("File"))"
        }
        if supportsImageAttachment && supportsFileAttachment {
            return "\(L10n.tr("Image")), \(L10n.tr("File"))"
        }
        if supportsImageAttachment && supportsVideoAttachment {
            return "\(L10n.tr("Image")), \(L10n.tr("Video"))"
        }
        if supportsVideoAttachment && supportsFileAttachment {
            return "\(L10n.tr("Video")), \(L10n.tr("File"))"
        }
        if supportsImageAttachment { return L10n.tr("Image") }
        if supportsVideoAttachment { return L10n.tr("Video") }
        if supportsFileAttachment { return L10n.tr("File") }
        return L10n.tr("Add")
    }

    private var attachmentAccessibilityValue: String {
        pendingAttachmentCount == 0 ? "" : "\(pendingAttachmentCount)"
    }


    // MARK: - Body

    @ViewBuilder
    private var noteContextSection: some View {
        if !pinnedNoteSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Notes used in this chat", table: .notes))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pinnedNoteSummaries) { note in
                            HStack(spacing: 4) {
                                Image(systemName: "quote.opening").font(.system(size: 9))
                                Text(NoteText.displayTitle(note.title))
                                    .font(OriveoTheme.Typography.footnote)
                                    .lineLimit(1)
                                Button {
                                    appState.unpinNote(note.id, from: conversationID)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                                }
                                .accessibilityLabel(L10n.tr("Unpin", table: .notes))
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(OriveoTheme.Palette.primary)
                            .padding(.horizontal, OriveoTheme.Spacing.sm)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
                        }
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if !visibleRelatedNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Related notes", table: .notes))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                ForEach(visibleRelatedNotes) { note in
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NoteText.displayTitle(note.title))
                                .font(OriveoTheme.Typography.footnote)
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                .lineLimit(1)
                            if note.showsSourceBadge {
                                NoteSourceBadge(providerKind: note.sourceProviderKind,
                                                modelName: note.sourceModelName,
                                                providerName: note.sourceProviderName,
                                                size: 12)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(L10n.tr("Attach", table: .notes)) {
                            appState.pinNote(note.id, to: conversationID)
                            dismissedRelatedNoteIDs.insert(note.id)
                        }
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        Button(L10n.tr("Dismiss", table: .notes)) {
                            dismissedRelatedNoteIDs.insert(note.id)
                        }
                        .font(OriveoTheme.Typography.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                }
            }
            .padding(OriveoTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset).fill(OriveoTheme.Palette.surfaceInset))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var bodyEvaluationCount = 0
    static func resetBodyEvaluationCount() { bodyEvaluationCount = 0 }
    #endif

    var body: some View {
        #if DEBUG
        let _ = { Self.bodyEvaluationCount += 1 }()
        #endif
        let _ = CapabilityEvidenceObservationBridge.shared.contentRevision
        VStack(alignment: .leading, spacing: 10) {
            if let modelRemovedBanner {
                modelRemovedBannerView(modelRemovedBanner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let compactionHintConversationID {
                compactionHintBannerView(conversationID: compactionHintConversationID)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let compactingConversationID {
                compactionInProgressView(conversationID: compactingConversationID)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            noteContextSection

            if let dictationController = DictationHub.shared.controller {
                DictationPromptSlot(
                    controller: dictationController,
                    onCheckConnection: openDictationCheckConnection
                )
            }

            if let voiceSurface = voiceConversationController {
                // The voice conversation replaces the chip row and the input row; the mic and the field are hidden.
                VoiceConversationBar(surface: voiceSurface, orbNamespace: voiceOrbNamespace) {
                    VoiceConversationSession.shared.end(.user)
                }
                .transition(.opacity)
            } else if VoiceConversationDemo.status != nil {
                VoiceConversationDemo.bar
            } else {
                if showsModeControls {
                    capabilityStrip
                        .padding(.bottom, -4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !pendingAttachments.isEmpty {
                    attachmentPreviewRow
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                composerInputRow
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, 12)
        .padding(.bottom, OriveoTheme.Spacing.sm + 2)
        .background {
            if !transparentChrome {
                LinearGradient(
                    stops: [
                        .init(color: OriveoTheme.Palette.background.opacity(0), location: 0),
                        .init(color: OriveoTheme.Palette.background, location: 0.42),
                        .init(color: OriveoTheme.Palette.background, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
            }
        }
        .animation(preferredAnimation, value: showsModeControls)
        .animation(
            VoiceConversationBar.transitionAnimation(reduceMotion: reduceMotion),
            value: voiceConversationController != nil
        )
        .animation(preferredAnimation, value: compactionHintConversationID)
        .animation(preferredAnimation, value: compactingConversationID)
        .animation(preferredAnimation, value: pendingAttachments.isEmpty)
        .animation(preferredAnimation, value: pendingQuoteContext)
        .animation(preferredAnimation, value: reasoningMode)
        .animation(preferredAnimation, value: webEnabled)
        .sensoryFeedback(.selection, trigger: reasoningMode)
        .sensoryFeedback(.selection, trigger: webEnabled)
        .onAppear {
            // When a pushed page covered the chat and navigation comes back, @State is still here:
            // the same conversation does not reload, so unsent input stays.
            if !draftSession.isBound || draftSession.conversationID != conversationID {
                commitDraft()
                composerText = draftSession.bind(conversationID: conversationID, storeDraft: storeDraft)
            }
            configureHighlightPulse()
            syncStoredCapabilitySelection()
            registerCarrierHandoff()
            VoiceConversationSession.shared.hostAppeared(conversationID)
        }
        .onDisappear {
            VoiceConversationSession.shared.hostDisappeared(conversationID)
            commitDraft()
            if let carrierHandoffToken {
                navigation.chatHandoff.unregister(carrierHandoffToken)
                self.carrierHandoffToken = nil
            }
        }
        .onChange(of: modelControlsReopenToken) { _, _ in
            showsModelControls = true
        }
        // Going to the background while focused neither loses focus nor disappears, and the draft
        // would be lost if the system then terminates the app. Write once against the stored snapshot
        // (nothing is written when unchanged).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            commitDraft()
        }
        .onChange(of: composerText.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty { onComposerTextStarted() }
        }
        .onChange(of: reduceMotion) { _, _ in configureHighlightPulse() }
        .onChange(of: currentModel?.id) { _, _ in syncStoredCapabilitySelection() }
        .onChange(of: conversationID) { old, new in
            syncStoredCapabilitySelection()
            VoiceConversationSession.shared.hostSwitched(from: old, to: new)
        }
        .onChange(of: isSendingMessage) { wasSending, isSending in
            if wasSending, !isSending { voiceTapGuard.generationEnded(atMs: VoiceEntryTapGuard.nowMs()) }
        }
        // ✕ hands the half-spoken transcript back as the draft.
        .onChange(of: VoiceConversationSession.shared.lastEnd) { _, end in
            guard let end, let draft = VoiceConversationSession.shared.consumeEndDraft(end, host: conversationID)
            else { return }
            composerText = composerText.isEmpty ? draft : composerText + " " + draft
        }
        // A conversation switch, an external push, focus loss and a store echo can land in the same
        // update; separate onChange handlers run in no guaranteed order.
        .onChange(of: draftInputs) { old, new in
            applyDraftInputs(old: old, new: new)
        }
        .onChange(of: showsModelControls) { _, isOpen in
            guard !isOpen else { return }
            syncStoredCapabilitySelection()
        }
        #if DEBUG
        // Short-screen acceptance on the cover display (`-AUTO_FOCUS_COMPOSER`): focus the composer to bring up the keyboard so the layout probe can measure the reading area.
        .onReceive(NotificationCenter.default.publisher(for: .oriveoDebugFocusComposer)) { _ in
            composerFocused.wrappedValue = true
        }
        // Screenshot-only: open the model options panel once the input bar of a relay family sample page is mounted
        // (wait for the push animation to finish before presenting the sheet).
        .onAppear {
            guard RelayFamilyDebugShots.takeModelOptions(providerID: provider.id, modelID: currentModel?.id) else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                showsModelControls = true
            }
        }
        #endif
        .onChange(of: reasoningMode) { _, _ in triggerHighlightPulse() }
        .onChange(of: webEnabled) { _, _ in triggerHighlightPulse() }
        .onChange(of: pendingAttachmentCount) { old, new in
            guard old != new else { return }
            triggerHighlightPulse()
        }
        .onChange(of: hasComposerContent) { old, new in
            guard old != new else { return }
            new ? triggerHighlightPulse() : configureHighlightPulse()
        }
        .task(id: noteRecallTaskID) {
            await refreshRelatedNotes()
        }
        .modifier(ChatComposerDictationHost(
            controller: DictationHub.shared.controller,
            slotKey: Self.dictationSlotKey(conversationID: conversationID),
            canSend: { dictationCanSend },
            onInsert: { transcript in
                let updated = dictationProbe.insert(transcript: transcript, currentText: composerText)
                composerText = updated
                return updated
            },
            onSend: { text in submitComposer(text: text) }
        ))
    }

    // MARK: - Dictation

    /// This bar's recording slot: a conversation uses its own slot, and the compose state uses the home draft slot.
    static func dictationSlotKey(conversationID: UUID?) -> String {
        guard let conversationID else { return RecordingStore.homeDraftKey }
        return RecordingStore.slotKey(conversationID: conversationID)
    }

    /// Where Check Connection on the dictation card goes: with a connection id it opens that connection's details, otherwise provider setup.
    enum DictationCheckConnectionRoute: Equatable {
        case providerDetail(UUID)
        case providerSetup
    }

    static func dictationCheckConnectionRoute(providerID: UUID?) -> DictationCheckConnectionRoute {
        guard let providerID else { return .providerSetup }
        return .providerDetail(providerID)
    }

    private func openDictationCheckConnection(_ providerID: UUID?) {
        switch Self.dictationCheckConnectionRoute(providerID: providerID) {
        case .providerDetail(let id):
            navigation.openProviderDetail(providerID: id)
        case .providerSetup:
            appState.openProviderSetup(from: .providers)
        }
    }

    /// Shared by the send button and dictation's "transcribe and send": carries the pending attachments.
    private func submitComposer(text: String) {
        onSend(text, pendingAttachments)
    }

    /// The same source as the send button; the transcript is inserted before sending, so this is judged as "has content".
    private var dictationCanSend: Bool {
        ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true,
            controlsDisabled: controlsDisabled,
            banner: modelRemovedBanner
        )
    }

    private struct DraftInputs: Equatable {
        let conversationID: UUID?
        let storeDraft: String?
        let pushToken: UInt
        let isFocused: Bool
    }

    private var draftInputs: DraftInputs {
        DraftInputs(
            conversationID: conversationID,
            storeDraft: storeDraft,
            pushToken: textPush.token,
            isFocused: composerFocused.wrappedValue
        )
    }

    /// Fixed order: write the previous conversation's draft back and rebind → apply an external push
    /// (it wins over the rebound initial text) → persist on focus loss → reconcile the store echo.
    private func applyDraftInputs(old: DraftInputs, new: DraftInputs) {
        if !draftSession.isBound || draftSession.conversationID != new.conversationID {
            commitDraft()
            composerText = draftSession.bind(conversationID: new.conversationID, storeDraft: new.storeDraft)
        }
        if new.pushToken != old.pushToken {
            composerText = textPush.text
        }
        if old.isFocused, !new.isFocused {
            commitDraft()
        }
        if new.storeDraft != old.storeDraft,
           let draft = draftSession.reconcile(
               storeDraft: new.storeDraft,
               latestDraft: draftSession.conversationID.flatMap { appState.conversation(for: $0)?.draftText },
               composerText: composerText,
               isFocused: new.isFocused
           ) {
            composerText = draft
        }
    }

    /// Called synchronously by `NavigationManager` before the move: reads the current input text, focus and panel.
    private func registerCarrierHandoff() {
        guard carrierHandoffToken == nil else { return }
        carrierHandoffToken = navigation.chatHandoff.registerComposer {
            ChatComposerCarrierState(
                text: composerText,
                isFocused: composerFocused.wrappedValue,
                showsModelControls: showsModelControls
            )
        }
    }

    private func commitDraft() {
        guard let write = draftSession.commit(composerText) else { return }
        onDraftCommit(write.text, write.conversationID)
    }

    private func refreshRelatedNotes() async {
        let draftSample = NoteRecallEngine.recallSample(from: composerText)
        guard !isSendingMessage,
              draftSample.contains(where: { !$0.isWhitespace }) else {
            recalledNotes = []
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return
        }

        let terms: [String]
        do {
            terms = try await noteRecallWorker.terms(for: draftSample)
        } catch {
            return
        }
        guard !terms.isEmpty, !Task.isCancelled else {
            recalledNotes = []
            return
        }

        let noteSnapshot = await appState.noteManager.recallCandidates(terms: terms)
        guard !Task.isCancelled else { return }
        let matches: [NoteRecallEngine.Suggestion]
        do {
            matches = try await noteRecallWorker.findRelatedNotes(
                terms: terms,
                candidates: noteSnapshot
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }

        guard !Task.isCancelled,
              NoteRecallEngine.recallSample(from: composerText) == draftSample else { return }
        recalledNotes = matches
    }

    // MARK: - Capability Strip

    private var capabilityStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                capabilityStripContent
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .mask(horizontalEdgeFadeMask)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pinned at the trailing end, outside the scrolling chips.
            if let contextUsage, ContextUsageRing.isVisible(contextUsage) {
                ContextUsageRing(summary: contextUsage, onTap: onOpenContextUsage)
            }
        }
    }

    private var capabilityStripContent: some View {
        HStack(spacing: 7) {
            Button { showsModelControls = true } label: {
                composerControlChip(
                    title: L10n.tr("Model Options"),
                    systemImage: "slider.horizontal.3",
                    accent: modelBehaviorAccent,
                    emphasized: hasModelControlSelection,
                    disabled: false,
                    accessory: .chevron,
                    capabilityGlyphs: activeCapabilityGlyphs
                )
            }
            .buttonStyle(ComposerInteractiveButtonStyle())
            .accessibilityLabel(Text(L10n.tr("Model Options")))
            .accessibilityValue(Text(modelControlSummary))
            .sheet(isPresented: $showsModelControls, onDismiss: {
                if opensConnectionSettingsAfterControls {
                    opensConnectionSettingsAfterControls = false
                    navigation.openProviderDetail(providerID: provider.id)
                    return
                }
                if opensConnectionWebSearchAfterControls {
                    opensConnectionWebSearchAfterControls = false
                    appState.openRelayWebSearch(providerID: provider.id)
                    return
                }
                if opensTestCapabilitiesAfterControls {
                    opensTestCapabilitiesAfterControls = false
                    if let testedModel = currentModel {
                        appState.openRelayModelAdvanced(providerID: provider.id, modelID: testedModel.id, readOnly: false)
                    }
                    return
                }
                guard opensModelPickerAfterControls else { return }
                opensModelPickerAfterControls = false
                onChooseModel()
            }) {
                ModelControlsEntrySheet(
                    provider: provider,
                    model: currentModel,
                    conversationID: generationParameterScopeID,
                    isExistingConversation: conversationID != nil,
                    transportIdentity: modelControlTransportIdentity,
                    runtimeIsReadOnly: controlsDisabled,
                    runtimeReadOnlyReason: isSendingMessage
                        ? L10n.tr("Thinking…", table: .chat)
                        : L10n.tr("Loading conversation…", table: .chat),
                    webEnabled: $webEnabled,
                    reasoningMode: $reasoningMode,
                    reasoningIntentSelection: $reasoningIntentSelection,
                    onChooseConnection: {
                        opensModelPickerAfterControls = true
                        showsModelControls = false
                    },
                    onOpenConnectionSettings: {
                        opensConnectionSettingsAfterControls = true
                        showsModelControls = false
                    },
                    onOpenConnectionWebSearch: {
                        opensConnectionWebSearchAfterControls = true
                        showsModelControls = false
                    },
                    onOpenTestCapabilities: {
                        opensTestCapabilitiesAfterControls = true
                        showsModelControls = false
                    }
                )
                .presentationDragIndicator(.visible)
            }

            // The "Tools" chip. Its number is the count of servers turned on and usable in this
            // conversation; at 0 there is no number and no highlight. When the current connection cannot
            // carry tools the chip is dimmed but still tappable: the panel it opens explains why. It can be
            // opened while an answer is generating too (changes apply to the next send).
            if let toolsChip {
                Button {
                    onOpenTools()
                } label: {
                    composerControlChip(
                        title: L10n.tr("Tools", table: .mcp),
                        systemImage: "wrench.adjustable",
                        accent: modelBehaviorAccent,
                        emphasized: toolsChip.enabledServerCount > 0,
                        disabled: isReadOnly || !toolsChip.isAvailable,
                        badgeText: toolsChip.enabledServerCount > 0 ? String(toolsChip.enabledServerCount) : nil
                    )
                }
                .buttonStyle(ComposerInteractiveButtonStyle())
                .disabled(isReadOnly)
                .accessibilityLabel(Text(L10n.tr("Tools", table: .mcp)))
                .accessibilityValue(Text(toolsChip.accessibilityValue))
            }
        }
    }

    private var modelControlSummary: String {
        let web = ModelControlIntentLabel.webText(
            capabilityDecision.webSearchEnabled ? webPreferenceSelection : .off
        )
        let thinking = capabilityDecision.reasoningIntent.map(ModelControlIntentLabel.text)
            ?? L10n.tr("Automatic")
        return "\(L10n.tr("Web Search", table: .chat)): \(web) · \(L10n.tr("Thinking Mode", table: .chat)): \(thinking)"
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewRow: some View {
        let canUseKnowledge = provider.kind == .openAI && !ProviderCredentialResolver.apiKey(provider: provider, modelID: nil).isEmpty
        let hasTruncatedChip = canUseKnowledge && pendingAttachments.contains { $0.extractedTruncated == true }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                ForEach(pendingAttachments) { attachment in
                    ChatAttachmentPicker.attachmentThumbnail(
                        attachment,
                        onRemove: { id in
                            pendingAttachments.removeAll { $0.id == id }
                        },
                        onTapKnowledgeCTA: (canUseKnowledge && attachment.extractedTruncated == true)
                            ? { navigation.openSkillEdit() }
                            : nil
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: hasTruncatedChip ? 112 : 78)
        .background {
            let trayShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            trayShape
                .fill(
                    Color.dynamic(
                        light: 0xF8FAFC,
                        dark: 0x111A2C,
                        lightAlpha: 0.66,
                        darkAlpha: 0.58
                    )
                )
                .overlay {
                    trayShape.fill(attachmentAccent.softFill.opacity(isDarkMode ? 0.05 : 0.08))
                }
                .shadow(color: OriveoTheme.Palette.shadow.opacity(isDarkMode ? 0.12 : 0.035), radius: 7, y: 3)
        }
        .mask(horizontalEdgeFadeMask)
    }

    // MARK: - Composer Input Row

    @ViewBuilder
    private var composerInputRow: some View {
        if let controller = DictationHub.shared.controller {
            DictationInputSwitcher(controller: controller, canSend: dictationCanSend) {
                composerIdleInputRow
            }
        } else {
            composerIdleInputRow
        }
    }

    private var composerIdleInputRow: some View {
        HStack(alignment: .bottom, spacing: 7) {
            VStack(spacing: 6) {
                pendingQuoteChip
                composerTextInputShell
            }
            composerActionCluster
                .padding(.bottom, 7)
        }
    }

    @ViewBuilder
    private var pendingQuoteChip: some View {
        if let pendingQuoteContext {
            QuoteContextChip(
                quote: pendingQuoteContext,
                allowsRemoval: true,
                presentation: .composer,
                onRemove: {
                    self.pendingQuoteContext = nil
                }
            )
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                removal: .opacity
            ))
        }
    }

    // MARK: - Text Input Shell

    private var composerTextInputShell: some View {
        let shellShape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let focused = composerFocused.wrappedValue

        return HStack(alignment: .center, spacing: 8) {
            if supportsAttachmentEntry {
                attachmentEntryButton
            }

            // Not a SwiftUI TextField: it re-lays out a long single paragraph on every layout pass, see ComposerTextView.
            ComposerTextView(
                text: $composerText,
                isFocused: composerFocused,
                placeholder: isSendingMessage
                    ? L10n.tr("AI is answering...", table: .chat)
                    : L10n.tr("Type a message...", table: .chat),
                font: Self.inputFont,
                textColor: controlsDisabled ? Self.inputDisabledColor : Self.inputTextColor,
                isEnabled: !controlsDisabled,
                maxLength: ChatInputLimit.maxUTF16,
                onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast,
                selectionProbe: dictationProbe,
                // Return on a hardware keyboard sends: the same condition and the same submitComposer as the send button
                onHardwareReturnSend: { submitComposer(text: composerText) },
                canSendOnHardwareReturn: !isSendingMessage && hasDraftHighlight
            )
            .padding(.vertical, 8)
            .frame(minHeight: 44, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let controller = DictationHub.shared.controller {
                DictationMicButton(controller: controller)
                    .disabled(controlsDisabled)
            }
        }
        .padding(.leading, supportsAttachmentEntry ? 6 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background {
            composerSurface(
                shellShape,
                fill: composerShellFill,
                border: composerShellBorder
            )
        }
        .overlay {
            if focused {
                aiFocusBorder(shellShape)
            }
        }
        .shadow(
            color: focused
                ? OriveoTheme.Palette.primaryGlow.opacity(0.1)
                : OriveoTheme.Palette.shadow.opacity(0.02),
            radius: focused ? 10 : 5,
            y: focused ? 5 : 2
        )
        .animation(.easeInOut(duration: 0.2), value: focused)
        .animation(.easeInOut(duration: 0.18), value: hasComposerContent)
    }

    // Same values as the old TextField's `.font(Typography.body)` / `.foregroundStyle(textPrimary | textTertiary)`.
    // Cached as single instances: ComposerTextView compares styles by equality, and a dynamic color created anew each
    // time would look changed and rewrite the attributes of the whole text.
    private static let inputFont = UIFont.systemFont(ofSize: 16)
    private static let inputTextColor = UIColor(OriveoTheme.Palette.textPrimary)
    private static let inputDisabledColor = UIColor(OriveoTheme.Palette.textTertiary)

    private var composerShellFill: Color {
        if composerFocused.wrappedValue {
            return Color.dynamic(light: 0xFFFFFF, dark: 0x101113, lightAlpha: 0.26, darkAlpha: 0.46)
        }
        if hasDraftHighlight {
            return Color.dynamic(light: 0xFBF9FF, dark: 0x0B0C0E, lightAlpha: 0.19, darkAlpha: 0.42)
        }
        return Color.dynamic(light: 0xFFFFFF, dark: 0x07080A, lightAlpha: 0.11, darkAlpha: 0.38)
    }

    private var composerShellBorder: Color {
        if composerFocused.wrappedValue { return .clear }
        if hasDraftHighlight { return OriveoTheme.Palette.primary.opacity(0.25) }
        return OriveoTheme.Palette.primary.opacity(0.16)
    }


    private var aiBorderColors: [Color] {
        [
            Color(hex: 0x6E8BFF),
            Color(hex: 0x9B6BFF),
            Color(hex: 0xE06BC4),
            Color(hex: 0xFFB36B),
            Color(hex: 0x66E0B8),
            Color(hex: 0x6E8BFF)
        ]
    }

    private func aiFocusBorder(_ shape: RoundedRectangle) -> some View {
        let gradient = AngularGradient(
            gradient: Gradient(colors: aiBorderColors),
            center: .center,
            angle: .degrees(24)
        )
        return ZStack {
            shape.stroke(gradient, lineWidth: 3)
                .blur(radius: 6)
                .opacity(0.55)
            shape.strokeBorder(gradient, lineWidth: 1.8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Attachment Entry Button

    @ViewBuilder
    private var attachmentEntryButton: some View {
        let attachmentDisabled = controlsDisabled || attachmentUploadBlocked
        let label = attachmentComposerButton(
            systemImage: attachmentButtonSystemImage,
            emphasized: attachmentButtonCount > 0,
            disabled: attachmentDisabled,
            count: attachmentButtonCount
        )

        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        let imageOptionCount = supportsImageAttachment ? (cameraAvailable ? 2 : 1) : 0
        let nonImageOptionCount = (supportsVideoAttachment ? 1 : 0) + (supportsFileAttachment ? 1 : 0)
        let totalOptionCount = imageOptionCount + nonImageOptionCount

        if totalOptionCount >= 2 || hasDisabledAttachmentEntry {
            Menu {
                if supportsImageAttachment {
                    if cameraAvailable {
                        Button { onShowCamera() } label: {
                            Label(L10n.tr("Take Photo"), systemImage: "camera")
                        }
                    }
                    Button { onShowPhotoPicker() } label: {
                        Label(L10n.tr("Choose from Library"), systemImage: "photo.on.rectangle")
                    }
                } else if let reason = attachmentEntries.image.disabledReason {
                    disabledAttachmentMenuItem(
                        title: L10n.tr("Choose from Library"), systemImage: "photo.on.rectangle", reason: reason
                    )
                }
                if supportsVideoAttachment {
                    Button { onShowFileImporter() } label: {
                        Label(L10n.tr("Video"), systemImage: "video")
                    }
                } else if let reason = attachmentEntries.video.disabledReason {
                    disabledAttachmentMenuItem(title: L10n.tr("Video"), systemImage: "video", reason: reason)
                }
                if supportsFileAttachment {
                    Button { onShowFileImporter() } label: {
                        Label(L10n.tr("File"), systemImage: "paperclip")
                    }
                } else if let reason = attachmentEntries.file.disabledReason {
                    disabledAttachmentMenuItem(title: L10n.tr("File"), systemImage: "paperclip", reason: reason)
                }
            } label: { label }
                .menuIndicator(.hidden)
                .buttonStyle(ComposerInteractiveButtonStyle())
                .disabled(attachmentDisabled)
                .accessibilityLabel(Text(attachmentAccessibilityLabel))
                .accessibilityValue(Text(attachmentAccessibilityValue))
        } else if supportsImageAttachment {
            Button { onShowPhotoPicker() } label: { label }
                .buttonStyle(ComposerInteractiveButtonStyle())
                .disabled(attachmentDisabled)
                .accessibilityLabel(Text(attachmentAccessibilityLabel))
                .accessibilityValue(Text(attachmentAccessibilityValue))
        } else if supportsVideoAttachment {
            Button { onShowFileImporter() } label: { label }
                .buttonStyle(ComposerInteractiveButtonStyle())
                .disabled(attachmentDisabled)
                .accessibilityLabel(Text(attachmentAccessibilityLabel))
                .accessibilityValue(Text(attachmentAccessibilityValue))
        } else if supportsFileAttachment {
            Button { onShowFileImporter() } label: { label }
                .buttonStyle(ComposerInteractiveButtonStyle())
                .disabled(attachmentDisabled)
                .accessibilityLabel(Text(attachmentAccessibilityLabel))
                .accessibilityValue(Text(attachmentAccessibilityValue))
        }
    }

    /// A visible but disabled menu item: the disabled reason (InputCapabilityCopy) is written on the line below the title.
    private func disabledAttachmentMenuItem(title: String, systemImage: String, reason: String) -> some View {
        Button {} label: {
            Label {
                Text(title)
                Text(reason)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .disabled(true)
        .accessibilityHint(Text(reason))
    }

    /// Hint shown on the third compaction while ChatManager flags this conversation.
    private var compactionHintConversationID: UUID? {
        guard let conversationID, appState.pendingCompactionHint == conversationID else { return nil }
        return conversationID
    }

    private func compactionHintBannerView(conversationID: UUID) -> some View {
        let tint = OriveoTheme.Palette.primary
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(L10n.tr("context_compaction_third_hint", table: .chat))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                Button {
                    appState.chatManager.dismissCompactionHint()
                } label: {
                    Text(L10n.tr("context_compaction_third_hint_dismiss", table: .chat))
                }
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .buttonStyle(.plain)
                Button {
                    ContextCompactionActions(appState: appState, conversationID: conversationID)
                        .startNewChatWithSummary()
                } label: {
                    Text(L10n.tr("context_compaction_third_hint_new_chat", table: .chat))
                }
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(isDarkMode ? 0.14 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(isDarkMode ? 0.28 : 0.20), lineWidth: 1)
                )
        }
    }

    /// Shown only while an AI summary call is running for this conversation.
    private var compactingConversationID: UUID? {
        guard let conversationID, appState.aiCompactingConversationIDs.contains(conversationID) else { return nil }
        return conversationID
    }

    private func compactionInProgressView(conversationID: UUID) -> some View {
        let tint = OriveoTheme.Palette.primary
        return HStack(alignment: .center, spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .accessibilityHidden(true)
            Text(L10n.tr("context_compaction_in_progress", table: .chat))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                appState.chatManager.cancelCompaction(conversationId: conversationID)
            } label: {
                Text(L10n.tr("context_compaction_cancel", table: .chat))
            }
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(isDarkMode ? 0.14 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(isDarkMode ? 0.28 : 0.20), lineWidth: 1)
                )
        }
    }

    /// The row shown when the conversation's model was removed: the same compact style as the other banners, with one button on the right that opens the model picker.
    private func modelRemovedBannerView(_ banner: ChatModelRemovedBanner) -> some View {
        let tint = OriveoTheme.Palette.warning
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(banner.message)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let successorModelID = banner.successorModelID {
                // An official model was retired and its successor is enabled: one tap switches to the successor, through the same selection path as the model picker.
                Button(banner.actionTitle) {
                    appState.selectModel(modelID: successorModelID, providerID: banner.providerID, for: conversationID)
                }
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .buttonStyle(.plain)
            } else {
                Button(banner.actionTitle, action: onChooseModel)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(isDarkMode ? 0.14 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(isDarkMode ? 0.28 : 0.20), lineWidth: 1)
                )
        }
    }

    // MARK: - Attachment Composer Button

    private func attachmentComposerButton(
        systemImage: String,
        emphasized: Bool,
        disabled: Bool,
        count: Int
    ) -> some View {
        let accent = attachmentAccent

        return ZStack(alignment: .topTrailing) {
            Image(systemName: systemImage)
                .font(.system(size: systemImage == "plus" ? 17 : 16, weight: .semibold))
                .foregroundStyle(emphasized ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textPrimary)
                .symbolEffect(.bounce, value: count)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(
                        Color.brand(defaultLight: OriveoLightBrand.defaultBrand.ink, light: \.ink, lightAlpha: 0.12, darkFixed: 0xFFFFFF, darkAlpha: 0.10)
                    )
                )
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [accent.iconStart, accent.iconEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .offset(x: 4, y: -1.5)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .opacity(disabled ? 0.52 : 1)
    }

    // MARK: - Control Chip

    private func composerControlChip(
        title: String,
        systemImage: String,
        accent: ComposerCapabilityAccent,
        emphasized: Bool,
        disabled: Bool,
        badgeText: String? = nil,
        accessory: ComposerControlChipAccessory = .none,
        capabilityGlyphs: [String] = []
    ) -> some View {
        let chipShape = Capsule(style: .continuous)

        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(emphasized ? accent.tint : OriveoTheme.Palette.textTertiary)
                .symbolEffect(.bounce, value: emphasized)
                .frame(width: 17)

            Text(title)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(emphasized ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.textTertiary)
                .lineLimit(1)

            if emphasized && badgeText == nil {
                if capabilityGlyphs.isEmpty {
                    composerEmphasisOrb(accent: accent)
                } else {
                    HStack(spacing: 3.5) {
                        ForEach(capabilityGlyphs, id: \.self) { glyph in
                            Image(systemName: glyph)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(accent.tint)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }

            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 10.25, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(emphasized ? accent.tint : OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            accessoryView(for: accessory, accent: accent)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .frame(minHeight: 34)
        .frame(minWidth: 44)
        .contentShape(chipShape)
        .background {
            chipShape
                .fill(
                    emphasized
                        ? accent.softFill.opacity(isDarkMode ? 0.68 : 0.80)
                        : Color.dynamic(light: 0xF9FAFD, dark: 0x121A2A, lightAlpha: 0.58, darkAlpha: 0.58)
                )
        }
        .contentShape(.hoverEffect, chipShape)
        .hoverEffect(.highlight)
        .shadow(
            color: emphasized ? accent.shadow.opacity(0.08) : .clear,
            radius: emphasized ? 7 : 0,
            y: emphasized ? 2 : 0
        )
        .opacity(disabled ? 0.52 : 1)
    }

    // MARK: - Action Cluster

    private var composerActionCluster: some View {
        let isPrimed = ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: hasComposerContent,
            controlsDisabled: controlsDisabled,
            banner: modelRemovedBanner
        )

        let action = VoiceConversationEntry.primaryAction(
            isSending: isSendingMessage,
            hasContent: hasComposerContent,
            sendEnabled: isPrimed,
            voiceAvailable: voiceConversationAvailable,
            modelProducesText: VoiceConversationEntry.modelProducesText(currentModel)
        )

        return Group {
            if action != .voice && isSendingMessage {
                OriveoCircleIconButton(
                    systemImage: "stop.fill",
                    fill: AnyShapeStyle(OriveoTheme.Palette.danger),
                    size: 40,
                    iconSize: 15,
                    bounceValue: isSendingMessage
                ) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCancel()
                }
                .accessibilityLabel(L10n.tr("Stop Generating"))
            } else {
                // ≋ and ↑ are the same solid purple primary key: empty draft ≋, text ↑, and the switch only morphs the icon while the key itself stays put.
                let isVoice = action == .voice
                let isLit = isVoice || isPrimed
                OriveoCircleIconButton(
                    systemImage: isVoice ? "waveform" : "arrow.up",
                    // Unavailable (empty draft and no ≋): the same flat lavender circle as the attachment / top buttons (no white fill or grey edge);
                    // available: lit up as a purple gradient CTA, keeping the primary / secondary hierarchy.
                    fill: isLit
                        ? AnyShapeStyle(OriveoTheme.Palette.primaryGradient)
                        : AnyShapeStyle(Color.brand(defaultLight: OriveoLightBrand.defaultBrand.ink, light: \.ink, lightAlpha: 0.12, darkFixed: 0xFFFFFF, darkAlpha: 0.10)),
                    foreground: isLit ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.textTertiary,
                    border: isLit ? OriveoTheme.Palette.hairline : .clear,
                    shadowColor: isLit ? OriveoTheme.Palette.primaryGlow : .clear,
                    size: 40,
                    iconSize: 16,
                    bounceValue: isPrimed
                ) {
                    if isVoice {
                        guard voiceTapGuard.acceptsTap(atMs: VoiceEntryTapGuard.nowMs()) else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onStartVoiceConversation()
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        submitComposer(text: composerText)
                    }
                }
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .voiceOrbMatched(voiceOrbNamespace, reduceMotion: reduceMotion)
                .scaleEffect(isLit ? 1 : 0.96)
                .disabled(!isLit)
                // ≋ and ↑ are both icon-only: each gets a screen reader name (↑ shares "Send" with the home page key)
                .accessibilityLabel(isVoice ? Text(VoiceConversationCopy.startA11y) : Text(L10n.tr("memory_extraction_send", table: .chat)))
            }
        }
        .animation(preferredAnimation, value: isSendingMessage)
        .animation(.easeInOut(duration: 0.18), value: hasComposerContent)
    }

    // MARK: - Voice Conversation

    /// The voice bar shows here when this page hosts the running conversation.
    private var voiceConversationController: (any VoiceConversationSurface)? {
        let session = VoiceConversationSession.shared
        guard session.isPresented(in: conversationID) else { return nil }
        return session.surface
    }

    /// ≋ needs an editable page, a usable model and the dictation pipeline.
    private var voiceConversationAvailable: Bool {
        !controlsDisabled && modelRemovedBanner == nil && DictationHub.shared.controller != nil
    }

    // MARK: - Shared Surface Helper

    @ViewBuilder
    private func composerSurface<S: Shape>(
        _ shape: S,
        fill: Color = OriveoTheme.Palette.surfaceChrome,
        border: Color = OriveoTheme.Palette.border,
        accentTint: Color? = nil
    ) -> some View {
        shape.fill(fill)
            .overlay {
                if let tint = accentTint {
                    shape.fill(tint.opacity(isDarkMode ? 0.08 : 0.12))
                    shape.fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.cardHighlight,
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.3)
                        )
                    )
                }
            }
            .overlay(shape.stroke(border, lineWidth: 1))
    }

    // MARK: - Small Helpers

    private var horizontalEdgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private func accessoryView(
        for accessory: ComposerControlChipAccessory,
        accent: ComposerCapabilityAccent
    ) -> some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        case .selectedMark:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent.iconEnd)
        }
    }

    private func composerEmphasisOrb(accent: ComposerCapabilityAccent) -> some View {
        ZStack {
            Circle().fill(accent.softFill)
            Circle()
                .fill(accent.iconEnd)
                .frame(width: 5.5, height: 5.5)
                .shadow(color: accent.shadow.opacity(0.22), radius: 4, y: 2)
        }
        .frame(width: 12, height: 12)
        .scaleEffect(reduceMotion ? 1 : (highlightPulse ? 1.04 : 0.94))
        .opacity(reduceMotion ? 1 : (highlightPulse ? 1 : 0.82))
    }

    // MARK: - Highlight Pulse

    private func configureHighlightPulse() {
        highlightPulseToken += 1
        highlightPulse = false
    }

    private func triggerHighlightPulse() {
        guard !reduceMotion else { return }
        highlightPulseToken += 1
        let token = highlightPulseToken
        withAnimation(.easeOut(duration: 0.18)) { highlightPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard token == highlightPulseToken else { return }
            withAnimation(.easeInOut(duration: 0.36)) { highlightPulse = false }
        }
    }

    // MARK: - Accent Colors

    private var attachmentAccent: ComposerCapabilityAccent {
        .init(
            tint: Color.dynamic(light: 0x52607A, dark: 0xCBD5E1),
            iconStart: Color.dynamic(light: 0xA5B4FC, dark: \.accent),
            iconEnd: Color.dynamic(light: 0x6366F1, dark: \.primary),
            softFill: Color.dynamic(light: 0xF8FAFC, dark: 0x172136, lightAlpha: 1, darkAlpha: 0.94),
            softBorder: Color.dynamic(light: 0xD5DBE7, dark: 0x94A3B8, lightAlpha: 1, darkAlpha: 0.26),
            shadow: OriveoTheme.Palette.shadow
        )
    }

    private var modelBehaviorAccent: ComposerCapabilityAccent {
        .init(
            // Brand colors: the default palette keeps its hand-tuned light values, other palettes follow the palette; the dark soft fill takes 15% of the primary instead of a fixed violet-black
            tint: Color.brand(defaultLight: 0x5B4AB8, light: \.textSafe, dark: \.accent),
            iconStart: Color.brand(defaultLight: 0xA78BFA, light: \.accent, dark: \.accent),
            iconEnd: Color.brand(defaultLight: 0x6D5BD0, light: \.ink, dark: \.primary),
            softFill: Color.brand(defaultLight: 0xF5F3FF, light: \.soft, dark: \.primary, darkAlpha: 0.15),
            softBorder: Color.brand(defaultLight: 0xC4B5FD, light: \.ink, lightAlpha: 0.7, dark: \.primary, darkAlpha: 0.3),
            shadow: Color.brand(defaultLight: 0x6D5BD0, light: \.ink, lightAlpha: 0.15, darkFixed: 0x000000, darkAlpha: 0.22)
        )
    }

    private func accent(for capability: ModelCapability) -> ComposerCapabilityAccent {
        switch capability {
        case .reasoning:
            return .init(
                tint: Color.dynamic(light: 0xC66312, dark: 0xF6C24B),
                iconStart: Color.dynamic(light: 0xF0A11F, dark: 0xF6C24B),
                iconEnd: Color.dynamic(light: 0xC66312, dark: 0xD97706),
                softFill: Color.dynamic(light: 0xFFF3DE, dark: 0x3A2610, lightAlpha: 1, darkAlpha: 0.92),
                softBorder: Color.dynamic(light: 0xE4B05D, dark: 0xF6C24B, lightAlpha: 0.65, darkAlpha: 0.34),
                shadow: Color.dynamic(light: 0xC66312, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0.22)
            )
        case .web:
            return .init(
                tint: Color.dynamic(light: 0x0F766E, dark: 0x2DD4BF),
                iconStart: Color.dynamic(light: 0x2DC7B4, dark: 0x2DD4BF),
                iconEnd: Color.dynamic(light: 0x0891B2, dark: 0x0F766E),
                softFill: Color.dynamic(light: 0xE9FBF7, dark: 0x102A28, lightAlpha: 1, darkAlpha: 0.92),
                softBorder: Color.dynamic(light: 0x7ADBCF, dark: 0x5EEAD4, lightAlpha: 0.62, darkAlpha: 0.28),
                shadow: Color.dynamic(light: 0x0F766E, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.22)
            )
        case .image, .video, .file, .text, .imageGen, .nativePdf, .toolCall:
            return attachmentAccent
        }
    }
}

private struct ComposerCapabilityAccent {
    let tint: Color
    let iconStart: Color
    let iconEnd: Color
    let softFill: Color
    let softBorder: Color
    let shadow: Color
}

private enum ComposerControlChipAccessory {
    case none
    case chevron
    case selectedMark
}

private struct ComposerInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// The two values the composer's "Tools" chip draws.
struct ComposerToolsChipState: Equatable {
    /// Servers turned on and usable in this conversation.
    var enabledServerCount: Int
    /// Whether the current connection and model can use MCP tools; the chip is dimmed when they cannot.
    var isAvailable: Bool

    /// What VoiceOver reads as the value. When the model cannot use tools it gives the reason, the same
    /// sentence as the title of the panel the chip opens, instead of the "Disabled" it reads when no
    /// server is turned on.
    var accessibilityValue: String {
        guard isAvailable else { return L10n.tr("This model can't use tools", table: .mcp) }
        return enabledServerCount > 0 ? String(enabledServerCount) : L10n.tr("Disabled")
    }

    /// Whether the capability strip draws the "Tools" capsule: the master switch is on and at least one server has been added (even if all are off).
    /// Hidden when none has been added (the discovery entry is in Settings > MCP); also not drawn while the panel state has not been read yet (`.empty`).
    static func resolve(featureEnabled: Bool, panelState: McpToolPanelState) -> ComposerToolsChipState? {
        guard featureEnabled, panelState.hasServers else { return nil }
        return ComposerToolsChipState(
            enabledServerCount: panelState.enabledServerCount,
            isAvailable: panelState.availability.isAvailable
        )
    }
}

/// Dictation host mount: not mounted when the controller cannot be created (nil).
private struct ChatComposerDictationHost: ViewModifier {
    let controller: DictationController?
    let slotKey: String
    let canSend: () -> Bool
    /// Inserts the transcript and returns the full text after insertion.
    let onInsert: (String) -> String
    /// Sends the given text.
    let onSend: (String) -> Void

    /// Remembers the text after the latest insertion: "transcribe and send" sends right after inserting, without waiting for the bound @State to refresh.
    private final class InsertedText {
        var value: String?
    }

    @State private var inserted = InsertedText()

    @ViewBuilder
    func body(content: Content) -> some View {
        if let controller {
            let inserted = inserted
            let onInsert = onInsert
            let onSend = onSend
            content.dictationHost(
                controller: controller,
                slotKey: slotKey,
                canSend: canSend,
                onInsert: { transcript in inserted.value = onInsert(transcript) },
                onSend: {
                    guard let text = inserted.value else { return }
                    inserted.value = nil
                    onSend(text)
                }
            )
        } else {
            content
        }
    }
}

// MARK: - Attachment entries

/// The three attachment entries of the input: enabled / visible but disabled with a reason / hidden, plus the first-attach hint flag.
/// The criteria read only the facade entry `CapabilityEvidenceFacade.attachmentImportEntry` and the same three-key projection.
struct ComposerAttachmentEntries: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let isEnabled: Bool
        /// The localized disabled reason; non-nil only when the entry is visible but disabled.
        let disabledReason: String?
        /// The projection is unknown: when an attachment is actually added to the pending list, a light hint is shown once per model.
        let hintsFirstAttach: Bool
        let medium: InputCapabilityCopy.Medium

        var isVisible: Bool { isEnabled || disabledReason != nil }

        static func hidden(_ medium: InputCapabilityCopy.Medium) -> Entry {
            Entry(isEnabled: false, disabledReason: nil, hintsFirstAttach: false, medium: medium)
        }
    }

    let image: Entry
    let video: Entry
    let file: Entry
    /// The reason when the file entry is available (text injection) but native files are not accepted: used to hint when a binary file is picked.
    var nativeFileRefusal: String? = nil

    static let closed = ComposerAttachmentEntries(image: .hidden(.image), video: .hidden(.video), file: .hidden(.file))

    /// When the file picker / drops go through file import, the hint reasons for media the entry does not accept (passed to `ChatDropImport.processFileURLs`).
    var fileImportRefusalReasons: [AttachmentKind: String] {
        var reasons: [AttachmentKind: String] = [:]
        if let reason = video.disabledReason { reasons[.video] = reason }
        if let reason = file.disabledReason ?? nativeFileRefusal { reasons[.file] = reason }
        return reasons
    }

    func entry(for kind: AttachmentKind) -> Entry {
        switch kind {
        case .image: image
        case .video: video
        case .file: file
        }
    }

    /// The same identity as `ChatAttachmentPicker.ImportContext` (built from the partition).
    static func resolve(provider: Provider?, model: AIModel?, partitionID: String?) -> ComposerAttachmentEntries {
        guard let provider, let model else { return .closed }
        let identity = partitionID.flatMap {
            ChatView.capabilityEvidenceIdentity(provider: provider, model: model, partitionID: $0)
        }
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider,
            model: model,
            identity: identity,
            keys: Set(CapabilityEvidenceFacade.inputCapabilityKeys)
        )
        let importEntry = CapabilityEvidenceFacade.attachmentImportEntry(
            provider: provider, model: model, projection: projection,
            relayInputEnvelope: {
                RelayRuntimeSupport.inputEnvelope(
                    transport: $0, runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
                )
            }
        )

        func make(_ key: String, _ medium: InputCapabilityCopy.Medium, enabled: Bool) -> Entry {
            let input = projection.inputProjection(for: key)
            if enabled {
                return Entry(
                    isEnabled: true, disabledReason: nil,
                    hintsFirstAttach: input?.hint == .firstAttachOnce, medium: medium
                )
            }
            // With no projection no reason can be given: stay hidden rather than invent one.
            guard let reason = input?.disabledReason else { return .hidden(medium) }
            return Entry(
                isEnabled: false, disabledReason: InputCapabilityCopy.disabled(reason, medium),
                hintsFirstAttach: false, medium: medium
            )
        }

        // All three entries follow the same rule: only the three-key projection counts, with no fallback to the model's old capability fields.
        let image = make(CapabilityEvidenceFacade.visionInputKey, .image, enabled: importEntry.image)
        let video = make(CapabilityEvidenceFacade.videoInputKey, .video, enabled: importEntry.video)
        let file = make(
            CapabilityEvidenceFacade.fileInputKey, .file,
            enabled: importEntry.textFileInline || importEntry.nativeFile
        )
        let nativeFileRefusal = importEntry.nativeFile
            ? nil
            : projection.inputProjection(for: CapabilityEvidenceFacade.fileInputKey)?.disabledReason
                .map { InputCapabilityCopy.disabled($0, .file) }
        return ComposerAttachmentEntries(image: image, video: video, file: file, nativeFileRefusal: nativeFileRefusal)
    }
}

/// The entry gate and first hint before attachments join the pending list (pure functions, shared by ChatView and tests).
enum ComposerAttachmentAdmission {
    /// Media the entry does not accept is dropped; those with a disabled reason are deduplicated by reason and written into the hint, and those without a reason are left to prune silently as before.
    static func partition(
        _ attachments: [Attachment],
        entries: ComposerAttachmentEntries
    ) -> (accepted: [Attachment], refusalReasons: [String]) {
        var accepted: [Attachment] = []
        var reasons: [String] = []
        for attachment in attachments {
            let entry = entries.entry(for: attachment.kind)
            if entry.isEnabled {
                accepted.append(attachment)
            } else if let reason = entry.disabledReason, !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        return (accepted, reasons)
    }

    /// When the attachments actually added contain unknown media, a light one-line hint is shown the first time per connection x model (regardless of medium).
    static func firstAttachHint(
        added: [Attachment],
        entries: ComposerAttachmentEntries,
        providerID: UUID,
        modelID: String,
        history: InputCapabilityHintHistory = .shared
    ) -> String? {
        guard let entry = added.lazy.map({ entries.entry(for: $0.kind) }).first(where: \.hintsFirstAttach),
              history.consumeFirstHint(providerID: providerID, modelID: modelID) else { return nil }
        return InputCapabilityCopy.hintFirstAttach(entry.medium)
    }
}
