import SwiftUI

enum MemoryViewAction: Equatable, Sendable {
    case generateDraft
    case focusEditor
}

enum MemoryHeroStyle: Equatable, Sendable {
    case draftStarter
    case manualStarter
    case activeMemory
}

enum MemoryDetailPanelStyle: Equatable, Sendable {
    case none
}

struct MemoryViewPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case starter
        case editor
    }

    let mode: Mode
    let heroStyle: MemoryHeroStyle
    let detailPanelStyle: MemoryDetailPanelStyle
    let primaryAction: MemoryViewAction?
    let secondaryAction: MemoryViewAction?
    let showsExampleCard: Bool
    let showsSupportCards: Bool

    static func resolve(
        memoryText: String,
        isEditorFocused: Bool,
        hasRecentConversations: Bool
    ) -> Self {
        let trimmedText = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsStarter = trimmedText.isEmpty && !isEditorFocused

        if showsStarter {
            return .init(
                mode: .starter,
                heroStyle: hasRecentConversations ? .draftStarter : .manualStarter,
                detailPanelStyle: .none,
                primaryAction: hasRecentConversations ? .generateDraft : .focusEditor,
                secondaryAction: hasRecentConversations ? .focusEditor : nil,
                showsExampleCard: false,
                showsSupportCards: false
            )
        }

        return .init(
            mode: .editor,
            heroStyle: .activeMemory,
            detailPanelStyle: .none,
            primaryAction: hasRecentConversations ? .generateDraft : nil,
            secondaryAction: nil,
            showsExampleCard: false,
            showsSupportCards: true
        )
    }
}

