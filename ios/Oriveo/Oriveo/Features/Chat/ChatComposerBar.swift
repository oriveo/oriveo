import Combine
import SwiftUI

/// Composer shell fill per state. Light mode is opaque: the former translucent white tint is
/// composited source-over onto the page base so message text never shows through, while the
/// empty area looks unchanged. Dark mode keeps its translucent values.
enum ComposerShellFill {
    enum State: CaseIterable {
        case focused
        case draftHighlight
        case idle
    }

    struct Tone: Equatable {
        let hex: UInt
        let alpha: CGFloat
    }

    struct Spec: Equatable {
        let light: Tone
        let dark: Tone
    }

    /// Light value of `OriveoTheme.Palette.backgroundBase`, resolved from the token with a light trait.
    static let lightPageBase: UInt = {
        let resolved = UIColor(OriveoTheme.Palette.backgroundBase)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt { UInt(min(max((v * 255).rounded(), 0), 255)) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }()

    /// Source-over composite of `top` onto an opaque `base`; the result is always opaque.
    static func compositeOver(_ top: Tone, base: UInt) -> Tone {
        let a = min(max(top.alpha, 0), 1)
        func channel(_ shift: UInt) -> UInt {
            let t = Double((top.hex >> shift) & 0xFF)
            let b = Double((base >> shift) & 0xFF)
            let v = (t * Double(a) + b * (1 - Double(a))).rounded()
            return UInt(min(max(v, 0), 255))
        }
        return Tone(hex: (channel(16) << 16) | (channel(8) << 8) | channel(0), alpha: 1)
    }

    static func spec(for state: State) -> Spec {
        let lightTint: Tone
        let dark: Tone
        switch state {
        case .focused:
            lightTint = Tone(hex: 0xFFFFFF, alpha: 0.26)
            dark = Tone(hex: 0x101113, alpha: 0.46)
        case .draftHighlight:
            lightTint = Tone(hex: 0xFBF9FF, alpha: 0.19)
            dark = Tone(hex: 0x0B0C0E, alpha: 0.42)
        case .idle:
            lightTint = Tone(hex: 0xFFFFFF, alpha: 0.11)
            dark = Tone(hex: 0x07080A, alpha: 0.38)
        }
        return Spec(light: compositeOver(lightTint, base: lightPageBase), dark: dark)
    }

    static func color(for state: State) -> Color {
        let s = spec(for: state)
        return Color.dynamic(
            light: s.light.hex,
            dark: s.dark.hex,
            lightAlpha: s.light.alpha,
            darkAlpha: s.dark.alpha
        )
    }
}

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

/// Cold-start realtime typed text held while the disclosure is pending; kept in memory only and sent after consent.
struct RealtimeTypedPendingSend: Equatable {
    let text: String
    let request: RealtimeModelDisclosureRequest

    /// Text to send after the disclosure answer: sent only if accepted and the conversation is still pending; nil on decline, dismiss, or conversation switch (the text stays in the input).
    func textToSend(accepted: Bool, activeConversationID: UUID?) -> String? {
        guard accepted, request.conversationID == activeConversationID else { return nil }
        return text
    }

    /// Input text after the outcome of the in-flight typed send (same as the home page HomeRealtimeTypedSend.inputText): not cleared on send;
    /// cleared only when persisted and only if the field still holds this text (edits made while waiting are kept); openFailed / disclosureDeclined /
    /// endedBeforePersist / hostLeft keep the text as is, with no concatenation.
    static func inputText(
        _ current: String, sent: String, outcome: RealtimeModelPolicy.TypedSendOutcomeKind
    ) -> String {
        guard !RealtimeModelPolicy.typedSendOutcome(context: .chat, outcome: outcome).inputKeepsText else { return current }
        return current.trimmingCharacters(in: .whitespacesAndNewlines) == sent ? "" : current
    }
}

/// Two realtime session signals observed by the input bar: user turns persisted in this page's realtime session, and the end delivery of the call.
private struct RealtimeSessionSignals: ViewModifier {
    let onUserPersisted: (Int?) -> Void
    let onEnd: (VoiceConversationSession.EndDelivery?) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: VoiceConversationSession.shared.realtimeDrafts?.userPersisted) { _, count in onUserPersisted(count) }
            .onChange(of: VoiceConversationSession.shared.lastEnd) { _, end in onEnd(end) }
    }
}

/// A realtime typed send already handed off by this page and not yet settled: the text stays in the field until settled, and no new send is handed off.
/// Persisted signal uses the page's persisted user-turn count (VoiceConversationSession.realtimeDrafts); the end signal uses lastEnd.
struct RealtimeTypedInFlight: Equatable {
    let text: String
    let conversationID: UUID?
    /// Persisted user-turn count of this page's realtime session at handoff (0 on cold start); exceeding it means this text is persisted.
    let persistedBaseline: Int

    /// Record the in-flight send at handoff; nil if one is already in flight (unsettled), so the page does not hand off another.
    @MainActor
    static func begin(
        _ current: RealtimeTypedInFlight?, text: String, conversationID: UUID?,
        session: VoiceConversationSession = .shared
    ) -> RealtimeTypedInFlight? {
        guard current == nil else { return nil }
        let baseline = session.hasRealtime(in: conversationID) ? (session.realtimeDrafts?.userPersisted ?? 0) : 0
        return RealtimeTypedInFlight(text: text, conversationID: conversationID, persistedBaseline: baseline)
    }

    /// The persisted user-turn count changed: above the baseline means this text is persisted; otherwise there is no outcome yet.
    func outcome(userPersisted: Int?) -> RealtimeModelPolicy.TypedSendOutcomeKind? {
        (userPersisted ?? 0) > persistedBaseline ? .persisted : nil
    }

    /// The page switched to another conversation: this text settles as hostLeft.
    func outcome(host conversationID: UUID?) -> RealtimeModelPolicy.TypedSendOutcomeKind? {
        conversationID == self.conversationID ? nil : .hostLeft
    }

