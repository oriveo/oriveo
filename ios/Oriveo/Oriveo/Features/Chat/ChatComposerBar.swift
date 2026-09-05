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
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsPreview, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                quotePreview
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("\(L10n.tr("Selected content", table: .chat)): \(quote.summaryText)")

            if allowsRemoval, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(removeForeground)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
        .frame(maxHeight: min(420, UIScreen.main.bounds.height * 0.6))
        .background(OriveoTheme.Palette.surface)
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
    let visibleCapabilityKeys: Set<String>
    let capabilityEvidenceIdentity: CapabilityEvidenceRequestIdentity?
    let generationProjection: GenerationParameterEvidenceProjection?
    let capabilityDecision: ChatCapabilityOutboundDecision
    let isSendingMessage: Bool
    var conversationID: UUID? = nil
    let generationParameterScopeID: UUID
    var isReadOnly: Bool = false
    var transparentChrome: Bool = false

    @Binding var composerText: String
    @Binding var pendingAttachments: [Attachment]
    @Binding var pendingQuoteContext: QuoteContext?
    @Binding var reasoningMode: ReasoningMode
    @Binding var reasoningIntentSelection: String?
    @Binding var webEnabled: Bool
    var composerFocused: FocusState<Bool>.Binding

    let onSend: (_ text: String, _ attachments: [Attachment]) -> Void
    let onChooseModel: () -> Void
    let onCancel: () -> Void
    let onShowPhotoPicker: () -> Void
    let onShowCamera: () -> Void
    let onShowFileImporter: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    @State private var highlightPulse = false
    @State private var highlightPulseToken = 0
    @State private var dismissedRelatedNoteIDs: Set<UUID> = []
    @State private var recalledNotes: [NoteRecallEngine.Suggestion] = []
    @State private var noteRecallWorker = NoteRecallWorker()
    @State private var showsModelControls = false
    @State private var opensModelPickerAfterControls = false
    @State private var opensConnectionSettingsAfterControls = false
    @State private var webPreferenceSelection: CapabilityWebPreference = .off

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

    private var attachmentSupport: (image: Bool, video: Bool, nativeFile: Bool, textFileInline: Bool) {
        if provider.kind == .relay,
           let runtime = RelayRuntimeSupport.attachmentSupport(
               for: provider,
               runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
           ) {
            return runtime
        }
        return provider.kind.attachmentSupport
    }

    private var supportsImageAttachment: Bool {
        visibleCapabilityKeys.contains("vision_input")
            && attachmentSupport.image
    }

    private var supportsVideoAttachment: Bool {
        currentModel?.capabilities.contains(.video) == true && attachmentSupport.video
    }

    private var supportsFileAttachment: Bool {
        attachmentSupport.textFileInline || attachmentSupport.nativeFile
    }

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

    /// Complete final-transport + Server-runtime identity used by typed preferences/custom fields.
    private var modelControlTransportIdentity: String? {
        currentModel.flatMap { CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: $0)?.wireValue }
    }

    private var supportsAttachmentEntry: Bool {
        supportsImageAttachment || supportsVideoAttachment || supportsFileAttachment
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
        guard supportedKinds == 1 else { return "plus" }

        if supportsImageAttachment { return "photo" }
        if supportsVideoAttachment { return "video" }
        return "paperclip"
    }

    private var hasDraftHighlight: Bool {
        hasComposerContent && !controlsDisabled
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

    var body: some View {
        let _ = CapabilityEvidenceObservationBridge.shared.contentRevision
        VStack(alignment: .leading, spacing: 10) {
            noteContextSection

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
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .animation(preferredAnimation, value: showsModeControls)
        .animation(preferredAnimation, value: pendingAttachments.isEmpty)
        .animation(preferredAnimation, value: pendingQuoteContext)
        .animation(preferredAnimation, value: reasoningMode)
        .animation(preferredAnimation, value: webEnabled)
        .sensoryFeedback(.selection, trigger: reasoningMode)
        .sensoryFeedback(.selection, trigger: webEnabled)
        .onAppear {
            configureHighlightPulse()
            syncStoredCapabilitySelection()
        }
        .onChange(of: reduceMotion) { _, _ in configureHighlightPulse() }
        .onChange(of: currentModel?.id) { _, _ in syncStoredCapabilitySelection() }
        .onChange(of: conversationID) { _, _ in syncStoredCapabilitySelection() }
        .onChange(of: showsModelControls) { _, isOpen in
            guard !isOpen else { return }
            syncStoredCapabilitySelection()
        }
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
        ScrollView(.horizontal, showsIndicators: false) {
            capabilityStripContent
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .mask(horizontalEdgeFadeMask)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    appState.navigation.openProviderDetail(providerID: provider.id)
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
                    }
                )
                .presentationDragIndicator(.visible)
            }

        }
    }

    private var modelControlSummary: String {
        let web = ModelControlIntentLabel.webText(
            capabilityDecision.webSearchEnabled ? webPreferenceSelection : .off
        )
        let thinking = capabilityDecision.reasoningIntent.map(ModelControlIntentLabel.text)
            ?? L10n.tr("Automatic")
        return "\(L10n.tr("Web Search", table: .chat)): \(web) • \(L10n.tr("Thinking Mode", table: .chat)): \(thinking)"
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewRow: some View {
        let canUseKnowledge = provider.kind == .openAI && !provider.apiKey.isEmpty
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
                            ? { appState.navigation.openSkillEdit() }
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

    private var composerInputRow: some View {
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

            TextField(
                isSendingMessage
                    ? L10n.tr("AI is answering...", table: .chat)
                    : L10n.tr("Type a message...", table: .chat),
                text: $composerText,
                axis: .vertical
            )
            .focused(composerFocused)
            .lineLimit(1...5)
            .disabled(controlsDisabled)
            .font(OriveoTheme.Typography.body)
            .foregroundStyle(controlsDisabled ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary)
            .padding(.vertical, 8)
            .frame(minHeight: 44, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
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

        if totalOptionCount >= 2 {
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
                }
                if supportsVideoAttachment {
                    Button { onShowFileImporter() } label: {
                        Label(L10n.tr("Video"), systemImage: "video")
                    }
                }
                if supportsFileAttachment {
                    Button { onShowFileImporter() } label: {
                        Label(L10n.tr("File"), systemImage: "paperclip")
                    }
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
                        Color.dynamic(light: 0x8C5FF8, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.10)
                    )
                )

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
        .shadow(
            color: emphasized ? accent.shadow.opacity(0.08) : .clear,
            radius: emphasized ? 7 : 0,
            y: emphasized ? 2 : 0
        )
        .opacity(disabled ? 0.52 : 1)
    }

    // MARK: - Action Cluster

    private var composerActionCluster: some View {
        let isPrimed = hasComposerContent && !controlsDisabled

        return Group {
            if isSendingMessage {
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
            } else {
                OriveoCircleIconButton(
                    systemImage: "arrow.up",
                    fill: isPrimed
                        ? AnyShapeStyle(OriveoTheme.Palette.primaryGradient)
                        : AnyShapeStyle(Color.dynamic(light: 0x8C5FF8, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.10)),
                    foreground: isPrimed ? .white : OriveoTheme.Palette.textTertiary,
                    border: isPrimed ? OriveoTheme.Palette.hairline : .clear,
                    shadowColor: isPrimed ? OriveoTheme.Palette.primaryGlow : .clear,
                    size: 40,
                    iconSize: 16,
                    bounceValue: isPrimed
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSend(composerText, pendingAttachments)
                }
                .scaleEffect(isPrimed ? 1 : 0.96)
                .disabled(!isPrimed)
            }
        }
        .animation(preferredAnimation, value: isSendingMessage)
        .animation(.easeInOut(duration: 0.18), value: hasComposerContent)
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
            iconStart: Color.dynamic(light: 0xA5B4FC, dark: 0x818CF8),
            iconEnd: Color.dynamic(light: 0x6366F1, dark: 0x6366F1),
            softFill: Color.dynamic(light: 0xF8FAFC, dark: 0x172136, lightAlpha: 1, darkAlpha: 0.94),
            softBorder: Color.dynamic(light: 0xD5DBE7, dark: 0x94A3B8, lightAlpha: 1, darkAlpha: 0.26),
            shadow: OriveoTheme.Palette.shadow
        )
    }

    private var modelBehaviorAccent: ComposerCapabilityAccent {
        .init(
            tint: Color.dynamic(light: 0x5B4AB8, dark: 0xC4B5FD),
            iconStart: Color.dynamic(light: 0xA78BFA, dark: 0xC4B5FD),
            iconEnd: Color.dynamic(light: 0x6D5BD0, dark: 0x8B5CF6),
            softFill: Color.dynamic(light: 0xF5F3FF, dark: 0x211B36, lightAlpha: 1, darkAlpha: 0.94),
            softBorder: Color.dynamic(light: 0xC4B5FD, dark: 0xA78BFA, lightAlpha: 0.7, darkAlpha: 0.3),
            shadow: Color.dynamic(light: 0x6D5BD0, dark: 0x000000, lightAlpha: 0.15, darkAlpha: 0.22)
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