struct MemoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editText: String = ""
    @State private var antiForgetEnabled: Bool = false
    @State private var editRevision: Int = 0
    @State private var isGeneratingDraft: Bool = false
    @State private var pendingGeneratedDraft: String? = nil
    @State private var showDraftConflictDialog: Bool = false
    @State private var activeDraftRequestID: UUID? = nil
    @State private var hasRecentConversations: Bool = false
    @State private var showSaveSuccessAlert: Bool = false
    @State private var heroAppeared: Bool = false
    @State private var savePulse: Bool = false
    @State private var draftErrorTitle: String = ""
    @State private var draftErrorMessage: String = ""
    @State private var showDraftErrorAlert: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private var hasChanges: Bool {
        let prefs = appState.preferences
        return editText != prefs.memoryText
            || antiForgetEnabled != prefs.memoryAntiForgetEnabled
    }

    private var trimmedText: String {
        editText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presentation: MemoryViewPresentation {
        MemoryViewPresentation.resolve(
            memoryText: editText,
            isEditorFocused: isTextFieldFocused,
            hasRecentConversations: hasRecentConversations
        )
    }

    private var approxTokens: Int? {
        guard !editText.isEmpty else { return nil }
        return Int(ceil(Double(editText.count) * 0.35))
    }

    private var heroTone: StatusTone {
        switch presentation.heroStyle {
        case .draftStarter:  return .primary
        case .manualStarter: return .primary
        case .activeMemory:  return .success
        }
    }

    private var heroBadgeTitle: String {
        switch presentation.heroStyle {
        case .draftStarter:  return L10n.tr("Auto")
        case .manualStarter: return L10n.tr("Memory")
        case .activeMemory:  return L10n.tr("Ready")
        }
    }

    private var overviewBadges: [MemoryOverviewBadge] {
        var badges: [MemoryOverviewBadge] = []

        if appState.memoryUsageCount > 0 {
            badges.append(
                .init(
                    text: String(format: L10n.tr("Used in %d conversations", table: .settings), appState.memoryUsageCount),
                    systemImage: "checkmark.circle.fill",
                    foreground: OriveoTheme.Palette.success,
                    fill: OriveoTheme.Palette.successSoft
                )
            )
        }

        if antiForgetEnabled && !trimmedText.isEmpty {
            badges.append(
                .init(
                    text: L10n.tr("Anti-forget mode", table: .settings),
                    systemImage: "bookmark.fill",
                    foreground: OriveoTheme.Palette.primary,
                    fill: OriveoTheme.Palette.primarySoft
                )
            )
        }

        return badges
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                heroSection
                    .opacity(heroAppeared ? 1 : 0)
                    .offset(y: heroAppeared ? 0 : 12)
                    .padding(.top, presentation.mode == .starter ? 12 : 0)

                editorCard

                if presentation.showsSupportCards {
                    advancedSection
                        .transition(.opacity)
                    privacyFootnote
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 64)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: presentation.mode)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(screenBackdrop)
        .safeAreaInset(edge: .top) { toolbar }
        .safeAreaInset(edge: .bottom) {
            if hasChanges {
                saveBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: hasChanges)
        .onAppear {
            loadCurrentState()
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85).delay(0.04)) {
                heroAppeared = true
            }
        }
        .onDisappear { activeDraftRequestID = nil }
        .alert(L10n.tr("Generated draft is ready", table: .settings), isPresented: $showDraftConflictDialog) {
            Button(L10n.tr("Apply draft", table: .settings)) {
                if let pendingGeneratedDraft {
                    editText = pendingGeneratedDraft
                    editRevision += 1
                }
                self.pendingGeneratedDraft = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingGeneratedDraft = nil
            }
        } message: {
            Text(L10n.tr("You've edited the current text. Apply the generated draft and replace current content?", table: .settings))
        }
        .alert(L10n.tr("Memory saved", table: .settings), isPresented: $showSaveSuccessAlert) {
            Button("OK", role: .cancel) { }
        }
        .alert(draftErrorTitle, isPresented: $showDraftErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(draftErrorMessage)
        }
        .task { await computeHasRecentConversations() }
    }

    // MARK: - Backdrop (page + hero aurora)

    private var screenBackdrop: some View {
        ZStack(alignment: .top) {
            OriveoScreenBackground()

            RadialGradient(
                colors: [
                    OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    OriveoTheme.Palette.primary.opacity(0)
                ],
                center: .center,
                startRadius: 0,
                endRadius: 240
            )
            .frame(width: 520, height: 520)
            .offset(y: 40)
            .blur(radius: 14)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            Button {
                appState.pop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 36, height: 36)
                    .oriveoRoundedSurface(
                        fill: OriveoTheme.Palette.surfaceChrome,
                        border: OriveoTheme.Palette.borderStrong,
                        shadow: .soft
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L10n.tr("Memory"))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer()

            Color.clear
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
        }
    }


    private var heroSection: some View {
        VStack(spacing: 18) {
            heroOrbWithRings

            heroChip
                .padding(.top, 4)

            VStack(spacing: 8) {
                Text(overviewTitle)
                    .font(OriveoTheme.Typography.hero)
                    .tracking(-0.4)
                    .lineSpacing(2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(overviewDescription)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 8)

            if !overviewBadges.isEmpty {
                badgesFlow(overviewBadges)
                    .padding(.top, 4)
            }

            if let primaryAction = presentation.primaryAction {
                VStack(spacing: 8) {
                    actionButton(for: primaryAction)
                        .frame(maxWidth: 340)

                    if let secondaryAction = presentation.secondaryAction {
                        secondaryActionLink(for: secondaryAction)
                    }
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var heroChip: some View {
        HStack(spacing: 6) {
            Image(systemName: heroBadgeIcon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(heroTone.foreground)

            Text(heroBadgeTitle)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(heroTone.foreground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(heroTone.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(heroTone.foreground.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var heroOrbWithRings: some View {
        ZStack {
            Circle()
                .stroke(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.10 : 0.05), lineWidth: 1)
                .frame(width: 168, height: 168)

            Circle()
                .stroke(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 1)
                .frame(width: 132, height: 132)

            heroOrb
        }
        .frame(width: 168, height: 168)
    }

    private var heroBadgeIcon: String {
        switch presentation.heroStyle {
        case .draftStarter:  return "sparkles"
        case .manualStarter: return "square.and.pencil"
        case .activeMemory:  return "checkmark"
        }
    }

    private var heroOrb: some View {
        ZStack {
            Circle()
                .fill(OriveoTheme.Palette.primary)
                .frame(width: 96, height: 96)
                .shadow(color: OriveoTheme.Palette.primaryGlow, radius: colorScheme == .dark ? 28 : 18, y: 12)
                .shadow(color: OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.38 : 0.22), radius: 8, y: 2)
                .shadow(color: OriveoTheme.Palette.shadow.opacity(0.12), radius: 1.5, y: 1)
                .opacity(0)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: 0xB89BFF),
                            Color(hex: 0x8347F5),
                            Color(hex: 0x5A2BB0)
                        ],
                        center: .init(x: 0.32, y: 0.28),
                        startRadius: 4,
                        endRadius: 64
                    )
                )
                .frame(width: 96, height: 96)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.42),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .frame(width: 96, height: 96)

            Circle()
                .trim(from: 0, to: 0.32)
                .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                .frame(width: 78, height: 78)
                .rotationEffect(.degrees(-115))
                .blur(radius: 1.2)

            Image(systemName: "brain")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color.white.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 4, y: 2)
        }
        .frame(width: 96, height: 96)
        .background(
            Circle()
                .fill(OriveoTheme.Palette.primary)
                .frame(width: 96, height: 96)
                .shadow(color: OriveoTheme.Palette.primaryGlow, radius: colorScheme == .dark ? 32 : 20, y: 14)
                .shadow(color: OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.34 : 0.22), radius: 6, y: 2)
                .shadow(color: OriveoTheme.Palette.shadow.opacity(0.16), radius: 1, y: 1)
                .opacity(0.001)
        )
        .scaleEffect(heroAppeared ? 1 : 0.86)
    }

    @ViewBuilder
    private func actionButton(for action: MemoryViewAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            Group {
                if action == .generateDraft && isGeneratingDraft {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    HStack(spacing: 8) {
                        if let icon = actionIcon(for: action) {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(actionTitle(for: action))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
        }
        .buttonStyle(OriveoPrimaryButtonStyle())
        .disabled(action == .generateDraft && isGeneratingDraft)
    }

    @ViewBuilder
    private func secondaryActionLink(for action: MemoryViewAction) -> some View {
        Button {
            handleAction(action)
        } label: {
            HStack(spacing: 6) {
                Text(actionTitle(for: action))
                    .font(OriveoTheme.Typography.body.weight(.medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(OriveoTheme.Palette.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }


    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorHeader

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            OriveoTheme.Palette.border.opacity(0.0),
                            OriveoTheme.Palette.border,
                            OriveoTheme.Palette.border.opacity(0.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $editText)
                    .focused($isTextFieldFocused)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200, maxHeight: 320)
                    .onChange(of: editText) { _, newValue in
                        if newValue.count > 2000 {
                            editText = String(newValue.prefix(2000))
                        }
                        editRevision += 1
                    }

                if editText.isEmpty {
                    Text(L10n.tr("e.g.: I'm a backend engineer, mainly using Go. Keep replies concise, in Chinese, give code not long explanations.", table: .settings))
                        .font(OriveoTheme.Typography.body.italic())
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }

            if let approxTokens {
                HStack(spacing: 6) {
                    Image(systemName: "atom")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    Text("\(approxTokens) tokens")
                        .font(OriveoTheme.Typography.footnote.monospacedDigit())
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, approxTokens == nil ? 18 : 14)
        .background(premiumCardBackground(focused: isTextFieldFocused, tone: .primary))
        .overlay(premiumCardShine())
        .overlay(focusGlowRing(active: isTextFieldFocused))
        .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous))
        .shadow(
            color: isTextFieldFocused
                ? OriveoTheme.Palette.primaryGlow
                : OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.45 : 0.10),
            radius: isTextFieldFocused ? 24 : (colorScheme == .dark ? 18 : 12),
            y: isTextFieldFocused ? 12 : 6
        )
        .shadow(
            color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.30 : 0.06),
            radius: 1.5,
            y: 1
        )
        .scaleEffect(isTextFieldFocused ? 1.005 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: isTextFieldFocused)
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.primarySoft,
                                OriveoTheme.Palette.primarySoft.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(OriveoTheme.Palette.primary.opacity(0.16), lineWidth: 0.5)
                    )

                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
            }

            Text(editorSectionTitle)
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer(minLength: 8)

            Text("\(editText.count) / 2,000")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(
                    editText.count > 1900
                        ? OriveoTheme.Palette.warning
                        : OriveoTheme.Palette.textSecondary
                )
                .contentTransition(.numericText())
        }
    }

    // MARK: - Advanced (premium row group)

    private var advancedSection: some View {
        antiForgetRow
            .background(premiumCardBackground(focused: false, tone: antiForgetEnabled ? .primary : .neutral))
            .overlay(premiumCardShine())
            .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous))
            .shadow(
                color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.40 : 0.08),
                radius: colorScheme == .dark ? 14 : 10,
                y: 4
            )
            .shadow(
                color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.24 : 0.04),
                radius: 1.5,
                y: 1
            )
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.85), value: antiForgetEnabled)
    }

    private var antiForgetRow: some View {
        HStack(alignment: .center, spacing: 14) {
            antiForgetIcon
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Long conversation anti-forgetting", table: .settings))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                Text(L10n.tr("After 10 rounds of conversation, automatically append a summary reminder at the end of messages.", table: .settings))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $antiForgetEnabled)
                .labelsHidden()
                .tint(OriveoTheme.Palette.primary)
                .onChange(of: antiForgetEnabled) { _, _ in
                    editRevision += 1
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var antiForgetIcon: some View {
        ZStack {
            if antiForgetEnabled {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x9B6BFF),
                                Color(hex: 0x7238E5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 0.6)
                    )
                    .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 8, y: 4)
                    .shadow(color: OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.30 : 0.18), radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(OriveoTheme.Palette.border, lineWidth: 0.5)
                    )
            }

            Image(systemName: "bookmark.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(antiForgetEnabled ? Color.white : OriveoTheme.Palette.textSecondary)
                .shadow(color: antiForgetEnabled ? Color.black.opacity(0.18) : .clear, radius: 2, y: 1)
        }
    }

    // MARK: - Footnotes

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.warningSoft,
                                OriveoTheme.Palette.warningSoft.opacity(0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(OriveoTheme.Palette.warning.opacity(0.22), lineWidth: 0.5)
                    )

                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.warning)
            }

            Text(L10n.tr("Memory content is sent with every AI request to your chosen provider. Do not enter passwords or other sensitive information.", table: .settings))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Save bar (premium with pulse dot)

    private var saveBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.clear,
                    OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.18 : 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(OriveoTheme.Palette.primary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(savePulse ? 1.6 : 1)
                        .opacity(savePulse ? 0 : 0.45)

                    Circle()
                        .fill(OriveoTheme.Palette.primary)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Unsaved changes", table: .settings))
                        .font(OriveoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(saveBarSubtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(L10n.tr("Save")) {
                    saveMemory()
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
                .frame(maxWidth: 132)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(OriveoTheme.Palette.border)
                    .frame(height: 0.5)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                savePulse = true
            }
        }
        .onDisappear { savePulse = false }
    }

    private var saveBarSubtitle: String {
        var line = "\(editText.count) / 2,000 " + L10n.tr("characters", table: .settings)
        if let approxTokens {
            line += " • \(approxTokens) tokens"
        }
        return line
    }

    // MARK: - Premium card primitives

    @ViewBuilder
    private func premiumCardBackground(focused: Bool, tone: StatusTone) -> some View {
        let baseShape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)

        baseShape
            .fill(OriveoTheme.Palette.surfaceElevated)
            .overlay(
                baseShape
                    .fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.cardHighlight,
                                Color.clear,
                                tone == .primary
                                    ? OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
                                    : Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                baseShape
                    .strokeBorder(
                        focused
                            ? OriveoTheme.Palette.primary.opacity(0.32)
                            : OriveoTheme.Palette.border,
                        lineWidth: focused ? 1 : 0.5
                    )
            )
    }

    @ViewBuilder
    private func premiumCardShine() -> some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        OriveoTheme.Palette.hairline,
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.black, Color.clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.45)
                )
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func focusGlowRing(active: Bool) -> some View {
        if active {
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
                .stroke(OriveoTheme.Palette.primary.opacity(0.18), lineWidth: 6)
                .blur(radius: 6)
                .padding(-3)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Badges flow

    @ViewBuilder
    private func badgesFlow(_ badges: [MemoryOverviewBadge]) -> some View {
        ViewThatFits {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    MemoryOverviewBadgeView(badge: badge)
                }
            }

            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    MemoryOverviewBadgeView(badge: badge)
                }
            }
        }
    }

    // MARK: - Copy

    private var overviewTitle: String {
        switch presentation.mode {
        case .starter:
            return L10n.tr("Let AI know you from the first message", table: .settings)
        case .editor:
            return L10n.tr("Memory")
        }
    }

    private var overviewDescription: String {
        switch presentation.mode {
        case .starter:
            return L10n.tr("Write your background and preferences. AI will automatically know this in every conversation — no need to repeat yourself.", table: .settings)
        case .editor:
            return L10n.tr("Tell AI about yourself. It will automatically know this at the start of every conversation.", table: .settings)
        }
    }

    private var editorSectionTitle: String {
        switch presentation.mode {
        case .starter:
            return L10n.tr("Write manually", table: .settings)
        case .editor:
            return L10n.tr("Memory")
        }
    }

    private func actionTitle(for action: MemoryViewAction) -> String {
        switch action {
        case .generateDraft:
            return L10n.tr("Generate draft from recent chats", table: .settings)
        case .focusEditor:
            return L10n.tr("Write manually", table: .settings)
        }
    }

    private func actionIcon(for action: MemoryViewAction) -> String? {
        switch action {
        case .generateDraft:
            return isGeneratingDraft ? nil : "sparkles"
        case .focusEditor:
            return "square.and.pencil"
        }
    }

    private func handleAction(_ action: MemoryViewAction) {
        switch action {
        case .generateDraft:
            generateDraft()
        case .focusEditor:
            isTextFieldFocused = true
        }
    }

    // MARK: - State / IO

    private func loadCurrentState() {
        let prefs = appState.preferences
        editText = prefs.memoryText
        antiForgetEnabled = prefs.memoryAntiForgetEnabled
        editRevision = 0
    }

    private func computeHasRecentConversations() async {
        let conversations = appState.conversations
        let result = conversations.contains(where: { $0.displayMessageCount > 0 })
        await MainActor.run { hasRecentConversations = result }
    }

    private func saveMemory() {
        let finalAntiForgetEnabled = trimmedText.isEmpty ? false : antiForgetEnabled
        let finalAntiForgetText = finalAntiForgetEnabled ? editText : ""

        appState.saveMemory(
            text: editText,
            antiForgetEnabled: finalAntiForgetEnabled,
            antiForgetText: finalAntiForgetText
        )
        isTextFieldFocused = false
        showSaveSuccessAlert = true
        editRevision = 0
    }

    private func generateDraft() {
        let requestID = UUID()
        let baselineRevision = editRevision
        let baselineText = editText
        pendingGeneratedDraft = nil
        activeDraftRequestID = requestID

        let candidates = appState.providers
            .filter { !$0.apiKey.isEmpty }
            .compactMap { provider -> DraftCandidate? in
                guard let model = provider.defaultModel ?? provider.models.first else { return nil }
                return DraftCandidate(provider: provider, model: model)
            }

        guard !candidates.isEmpty else {
            let hasAnyKey = appState.providers.contains { !$0.apiKey.isEmpty }
            if hasAnyKey {
                presentDraftError(
                    title: L10n.tr("No model available", table: .settings),
                    message: L10n.tr("This provider has no models configured. Add at least one model first.", table: .settings)
                )
            } else {
                presentDraftError(
                    title: L10n.tr("No provider configured", table: .settings),
                    message: L10n.tr("Add a provider with an API key first, then come back to generate a draft.", table: .settings)
                )
            }
            return
        }

        let candidateIDs = recentConversationIDsForDraft(limit: 5)
        guard !candidateIDs.isEmpty else {
            presentDraftError(
                title: L10n.tr("Not enough conversation content", table: .settings),
                message: L10n.tr("Have a few chats first, then come back to generate a draft from them.", table: .settings)
            )
            return
        }

        isGeneratingDraft = true

        let uid = appState.sessionPartitionUID
        let bridge = appState.conversationRuntimeBridge

        Task {
            defer { isGeneratingDraft = false }

            let hydrated: [Conversation]
            do {
                hydrated = try await Task.detached(priority: .userInitiated) {
                    try bridge.fetchConversationProjections(
                        ids: candidateIDs,
                        uid: uid,
                        hydrateFilePayloads: false
                    )
                }.value
            } catch {
                #if DEBUG
                AppLog.error(error, module: "Memory", context: ["op": "generateDraft.hydrate"])
                #endif
                guard activeDraftRequestID == requestID else { return }
                presentDraftError(
                    title: L10n.tr("Could not load recent conversations", table: .settings),
                    message: L10n.tr("Please try again later or write manually.", table: .settings)
                )
                return
            }

            guard activeDraftRequestID == requestID else { return }

            let excerpts = Self.buildExcerpts(from: hydrated)
            guard !excerpts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentDraftError(
                    title: L10n.tr("Not enough conversation content", table: .settings),
                    message: L10n.tr("Have a few chats first, then come back to generate a draft from them.", table: .settings)
                )
                return
            }

            let prompt = """
            Based on the following conversation excerpts, write a concise personal profile in the same language the user is using (under 400 words).
            Include: their role/expertise, current projects or tech stack, preferred response style and language.
            Only include information clearly evident from the conversations. Do not invent or assume.
            Write in first person, as if the user is describing themselves.

            Conversation excerpts:
            \(excerpts)
            """

            var lastError: Error?
            var attempts = 0
            for candidate in candidates {
                guard activeDraftRequestID == requestID else { return }
                attempts += 1

                do {
                    let draftMessage = ChatMessage(
                        id: UUID(),
                        role: .user,
                        text: prompt,
                        providerKind: candidate.provider.kind,
                        providerName: candidate.provider.displayName,
                        modelName: candidate.model.name,
                        state: .delivered
                    )

                    guard let service = Self.makeService(for: candidate.provider.kind) else {
                        lastError = ProviderServiceError.invalidConfiguration(
                            detail: "Provider kind \(candidate.provider.kind.rawValue) cannot generate memory drafts through BYOK provider services."
                        )
                        continue
                    }
                    let baseURL = ProviderSetupCatalog.current()
                        .usesConfigurableBaseURL(candidate.provider.kind)
                        ? candidate.provider.baseURLText
                        : nil

                    let result = try await service.sendMessage(
                        apiKey: candidate.provider.apiKey,
                        modelID: candidate.model.id,
                        messages: [draftMessage],
                        baseURL: baseURL
                    )

                    guard activeDraftRequestID == requestID else { return }

                    let draft = String(result.text.prefix(2000))
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if draft.isEmpty {
                        lastError = ProviderServiceError.emptyResponse
                        #if DEBUG
                        AppLog.info(
                            "Draft generation returned an empty response, falling back to the next candidate",
                            module: "Memory",
                            context: ["model": candidate.model.name]
                        )
                        #endif
                        continue
                    }

                    let userEditedSinceStart = editRevision != baselineRevision || editText != baselineText
                    if !userEditedSinceStart {
                        editText = draft
                        editRevision += 1
                    } else {
                        pendingGeneratedDraft = draft
                        showDraftConflictDialog = true
                    }
                    return
                } catch {
                    #if DEBUG
                    AppLog.error(
                        error,
                        module: "Memory",
                        context: ["model": candidate.model.name, "op": "generateDraft"]
                    )
                    #endif
                    lastError = error
                    continue
                }
            }

            guard activeDraftRequestID == requestID else { return }
            let aggregated = aggregateDraftError(attempts: attempts, lastError: lastError)
            presentDraftError(title: aggregated.title, message: aggregated.message)
        }
    }

    private func aggregateDraftError(attempts: Int, lastError: Error?) -> (title: String, message: String) {
        if attempts <= 1 {
            if let psError = lastError as? ProviderServiceError {
                return (psError.title, psError.message)
            }
            return (
                L10n.tr("Generation failed, please write manually", table: .settings),
                lastError?.localizedDescription ?? L10n.tr("Please try again later or write manually.", table: .settings)
            )
        }

        let detail: String
        if let psError = lastError as? ProviderServiceError {
            detail = psError.message
        } else {
            detail = lastError?.localizedDescription ?? ""
        }
        let message: String
        if detail.isEmpty {
            message = String(format: L10n.tr("Tried %d providers, all failed.", table: .settings), attempts)
        } else {
            message = String(format: L10n.tr("Tried %d providers, all failed. Last error: %@", table: .settings), attempts, detail)
        }
        return (L10n.tr("Generation failed, please write manually", table: .settings), message)
    }

    private func recentConversationIDsForDraft(limit: Int) -> [UUID] {
        appState.conversations
            .filter { $0.displayMessageCount > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map(\.id)
    }

    @MainActor
    private func presentDraftError(title: String, message: String) {
        draftErrorTitle = title
        draftErrorMessage = message
        showDraftErrorAlert = true
    }

    private static func buildExcerpts(from conversations: [Conversation]) -> String {
        conversations
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { conv in
                String(
                    conv.messages
                        .filter { $0.role == .user || $0.role == .assistant }
                        .map { "\($0.role.rawValue): \($0.text)" }
                        .joined(separator: "\n")
                        .prefix(500)
                )
            }
            .joined(separator: "\n---\n")
    }

    private static func makeService(for kind: ProviderKind) -> ProviderServiceProtocol? {
        switch kind {
        case .openRouter: return OpenRouterService()
        case .openAI: return OpenAIService()
        case .deepseek: return DeepSeekService()
        case .grok: return GrokService()
        case .anthropic: return AnthropicService()
        case .gemini: return GeminiService()
        case .groq: return GroqService()
        case .together: return TogetherService()
        case .fireworks: return FireworksService()
        case .miniMax: return MiniMaxService()
        case .zhipu: return ZhipuService()
        case .qwen: return QwenService()
        case .moonshot: return MoonshotService()
        case .mistral: return MistralService()
        case .siliconFlow: return SiliconFlowService()
        case .relay: return OpenAIService()
        }
    }
}

private struct DraftCandidate {
    let provider: Provider
    let model: AIModel
}

private struct MemoryOverviewBadge {
    let text: String
    let systemImage: String
    let foreground: Color
    let fill: Color
}

private struct MemoryOverviewBadgeView: View {
    let badge: MemoryOverviewBadge

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.systemImage)
                .font(.system(size: 12, weight: .semibold))

            Text(badge.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(badge.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(badge.fill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(badge.foreground.opacity(0.16), lineWidth: 0.5)
        )
    }
}