    /// Input text from the outcome.
    func inputText(_ current: String, outcome: RealtimeModelPolicy.TypedSendOutcomeKind) -> String {
        RealtimeTypedPendingSend.inputText(current, sent: text, outcome: outcome)
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
            .oriveoPopover(isPresented: $showsPreview, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
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
    /// Conversation value may be a realtime model while the voice catalog failed to load: when non-nil, a failure row with retry shows above the input and the primary key is disabled without a spinner.
    var realtimeCatalogRetryRow: ChatRealtimeCatalogRetryRow? = nil
    /// capability keys the ChatView exports from the current facade projection.
    /// The set is empty when Relay cannot resolve a unique final route, so the UI stays fail-closed.
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
    /// Conversation switched to typing while realtime is selected (nil = compose state): ChatView owns it, kept in memory only; capability projection and this bar read the same value;
    /// removed when realtime selection for that conversation becomes false.
    var realtimeTypingHosts: Binding<Set<UUID?>> = .constant([])

    let onSend: (_ text: String, _ attachments: [Attachment]) -> Void
    let onChooseModel: () -> Void
    /// Retry in the failure row: reload the voice catalog.
    var onRetryRealtimeCatalog: () -> Void = {}
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
    /// Realtime typing send that would open a session: the host runs the same sign-in gates as ≋;
    /// false = a prompt was shown, the text stays in the composer.
    var realtimeTypedPreflight: () -> Bool = { true }
    /// Realtime selection without disclosure consent yet: the host shows the disclosure (with cost note) and holds this text, then sends it after consent.
    var onNeedsRealtimeDisclosure: (RealtimeModelSelection, String) -> Void = { _, _ in }
    /// The realtime typed send already handed off and not yet settled: ChatView owns it (a send after consent is also recorded here); kept in memory only.
    var realtimeTypedInFlight: Binding<RealtimeTypedInFlight?> = .constant(nil)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Model options "Add a search service": after the sheet is dismissed, push Settings > Web search; going back returns to this conversation with the draft untouched.
    @State private var opensSearchSettingsAfterControls = false
    /// The sub-page to push straight in the next time the model options panel opens (the error card's "Switch service"); cleared when the panel closes.
    @State private var modelControlsInitialRoute: ModelControlsRoute?
    /// Same idea: when the relay web template is rejected and "Test capabilities" is tapped, open that model's Advanced page once the
    /// sheet is dismissed (the verdict stays on that row with the test button beside it; no test is started automatically).
    @State private var opensTestCapabilitiesAfterControls = false
    @State private var webPreferenceSelection: CapabilityWebPreference = .off
    @State private var voiceTapGuard = VoiceEntryTapGuard()
    /// Recognition language sheet inside the voice stage.
    @State private var showsRecognitionLanguageSheet = false
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

    private var controlsDisabled: Bool { isSendingMessage || isReadOnly }

    private var attachmentUploadBlocked: Bool {
        false
    }

    private var hasComposerContent: Bool {
        !composerText.isEmpty && composerText.contains(where: { !$0.isWhitespace })
            || !pendingAttachments.isEmpty
    }

    private var preferredAnimation: Animation {
        Self.composerAnimation(reduceMotion: reduceMotion)
    }

    static func composerAnimation(reduceMotion: Bool) -> Animation {
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
            banner: modelRemovedBanner,
            awaitingVoiceCatalog: awaitsVoiceCatalog
        )
    }

    /// Conversation value may be a realtime model while the voice catalog is not ready yet: the send key is disabled while loading; the revision re-evaluates when the catalog arrives.
    private var awaitsVoiceCatalog: Bool {
        _ = appState.realtimeVoiceCatalogRevision
        guard let conversationID,
              let conversation = appState.conversation(for: conversationID),
              let conversationProvider = appState.provider(for: conversation.providerID)
        else { return false }
        return ChatModelRemovedBanner.awaitsVoiceCatalog(
            storedModelID: conversation.modelID,
            provider: conversationProvider,
            voiceCatalog: appState.realtimeVoiceCatalog()
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

    /// Note context above the input: pinned chips plus related-note suggestions (matches Web).
    #if DEBUG
    nonisolated(unsafe) static var bodyEvaluationCount = 0
    static func resetBodyEvaluationCount() { bodyEvaluationCount = 0 }
    #endif

    /// While the voice stage is shown, the panel spans the full width at the bottom (including the safe area), with no bar inset or gradient background and no managed quota line; other banners keep their own margins.
    private var showsVoiceStage: Bool {
        voiceConversationController != nil || VoiceConversationDemo.shows(on: .chat)
    }

    var body: some View {
        #if DEBUG
        let _ = { Self.bodyEvaluationCount += 1 }()
        #endif
        let _ = CapabilityEvidenceObservationBridge.shared.contentRevision
        let stageInset = showsVoiceStage ? OriveoTheme.Spacing.lg : 0
        VStack(alignment: .leading, spacing: 10) {
            Group {
            ChatComposerBannerStack(
                modelRemovedBanner: modelRemovedBanner,
                realtimeCatalogRetryRow: realtimeCatalogRetryRow,
                compactionHintConversationID: compactionHintConversationID,
                compactingConversationID: compactingConversationID,
                conversationID: conversationID,
                onChooseModel: onChooseModel,
                onRetryRealtimeCatalog: onRetryRealtimeCatalog
            )

            ChatComposerNoteContextSection(
                pinnedNoteSummaries: pinnedNoteSummaries,
                visibleRelatedNotes: visibleRelatedNotes,
                conversationID: conversationID,
                dismissedRelatedNoteIDs: $dismissedRelatedNoteIDs
            )

            if let dictationController = DictationHub.shared.controller {
                DictationPromptSlot(
                    controller: dictationController,
                    onCheckConnection: openDictationCheckConnection,
                    onOpenVoiceSettings: openDictationVoiceSettings
                )
            }
            }
            .padding(.horizontal, stageInset)

            if let voiceSurface = voiceConversationController {
                // The voice conversation replaces the chip row and the input row; the mic and the field are hidden.
                VoiceConversationBar(
                    surface: voiceSurface,
                    orbNamespace: voiceOrbNamespace,
                    languageChip: .recognitionLanguage { showsRecognitionLanguageSheet = true }
                ) {
                    // The idle stage shows no ✕ (the keyboard button on the left switches to typing); ✕ only ends an active conversation.
                    VoiceConversationSession.shared.end(.user)
                }
                .recognitionLanguageSheet(isPresented: $showsRecognitionLanguageSheet)
                .transition(.opacity)
            } else if VoiceConversationDemo.shows(on: .chat) {
                VoiceConversationDemo.bar()
            } else {
                if showsModeControls {
                    ChatComposerCapabilityStrip(
                        provider: provider,
                        currentModel: currentModel,
                        conversationID: conversationID,
                        generationParameterScopeID: generationParameterScopeID,
                        modelControlTransportIdentity: modelControlTransportIdentity,
                        controlsDisabled: controlsDisabled,
                        isSendingMessage: isSendingMessage,
                        isReadOnly: isReadOnly,
                        showsModelControls: $showsModelControls,
                        modelControlsInitialRoute: modelControlsInitialRoute,
                        opensModelPickerAfterControls: $opensModelPickerAfterControls,
                        opensConnectionSettingsAfterControls: $opensConnectionSettingsAfterControls,
                        opensConnectionWebSearchAfterControls: $opensConnectionWebSearchAfterControls,
                        opensSearchSettingsAfterControls: $opensSearchSettingsAfterControls,
                        opensTestCapabilitiesAfterControls: $opensTestCapabilitiesAfterControls,
                        onModelControlsDismiss: handleModelControlsDismiss,
                        webEnabled: $webEnabled,
                        reasoningMode: $reasoningMode,
                        reasoningIntentSelection: $reasoningIntentSelection,
                        modelBehaviorAccent: modelBehaviorAccent,
                        hasModelControlSelection: hasModelControlSelection,
                        activeCapabilityGlyphs: activeCapabilityGlyphs,
                        modelControlSummary: modelControlSummary,
                        toolsChip: toolsChip,
                        onOpenTools: onOpenTools,
                        contextUsage: contextUsage,
                        onOpenContextUsage: onOpenContextUsage,
                        highlightPulse: highlightPulse
                    )
                        .padding(.bottom, -4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !pendingAttachments.isEmpty {
                    ChatComposerAttachmentPreviewRow(
                        provider: provider,
                        pendingAttachments: $pendingAttachments,
                        attachmentAccent: attachmentAccent,
                        onTapKnowledgeCTA: { navigation.openSkillEdit() }
                    )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ChatComposerInputRow(
                    pendingQuoteContext: $pendingQuoteContext,
                    composerText: $composerText,
                    composerFocused: composerFocused,
                    dictationProbe: dictationProbe,
                    dictationCanSend: dictationCanSend,
                    isSendingMessage: isSendingMessage,
                    controlsDisabled: controlsDisabled,
                    hasDraftHighlight: hasDraftHighlight,
                    hasComposerContent: hasComposerContent,
                    supportsAttachmentEntry: supportsAttachmentEntry,
                    attachmentUploadBlocked: attachmentUploadBlocked,
                    attachmentButtonSystemImage: attachmentButtonSystemImage,
                    attachmentButtonCount: attachmentButtonCount,
                    supportsImageAttachment: supportsImageAttachment,
                    supportsVideoAttachment: supportsVideoAttachment,
                    supportsFileAttachment: supportsFileAttachment,
                    attachmentEntries: attachmentEntries,
                    hasDisabledAttachmentEntry: hasDisabledAttachmentEntry,
                    attachmentAccessibilityLabel: attachmentAccessibilityLabel,
                    attachmentAccessibilityValue: attachmentAccessibilityValue,
                    attachmentAccent: attachmentAccent,
                    onShowCamera: onShowCamera,
                    onShowPhotoPicker: onShowPhotoPicker,
                    onShowFileImporter: onShowFileImporter,
                    awaitsVoiceCatalog: awaitsVoiceCatalog,
                    realtimeCatalogRetryRow: realtimeCatalogRetryRow,
                    modelRemovedBanner: modelRemovedBanner,
                    isRealtimeTyping: isRealtimeTyping,
                    hasRealtimeTypedInFlight: realtimeTypedInFlight.wrappedValue != nil,
                    voiceConversationAvailable: voiceConversationAvailable,
                    modelProducesText: VoiceConversationEntry.modelProducesText(currentModel),
                    realtimeSelected: appState.realtimeModelSelection(for: conversationID) != nil,
                    conversationID: conversationID,
                    realtimeTypingHosts: realtimeTypingHosts,
                    voiceOrbNamespace: voiceOrbNamespace,
                    onCancel: onCancel,
                    onStartVoiceConversationTap: startVoiceConversationFromTap,
                    onSubmit: { text in submitComposer(text: text) }
                )
                    .transition(.opacity)
            }

        }
        .padding(.horizontal, showsVoiceStage ? 0 : OriveoTheme.Spacing.lg)
        .padding(.top, showsVoiceStage ? 0 : 12)
        .padding(.bottom, showsVoiceStage ? 0 : OriveoTheme.Spacing.sm + 2)
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
            if let inFlight = realtimeTypedInFlight.wrappedValue {
                settleRealtimeTyped(inFlight, outcome: .hostLeft)
            }
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
        // Metadata published after this composer appeared can resolve the runtime identity the
        // stored selection is keyed by: re-read once (writes are equality-guarded).
        .onReceive(
            NotificationCenter.default.publisher(for: .metadataSnapshotDidPublish).receive(on: RunLoop.main)
        ) { _ in
            syncStoredCapabilitySelection()
        }
        .onChange(of: conversationID) { old, new in
            syncStoredCapabilitySelection()
            VoiceConversationSession.shared.hostSwitched(from: old, to: new)
            if let inFlight = realtimeTypedInFlight.wrappedValue, let outcome = inFlight.outcome(host: new) {
                settleRealtimeTyped(inFlight, outcome: outcome)
            }
        }
        .onChange(of: isSendingMessage) { wasSending, isSending in
            if wasSending, !isSending { voiceTapGuard.generationEnded(atMs: VoiceEntryTapGuard.nowMs()) }
        }
        .modifier(RealtimeTypingReset(
            key: RealtimeTypingReset.Key(
                conversationID: conversationID,
                selection: appState.realtimeModelSelection(for: conversationID)
            ),
            hosts: realtimeTypingHosts
        ))
        .modifier(RealtimeSessionSignals(
            onUserPersisted: realtimeTypedUserPersisted,
            onEnd: realtimeSessionEnded
        ))
        // A conversation switch, an external push, focus loss and a store echo can land in the same
        // update; separate onChange handlers run in no guaranteed order.
        .onChange(of: draftInputs) { old, new in
            applyDraftInputs(old: old, new: new)
        }
        .onChange(of: showsModelControls) { _, isOpen in
            guard !isOpen else { return }
            modelControlsInitialRoute = nil
            syncStoredCapabilitySelection()
        }
        // The external search error card's "Switch service": open the panel through the same sheet as the real entry and push "Search method".
        .onReceive(NotificationCenter.default.publisher(for: .oriveoOpenSearchSourcePage)) { note in
            guard let target = note.object as? UUID, target == conversationID, !showsModelControls else { return }
            modelControlsInitialRoute = .searchSource
            showsModelControls = true
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
            onSend: { text in submitComposer(text: text) },
            live: .probe(dictationProbe, text: $composerText)
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

    /// Dictation card Change Language / Change Dictation Engine: open the voice settings page.
    private func openDictationVoiceSettings() {
        navigation.attemptNavigate(to: .voiceSettings)
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
        if isRealtimeTyping {
            submitRealtimeTyped(text: text)
            return
        }
        onSend(text, pendingAttachments)
    }

    /// Realtime typed send: hand off to this conversation's realtime session (a playback-only one if none), and keep the typing state.
    /// No clearing on send: the text stays in the field and is cleared on first persist; no new send is handed off while one is in flight (unsettled).
    private func submitRealtimeTyped(text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let session = VoiceConversationSession.shared
        guard realtimeTypedInFlight.wrappedValue == nil else { return }
        // Cold start (no realtime session on this page yet) runs the same pre-check as the ≋ key first; a blocked text stays in the input.
        if !session.hasRealtime(in: conversationID), !realtimeTypedPreflight() { return }
        guard let inFlight = RealtimeTypedInFlight.begin(
            realtimeTypedInFlight.wrappedValue, text: typed, conversationID: conversationID, session: session
        ) else { return }
        realtimeTypedInFlight.wrappedValue = inFlight
        Task {
            // Not yet accepted the disclosure: the page shows it and holds this text without connecting; the page sends it after consent.
            let sent = await session.sendRealtimeTyped(
                typed, conversationID: inFlight.conversationID, host: appState,
                onNeedsRealtimeDisclosure: { onNeedsRealtimeDisclosure($0, typed) }
            )
            // Not handed off (openFailed / disclosureDeclined): the text is still in the field; only the in-flight send is settled.
            if !sent { settleRealtimeTyped(inFlight, outcome: .openFailed) }
        }
    }

    /// Clear the input when the in-flight realtime typed send is persisted (only if the field still holds this text).
    private func realtimeTypedUserPersisted(_ userPersisted: Int?) {
        guard let inFlight = realtimeTypedInFlight.wrappedValue,
              let outcome = inFlight.outcome(userPersisted: userPersisted) else { return }
        settleRealtimeTyped(inFlight, outcome: outcome)
    }

    /// The call ends: if the in-flight send is not yet persisted, the text stays in the field and is not concatenated;
    /// ✕ hands the half-spoken transcript back as the draft.
    private func realtimeSessionEnded(_ end: VoiceConversationSession.EndDelivery?) {
        guard let end else { return }
        if let inFlight = realtimeTypedInFlight.wrappedValue {
            settleRealtimeTyped(inFlight, outcome: .endedBeforePersist)
        }
        guard let draft = VoiceConversationSession.shared.consumeEndDraft(end, host: conversationID) else { return }
        composerText = composerText.isEmpty ? draft : composerText + " " + draft
    }

    /// Settle the in-flight send (only if it is still this one): compute the input text from the outcome and release the next handoff.
    private func settleRealtimeTyped(_ inFlight: RealtimeTypedInFlight, outcome: RealtimeModelPolicy.TypedSendOutcomeKind) {
        guard realtimeTypedInFlight.wrappedValue == inFlight else { return }
        realtimeTypedInFlight.wrappedValue = nil
        composerText = inFlight.inputText(composerText, outcome: outcome)
    }

    /// The same source as the send button; the transcript is inserted before sending, so this is judged as "has content".
    private var dictationCanSend: Bool {
        ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: true,
            controlsDisabled: controlsDisabled,
            banner: modelRemovedBanner,
            awaitingVoiceCatalog: awaitsVoiceCatalog
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

    private func handleModelControlsDismiss() {
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
        if opensSearchSettingsAfterControls {
            opensSearchSettingsAfterControls = false
            appState.navigation.attemptNavigate(to: .webSearchSettings)
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
    }

    /// The VoiceOver summary reads **what will actually happen on this send**, from the same source as the chip glyphs.
    /// Reading the expressed preference (`webPreferenceSelection` / stored intent) would make VoiceOver users
    /// hear "Web: Auto" while the screen shows no globe and the request carries no web tool.
    private var modelControlSummary: String {
        let web = ModelControlIntentLabel.webText(
            capabilityDecision.webSearchEnabled ? webPreferenceSelection : .off
        )
        // "Automatic" rather than "Provider default": the panel row is now called "Automatic",
        // and VoiceOver reading a different word than the screen is as bad as a wrong label.
        let thinking = capabilityDecision.reasoningIntent.map(ModelControlIntentLabel.text)
            ?? L10n.tr("Automatic")
        return "\(L10n.tr("Web Search", table: .chat)): \(web) · \(L10n.tr("Thinking Mode", table: .chat)): \(thinking)"
    }

    // MARK: - Text Input Shell

    /// Empty-draft placeholder "Listening…" while recording (design §1 row 1); unchanged while transcribing or idle. Home's field uses it too.
    static func listeningPlaceholder(phase: DictationInputPhase) -> String? {
        phase == .recording ? L10n.tr("Listening…", table: .voice) : nil
    }

    /// Composer placeholder: listening › AI is answering › type a message.
    static func inputPlaceholder(phase: DictationInputPhase, isSending: Bool) -> String {
        if let listening = listeningPlaceholder(phase: phase) { return listening }
        if isSending { return L10n.tr("AI is answering...", table: .chat) }
        return L10n.tr("Type a message...", table: .chat)
    }

    /// The attachment "+" only shows in the normal phase: no attaching while recording / transcribing, so the button would only mis-tap (matches the canvas and Android).
    static func showsAttachmentEntry(supportsEntry: Bool, phase: DictationInputPhase) -> Bool {
        supportsEntry && !phase.isDictating
    }

    /// Third-compaction hint (P3·U4 contract item 6): shown while ChatManager flags this conversation.
    private var compactionHintConversationID: UUID? {
        guard let conversationID, appState.pendingCompactionHint == conversationID else { return nil }
        return conversationID
    }

    /// Shown only while this conversation's AI summary call runs.
    private var compactingConversationID: UUID? {
        guard let conversationID, appState.aiCompactingConversationIDs.contains(conversationID) else { return nil }
        return conversationID
    }

    // MARK: - Voice Conversation

    /// Primary key in the ≋ state: debounce through the tap guard, then start the voice conversation.
    private func startVoiceConversationFromTap() {
        guard voiceTapGuard.acceptsTap(atMs: VoiceEntryTapGuard.nowMs()) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onStartVoiceConversation()
    }

    /// Realtime typing in this conversation: a realtime selection exists and the user switched from the stage to the field.
    private var isRealtimeTyping: Bool {
        realtimeTypingHosts.wrappedValue.contains(conversationID) && appState.realtimeModelSelection(for: conversationID) != nil
    }

    /// Voice stage: shown while this page hosts a live conversation; stays up with a realtime selection (an idle tap takes the same path as ≋).
    /// After a failed call: retry = tap the orb; open connection / switch model go through realtimeFailureNavigation.
    private var voiceConversationController: (any VoiceConversationSurface)? {
        // Typing wins over the stage: the field shows even mid-conversation.
        guard !isRealtimeTyping else { return nil }
        let session = VoiceConversationSession.shared
        let selection = appState.realtimeModelSelection(for: conversationID)
        let failure = session.realtimeFailure(in: conversationID, selection: selection)
        let navigation = realtimeFailureNavigation
        return session.stageSurface(
            in: conversationID,
            realtimeSelected: showsRealtimeVoiceStage,
            realtimeSelection: selection,
            onIdleTap: {
                guard voiceTapGuard.acceptsTap(atMs: VoiceEntryTapGuard.nowMs()) else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onStartVoiceConversation()
            },
            onFailureAction: { navigation.perform($0, failure: failure, selection: selection) },
            onSwitchToTyping: { [realtimeTypingHosts, conversationID] in
                realtimeTypingHosts.wrappedValue.insert(conversationID)
            }
        )
    }

    /// Stage failure routes: open connection matches the dictation card's Check Connection; switch model opens this page's model picker.
    private var realtimeFailureNavigation: RealtimeFailureNavigation {
        RealtimeFailureNavigation(
            openConnection: openDictationCheckConnection,
            openModelPicker: onChooseModel,
            clearRealtimeSelection: { [appState, conversationID] in
                appState.clearRealtimeModelSelection(for: conversationID)
            }
        )
    }

    /// This page has a realtime selection and the primary key resolves to the stage (not generating, voice conversation allowed).
    private var showsRealtimeVoiceStage: Bool {
        VoiceConversationEntry.primaryAction(
            isSending: isSendingMessage,
            hasContent: hasComposerContent,
            sendEnabled: false,
            voiceAvailable: voiceConversationAvailable,
            modelProducesText: VoiceConversationEntry.modelProducesText(currentModel),
            realtimeSelected: appState.realtimeModelSelection(for: conversationID) != nil,
            realtimeTyping: isRealtimeTyping,
            realtimeReadOnly: controlsDisabled
        ) == .voiceStage
    }

    /// ≋ needs an editable page, a usable model and the dictation pipeline.
    private var voiceConversationAvailable: Bool {
        !controlsDisabled && modelRemovedBanner == nil && DictationHub.shared.controller != nil
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
            // Brand colors: the default light palette keeps hand-tuned values, others follow the palette; dark soft fill is 15% primary, no hard-coded purple-black.
            tint: Color.brand(defaultLight: 0x5B4AB8, light: \.textSafe, dark: \.accent),
            iconStart: Color.brand(defaultLight: 0xA78BFA, light: \.accent, dark: \.accent), // dark-palette-guard: keep (d) hand-tuned light value for the default palette
            iconEnd: Color.brand(defaultLight: 0x6D5BD0, light: \.ink, dark: \.primary),
            softFill: Color.brand(defaultLight: 0xF5F3FF, light: \.soft, dark: \.primary, darkAlpha: 0.15),
            softBorder: Color.brand(defaultLight: 0xC4B5FD, light: \.ink, lightAlpha: 0.7, dark: \.primary, darkAlpha: 0.3), // dark-palette-guard: keep (d) hand-tuned light value for the default palette
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

/// Composer input row (quote chip, text shell, attachment entry, action cluster), split out of
/// `ChatComposerBar.body` so the Debug body frame keeps main-thread stack headroom. Inputs are explicit
/// values, bindings and callbacks; behavior and styling are unchanged.
private struct ChatComposerInputRow: View {
    @Binding var pendingQuoteContext: QuoteContext?
    @Binding var composerText: String
    let composerFocused: Binding<Bool>
    let dictationProbe: ComposerSelectionProbe
    let dictationCanSend: Bool
    let isSendingMessage: Bool
    let controlsDisabled: Bool
    let hasDraftHighlight: Bool
    let hasComposerContent: Bool
    let supportsAttachmentEntry: Bool
    let attachmentUploadBlocked: Bool
    let attachmentButtonSystemImage: String
    let attachmentButtonCount: Int
    let supportsImageAttachment: Bool
    let supportsVideoAttachment: Bool
    let supportsFileAttachment: Bool
    let attachmentEntries: ComposerAttachmentEntries
    let hasDisabledAttachmentEntry: Bool
    let attachmentAccessibilityLabel: String
    let attachmentAccessibilityValue: String
    let attachmentAccent: ComposerCapabilityAccent
    let onShowCamera: () -> Void
    let onShowPhotoPicker: () -> Void
    let onShowFileImporter: () -> Void
    let awaitsVoiceCatalog: Bool
    let realtimeCatalogRetryRow: ChatRealtimeCatalogRetryRow?
    let modelRemovedBanner: ChatModelRemovedBanner?
    let isRealtimeTyping: Bool
    let hasRealtimeTypedInFlight: Bool
    let voiceConversationAvailable: Bool
    let modelProducesText: Bool
    let realtimeSelected: Bool
    let conversationID: UUID?
    let realtimeTypingHosts: Binding<Set<UUID?>>
    let voiceOrbNamespace: Namespace.ID
    let onCancel: () -> Void
    let onStartVoiceConversationTap: () -> Void
    let onSubmit: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool { colorScheme == .dark }
    private var preferredAnimation: Animation { ChatComposerBar.composerAnimation(reduceMotion: reduceMotion) }

    private func submitComposer(text: String) {
        onSubmit(text)
    }

    var body: some View {
        if let controller = DictationHub.shared.controller {
            // While dictating, the field stays on top (read-only) and the recording bar takes the full row below it.
            DictationInputSwitcher(
                controller: controller,
                canSend: dictationCanSend,
                arrangement: .sideBySide(spacing: 7, stackedSpacing: 8)
            ) { phase in
                composerInputColumn(phase: phase)
            } buttons: {
                composerActionCluster
                    .padding(.bottom, 7)
            }
        } else {
            composerIdleInputRow
        }
    }

    private var composerIdleInputRow: some View {
        HStack(alignment: .bottom, spacing: 7) {
            composerInputColumn(phase: .normal)
            composerActionCluster
                .padding(.bottom, 7)
        }
    }

    private func composerInputColumn(phase: DictationInputPhase) -> some View {
        VStack(spacing: 6) {
            pendingQuoteChip
            composerTextInputShell(phase: phase)
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

    /// While dictating (phase != normal) the field is read-only, drops the keyboard and hides the inline mic and attachment "+"; recording adds the flow border.
    private func composerTextInputShell(phase: DictationInputPhase) -> some View {
        let shellShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let focused = composerFocused.wrappedValue
        let showsAttachmentEntry = ChatComposerBar.showsAttachmentEntry(supportsEntry: supportsAttachmentEntry, phase: phase)

        return HStack(alignment: .center, spacing: 8) {
            if showsAttachmentEntry {
                attachmentEntryButton
            }

            // Not a SwiftUI TextField: it re-lays out a long single paragraph on every layout pass, see ComposerTextView.
            ComposerTextView(
                text: $composerText,
                isFocused: composerFocused,
                placeholder: ChatComposerBar.inputPlaceholder(
                    phase: phase, isSending: isSendingMessage
                ),
                font: Self.inputFont,
                textColor: controlsDisabled ? Self.inputDisabledColor : Self.inputTextColor,
                isEnabled: !controlsDisabled && !phase.isDictating,
                maxLength: ChatInputLimit.maxUTF16,
                onLengthLimitExceeded: ChatInputLimit.showLimitReachedToast,
                selectionProbe: dictationProbe,
                // Return on a hardware keyboard sends: the same condition and the same submitComposer as the send button
                onHardwareReturnSend: { submitComposer(text: composerText) },
                canSendOnHardwareReturn: !isSendingMessage && hasDraftHighlight
            )
            .accessibilityIdentifier("chat_composer_input")
            .padding(.vertical, 8)
            .frame(minHeight: 44, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let controller = DictationHub.shared.controller, !phase.isDictating {
                DictationMicButton(controller: controller)
                    .disabled(controlsDisabled)
            }
        }
        .padding(.leading, showsAttachmentEntry ? 6 : 14)
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
            if phase == .recording {
                DictationFlowBorder(cornerRadius: 24)
            } else if focused {
                // Focused: static AI gradient border, no per-frame redraw while typing.
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
        let state: ComposerShellFill.State
        if composerFocused.wrappedValue {
            state = .focused
        } else if hasDraftHighlight {
            state = .draftHighlight
        } else {
            state = .idle
        }
        return ComposerShellFill.color(for: state)
    }

    private var composerShellBorder: Color {
        // Focused: the solid stroke yields to the gradient border (aiFocusBorder).
        if composerFocused.wrappedValue { return .clear }
        if hasDraftHighlight { return OriveoTheme.Palette.primary.opacity(0.25) }
        // Unfocused: soft lavender stroke in the aurora / brand family instead of neutral gray.
        return OriveoTheme.Palette.primary.opacity(0.16)
    }

    // MARK: - Focus Gradient Border

    private var aiBorderColors: [Color] {
        // Restrained rainbow: blue -> purple -> magenta -> warm -> mint -> back to blue.
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
            // Outer glow: the colored ring bleeds slightly past the edge.
            shape.stroke(gradient, lineWidth: 3)
                .blur(radius: 6)
                .opacity(0.55)
            // Crisp colored stroke.
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

        // Vision models: the image entry splits into Take Photo + Choose from Library, like ChatGPT / Claude / Gemini.
        // Take Photo only shows when the device has a camera (not on Mac Catalyst / Simulator).
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
            // No camera: fall back to a single button that opens the photo library.
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

    // MARK: - Attachment Composer Button

    private func attachmentComposerButton(
        systemImage: String,
        emphasized: Bool,
        disabled: Bool,
        count: Int
    ) -> some View {
        let accent = attachmentAccent

        return ZStack(alignment: .topTrailing) {
            // Flat lavender circle + bare icon, matching the toolbar buttons (no stroke / highlight / shadow box).
            // With attachments the icon turns brand purple with a count badge at the top trailing corner.
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

    // MARK: - Action Cluster

    private var composerActionCluster: some View {
        // A realtime typed sentence still in flight: the send key greys out like the not-sendable style.
        // Waiting for the voice catalog: the primary key (≋ / ↑ share one key) spins disabled and reads "loading model".
        // Catalog load failed: disabled without the spinner; the failure row above offers retry.
        let awaitingCatalog = awaitsVoiceCatalog
        let catalogLoading = ChatRealtimeCatalogRetryRow.showsLoadingIndicator(
            awaitingVoiceCatalog: awaitingCatalog,
            retryRow: realtimeCatalogRetryRow
        )
        let isPrimed = ChatModelRemovedBanner.isSendEnabled(
            hasComposerContent: hasComposerContent,
            controlsDisabled: controlsDisabled,
            banner: modelRemovedBanner,
            awaitingVoiceCatalog: awaitingCatalog
        ) && !(isRealtimeTyping && hasRealtimeTypedInFlight)

        let action = VoiceConversationEntry.primaryAction(
            isSending: isSendingMessage,
            hasContent: hasComposerContent,
            sendEnabled: isPrimed,
            voiceAvailable: voiceConversationAvailable,
            modelProducesText: modelProducesText,
            realtimeSelected: realtimeSelected,
            realtimeTyping: isRealtimeTyping,
            realtimeReadOnly: controlsDisabled
        )

        return Group {
            if action == .backToStage {
                backToStageButton
            } else if action != .voice && isSendingMessage {
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
                let isLit = !awaitingCatalog && (isVoice || isPrimed)
                OriveoCircleIconButton(
                    systemImage: isVoice ? "waveform" : "arrow.up",
                    // Unavailable (empty draft and no ≋): the same flat lavender circle as the attachment / top buttons (no white fill or grey edge);
                    // available: lit up as a purple gradient CTA, keeping the primary / secondary hierarchy.
                    fill: isLit
                        ? AnyShapeStyle(OriveoTheme.Palette.primaryGradient)
                        : AnyShapeStyle(Color.brand(defaultLight: OriveoLightBrand.defaultBrand.ink, light: \.ink, lightAlpha: 0.12, darkFixed: 0xFFFFFF, darkAlpha: 0.10)),
                    foreground: catalogLoading
                        ? .clear
                        : (isLit ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.textTertiary),
                    border: isLit ? OriveoTheme.Palette.hairline : .clear,
                    shadowColor: isLit ? OriveoTheme.Palette.primaryGlow : .clear,
                    size: 40,
                    iconSize: 16,
                    bounceValue: isPrimed
                ) {
                    if isVoice {
                        onStartVoiceConversationTap()
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        submitComposer(text: composerText)
                    }
                }
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .voiceOrbMatched(voiceOrbNamespace, reduceMotion: reduceMotion)
                .scaleEffect(isLit ? 1 : 0.96)
                .overlay {
                    if catalogLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(OriveoTheme.Palette.textTertiary)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(!isLit)
                // ≋ and ↑ are icon-only: each gets a VoiceOver label (↑ reads "Send" like Home); "loading model" while waiting for the catalog.
                .accessibilityLabel(
                    catalogLoading
                        ? Text(ChatModelRemovedBanner.voiceCatalogLoadingLabel)
                        : (isVoice ? Text(VoiceConversationCopy.startA11y) : Text(L10n.tr("Send", table: .chat)))
                )
                .accessibilityIdentifier(isVoice ? "chat_voice_conversation_button" : "chat_send_button")
            }
        }
        .animation(preferredAnimation, value: isSendingMessage)
        .animation(.easeInOut(duration: 0.18), value: hasComposerContent)
    }

    // MARK: - Voice Conversation

    /// Back-to-stage button in the ≋ slot while realtime typing with an empty draft (shared with Home).
    private var backToStageButton: some View {
        RealtimeBackToStageButton(
            accessibilityID: "chat_voice_back_to_stage_button",
            hitSize: 40,
            namespace: voiceOrbNamespace,
            reduceMotion: reduceMotion
        ) {
            // With a realtime session here: request the mic, resume capture on the same connection and return to the stage; stay typing if denied.
            // Without one, only return to the idle stage: no connect, no mic request.
            // A reply that is playing is interrupted by resumeVoiceCapture (interruptsPlayback); the page does not decide.
            let session = VoiceConversationSession.shared
            let host = conversationID
            let decision = RealtimeModelPolicy.backToStage(session: session.hasRealtime(in: host) ? .typingOpened : .none)
            switch decision.action {
            case .idleStage:
                realtimeTypingHosts.wrappedValue.remove(host)
                return
            case .none:
                return
            case .resumeCapture:
                break
            }
            Task {
                if await session.resumeRealtimeVoice(in: host) {
                    realtimeTypingHosts.wrappedValue.remove(host)
                }
            }
        }
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
    /// A specific unavailable reason (realtime model selected: voice_realtime_no_tools) for VoiceOver; nil = the generic MCP reason.
    var unavailableReason: String? = nil

    /// What VoiceOver reads as the value. When the model cannot use tools it gives the reason, the same
    /// sentence as the title of the panel the chip opens, instead of the "Disabled" it reads when no
    /// server is turned on.
    var accessibilityValue: String {
        guard isAvailable else { return unavailableReason ?? L10n.tr("This model can't use tools", table: .mcp) }
        return enabledServerCount > 0 ? String(enabledServerCount) : L10n.tr("Disabled")
    }

    /// Whether the capability strip draws the Tools capsule: the master switch is on and at least one server has been added (even if all are off),
    /// same rule as the library capsule. Hidden when none has been added (the discovery entry is in Settings > MCP); also not drawn while the panel state is unknown (`.empty`).
    /// realtimeMode non-nil = a realtime model is selected, projected through `RealtimeModelPolicy.capability`:
    /// typing state is dimmed but tappable and shows the reason; not drawn in the voice stage state.
    static func resolve(
        featureEnabled: Bool,
        panelState: McpToolPanelState,
        realtimeMode: RealtimeModelPolicy.ComposerMode? = nil
    ) -> ComposerToolsChipState? {
        guard featureEnabled, panelState.hasServers else { return nil }
        if let realtimeMode {
            let capability = RealtimeModelPolicy.capability(modelKind: .realtime, mode: realtimeMode)
            guard capability.tools == "disabledTappable" else { return nil }
            return ComposerToolsChipState(
                enabledServerCount: panelState.enabledServerCount,
                isAvailable: false,
                unavailableReason: capability.toolsReasonKey.flatMap(RealtimeCapabilityCopy.reason)
            )
        }
        return ComposerToolsChipState(
            enabledServerCount: panelState.enabledServerCount,
            isAvailable: panelState.availability.isAvailable
        )
    }
}

/// A change of the selected model in this conversation (back to a text model, to another realtime model, or realtime cancelled) resets this conversation's typing state to the entry state.
/// Switching conversations alone is not a change: typing state is stored per conversation, so entering another one leaves it alone.
struct RealtimeTypingReset: ViewModifier {
    struct Key: Equatable {
        let conversationID: UUID?
        let selection: RealtimeModelSelection?
    }

    let key: Key
    @Binding var hosts: Set<UUID?>

    func body(content: Content) -> some View {
        content.onChange(of: key) { old, new in
            var next = hosts
            Self.apply(old: old, new: new, hosts: &next)
            if next != hosts { hosts = next }
        }
    }

    static func apply(old: Key, new: Key, hosts: inout Set<UUID?>) {
        // Switching conversations alone is not a change (typing state is stored per conversation)
        guard old.conversationID == new.conversationID, hosts.contains(new.conversationID) else { return }
        let keeps = RealtimeModelPolicy.typingAfterSelectionChange(
            typing: true, before: policySelection(old.selection), after: policySelection(new.selection)
        )
        if !keeps { hosts.remove(new.conversationID) }
    }

    /// Map the selection to the fixture {connectionId, model}: connection = providerID.
    static func policySelection(_ selection: RealtimeModelSelection?) -> RealtimeModelPolicy.PickerSelected? {
        selection.map { RealtimeModelPolicy.PickerSelected(connectionId: $0.providerID.uuidString, model: $0.model) }
    }
}

/// Which composer state applies while a realtime model is selected: the primary key resolves to the voice stage = stage, otherwise (the user switched to typing, generating, or read-only) = typing;
/// nil when no realtime model is selected. voiceAvailable = the page is not read-only (realtime ignores the dictation engine and the text-model-removed banner). ChatView and the input bar use the same rule (`VoiceConversationEntry.primaryAction`).
enum ComposerRealtimeMode {
    static func resolve(
        realtimeSelected: Bool,
        isSending: Bool,
        voiceAvailable: Bool,
        typing: Bool = false
    ) -> RealtimeModelPolicy.ComposerMode? {
        guard realtimeSelected else { return nil }
        let action = VoiceConversationEntry.primaryAction(
            isSending: isSending,
            hasContent: false,
            sendEnabled: false,
            voiceAvailable: voiceAvailable,
            modelProducesText: true,
            realtimeSelected: true,
            realtimeTyping: typing
        )
        return action == .voiceStage ? .stage : .typing
    }
}

/// Map the realtime capability reason key to the localized copy (Voice table; keys are the English source text).
enum RealtimeCapabilityCopy {
    static func reason(_ key: String) -> String? {
        switch key {
        case "voice_realtime_no_attachments":
            L10n.tr("Realtime voice models don't take attachments. Switch to a text model to send them.", table: .voice)
        case "voice_realtime_no_web_search":
            L10n.tr("Realtime voice models can't search the web.", table: .voice)
        case "voice_realtime_no_thinking":
            L10n.tr("Realtime voice models don't support thinking.", table: .voice)
        case "voice_realtime_no_tools":
            L10n.tr("Realtime voice models can't use tools.", table: .voice)
        default:
            nil
        }
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
    /// Realtime text is written into the input field.
    let live: DictationLiveHooks

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
                },
                live: live
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

    /// Same identity as `ChatAttachmentPicker.ImportContext` (built from the partition).
    /// realtimeMode non-nil = a realtime model is selected: the typing state shows the three entries disabled with voice_realtime_no_attachments; the voice stage state does not exist.
    static func resolve(
        provider: Provider?,
        model: AIModel?,
        partitionID: String?,
        realtimeMode: RealtimeModelPolicy.ComposerMode? = nil
    ) -> ComposerAttachmentEntries {
        if let realtimeMode {
            let capability = RealtimeModelPolicy.capability(modelKind: .realtime, mode: realtimeMode)
            guard capability.attachments == "disabledWithReason",
                  let reason = capability.attachmentsReasonKey.flatMap(RealtimeCapabilityCopy.reason) else { return .closed }
            func disabled(_ medium: InputCapabilityCopy.Medium) -> Entry {
                Entry(isEnabled: false, disabledReason: reason, hintsFirstAttach: false, medium: medium)
            }
            return ComposerAttachmentEntries(image: disabled(.image), video: disabled(.video), file: disabled(.file))
        }
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

// MARK: - Body sections
// Each section is its own `View` struct so it renders in its own stack frame: the Debug build of
// `ChatComposerBar.body` overflowed the 1 MB main-thread stack while these were inline.

private func composerHorizontalEdgeFadeMask() -> some View {
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

/// Model removed, voice catalog retry, and compaction rows above the composer.
private struct ChatComposerBannerStack: View {
    let modelRemovedBanner: ChatModelRemovedBanner?
    let realtimeCatalogRetryRow: ChatRealtimeCatalogRetryRow?
    let compactionHintConversationID: UUID?
    let compactingConversationID: UUID?
    let conversationID: UUID?
    let onChooseModel: () -> Void
    let onRetryRealtimeCatalog: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private var isDarkMode: Bool { colorScheme == .dark }

    var body: some View {
        if let modelRemovedBanner {
            modelRemovedBannerView(modelRemovedBanner)
                .transition(.move(edge: .top).combined(with: .opacity))
        }

        if let realtimeCatalogRetryRow {
            realtimeCatalogRetryRowView(realtimeCatalogRetryRow)
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
                .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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
            .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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

    /// Row shown when the conversation model was removed: same compact style as the sync banner, trailing button opens the model picker.
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
                // Official / Free model retired with an enabled successor: switch to it in one tap through the model picker's selection path.
                Button(banner.actionTitle) {
                    appState.selectModel(modelID: successorModelID, providerID: banner.providerID, for: conversationID)
                }
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
                .buttonStyle(.plain)
            } else {
                Button(banner.actionTitle, action: onChooseModel)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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

    /// Voice catalog load failure row: same style as the model removed row, trailing Retry reloads the catalog.
    private func realtimeCatalogRetryRowView(_ row: ChatRealtimeCatalogRetryRow) -> some View {
        let tint = OriveoTheme.Palette.warning
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(row.message)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(row.actionTitle, action: onRetryRealtimeCatalog)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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
}

/// Notes pinned to this chat and related-note suggestions.
private struct ChatComposerNoteContextSection: View {
    let pinnedNoteSummaries: [NoteSummary]
    let visibleRelatedNotes: [NoteRecallEngine.Suggestion]
    let conversationID: UUID?
    @Binding var dismissedRelatedNoteIDs: Set<UUID>

    @Environment(AppState.self) private var appState

    var body: some View {
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
                            .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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
                        .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
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
}

/// Pending attachment thumbnails tray.
private struct ChatComposerAttachmentPreviewRow: View {
    let provider: Provider
    @Binding var pendingAttachments: [Attachment]
    let attachmentAccent: ComposerCapabilityAccent
    let onTapKnowledgeCTA: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool { colorScheme == .dark }

    var body: some View {
        // Truncation CTA gate: only shown when the current provider is OpenAI with a key configured.
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
                            ? { onTapKnowledgeCTA() }
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
        .mask(composerHorizontalEdgeFadeMask())
    }
}

/// Model Options and Tools chips plus the context usage ring.
private struct ChatComposerCapabilityStrip: View {
    let provider: Provider
    let currentModel: AIModel?
    let conversationID: UUID?
    let generationParameterScopeID: UUID
    let modelControlTransportIdentity: String?
    let controlsDisabled: Bool
    let isSendingMessage: Bool
    let isReadOnly: Bool
    @Binding var showsModelControls: Bool
    let modelControlsInitialRoute: ModelControlsRoute?
    @Binding var opensModelPickerAfterControls: Bool
    @Binding var opensConnectionSettingsAfterControls: Bool
    @Binding var opensConnectionWebSearchAfterControls: Bool
    @Binding var opensSearchSettingsAfterControls: Bool
    @Binding var opensTestCapabilitiesAfterControls: Bool
    let onModelControlsDismiss: () -> Void
    @Binding var webEnabled: Bool
    @Binding var reasoningMode: ReasoningMode
    @Binding var reasoningIntentSelection: String?
    let modelBehaviorAccent: ComposerCapabilityAccent
    let hasModelControlSelection: Bool
    let activeCapabilityGlyphs: [String]
    let modelControlSummary: String
    let toolsChip: ComposerToolsChipState?
    let onOpenTools: () -> Void
    let contextUsage: ContextUsageSummary?
    let onOpenContextUsage: () -> Void
    let highlightPulse: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private var isDarkMode: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                capabilityStripContent
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .mask(composerHorizontalEdgeFadeMask())
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pinned at the trailing end, outside the scrolling chips.
            if let contextUsage, ContextUsageRing.isVisible(contextUsage) {
                ContextUsageRing(summary: contextUsage, onTap: onOpenContextUsage)
            }
        }
    }

    private var capabilityStripContent: some View {
        HStack(spacing: 7) {
            // The single entry does not consume model / identity / managed / runtime read-only checks.
            // Without a model it still opens the fallback panel to pick one; writability is decided inside the panel.
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
            .oriveoSheet(isPresented: $showsModelControls, onDismiss: onModelControlsDismiss) {
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
                    },
                    onOpenSearchSettings: {
                        opensSearchSettingsAfterControls = true
                        showsModelControls = false
                    },
                    initialRoute: modelControlsInitialRoute,
                    realtimeSelected: appState.realtimeModelSelection(for: conversationID) != nil
                )
                // The panel owns its detents (height follows content, full height on sub-pages): presentation preferences
                // written outside override the inner ones, so setting them here would silently break the panel's sizing.
                .presentationDragIndicator(.visible)
            }

            // Tools chip (design 01 / 05): the number is enabled, available servers in this chat; at 0 there is no number and no highlight.
            // When the connection cannot send tools it is dimmed but still tappable, opening a panel that explains why (design 04).
            // It also opens while generating (changes apply to the next send, not the current answer).
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
                // When specific capabilities are set, draw their glyphs so the chip says which one changed;
                // only changes without a dedicated glyph (model behavior) fall back to the dot.
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
}
