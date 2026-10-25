import SwiftUI

struct ChatToolbar: View {
    let projection: ChatScreenProjection
    let provider: Provider
    let currentModel: AIModel?
    /// The model name stored on the conversation, shown while its connection is temporarily unavailable and the model cannot be resolved.
    var pendingModelName: String? = nil
    let isSendingMessage: Bool
    var transparentChrome: Bool = false
    @Binding var showModelSwitcher: Bool
    @Binding var showDeleteConfirmation: Bool
    /// Opens the chat settings sheet; `true` = focus the instructions editor (badge tap).
    var onOpenSettings: (_ focusEditor: Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(\.windowNavigation) private var windowNavigation
    /// This window's navigation state (one per window); a host without one injected (tests) falls back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }
    /// The system runs the navigation bar vertically along a side (the Duo cover screen, the detail column of the unfolded Duo held sideways): back / new chat / memory / export / the overflow menu
    /// go into the system's vertical bar and only the model capsule and the cost stay here. See `chatNavigationChrome`.
    @Environment(\.chatUsesVerticalBar) private var usesVerticalBar
    @State private var showMemoryPopover = false
    @State private var pendingExport: ChatExportItem?

    var body: some View {
        let costTotalsText = projection.costTotalsText
        HStack(spacing: OriveoTheme.Spacing.sm) {
            // No back button in the two-column layout: there is nowhere to go back to, because
            // the sidebar stays on screen (the same rule the system split view follows).
            if !navigation.isRegularWidth && !usesVerticalBar {
                OriveoBackButton { appState.pop() }
                    .accessibilityIdentifier("chat_back_button")
                    // Keeps the old 36pt slot so the model picker does not move; the 44pt target
                    // overflows it on every side, so the tappable area does not shrink
                    .frame(width: 36, height: 36)
            }

            if let skillId = projection.skillID,
               let skill = appState.skillManager.skill(by: skillId) {
                Text(skill.icon)
                    .font(.title3)
                    .padding(.leading, 2)
            }

            Button {
                showModelSwitcher = true
            } label: {
                if usesVerticalBar {
                    verticalBarModelLabel
                } else {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        ConnectionAvatarIcon(provider: provider, kind: provider.kind, relayKind: provider.relayKind, size: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentModel?.name ?? pendingModelName ?? L10n.tr("Choose Model"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)

                            if let currentModel {
                                LocalModelRuntimeLabel(model: currentModel)
                            }

                            HStack(spacing: 4) {
                                Text(provider.displayName)
                                    .font(OriveoTheme.Typography.footnote)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                    .lineLimit(1)

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                        }
                    }
                    .padding(.leading, 2)
                    .contentShape(.rect)
                }
            }
            .buttonStyle(ChatToolbarPressableStyle())

            if hasInstructions && !usesVerticalBar {
                instructionsBadge
            }

            Spacer(minLength: 0)

            if !costTotalsText.isEmpty {
                ChatCostPill(text: costTotalsText)
            }

            if showMemoryIndicator && !usesVerticalBar {
                Button {
                    showMemoryPopover = true
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(ChatToolbarPressableStyle())
                .popover(isPresented: $showMemoryPopover) {
                    memoryPopoverContent
                }
                .accessibilityLabel(L10n.tr("This conversation is using memory", table: .chat))
                .accessibilityHint(L10n.tr("View/edit full memory", table: .chat))
            }

            if !usesVerticalBar {
                Menu {
                    Button {
                        appState.startNewChat()
                    } label: {
                        Label(L10n.tr("New Chat"), systemImage: "plus")
                    }

                    Button {
                        presentExport()
                    } label: {
                        Label(L10n.tr("Export Conversation", table: .chat), systemImage: "square.and.arrow.up")
                    }
                    .disabled(!projection.exportsEnabled)

                    if !costTotalsText.isEmpty {
                        Section {
                            Text(costTotalsText)
                        }
                    }

                    // Conversation settings (instructions and the use-memory switch live in the sheet)
                    conversationSettingsButton

                    if projection.activeConversationID != nil {
                        Section {
                            deleteButton
                        }
                    }
                } label: {
                    ChatToolbarIconCapsule(systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(ChatToolbarPressableStyle())
            }
        }
        // Without vertical bars the navigation bar is hidden and this produces no items, so nothing changes there
        .toolbar { verticalBarItems }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, OriveoTheme.Spacing.md)
        .padding(.bottom, OriveoTheme.Spacing.sm)
        .background {
            if !transparentChrome {
                // Extends sideways too: the Duo cover screen and the unfolded Duo held sideways have an 84pt vertical status bar safe area on the right, and filling only the top would leave a strip of another colour there.
                LinearGradient(
                    stops: [
                        .init(color: OriveoTheme.Palette.background, location: 0),
                        .init(color: OriveoTheme.Palette.background, location: 0.5),
                        .init(color: OriveoTheme.Palette.background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
            }
        }
        .sheet(item: $pendingExport) { item in
            ChatExportShareSheet(item: item.url) { completed in
                pendingExport = nil
                if completed {
                    ToastManager.shared.show(L10n.tr("Conversation exported as Markdown.", table: .chat))
                }
            }
        }
    }

    // MARK: - Vertical bars (Duo)

    /// The model capsule with vertical bars: model name · provider on one line, shorter than the two-line version, giving the height back to the cover screen's reading area.
    private var verticalBarModelLabel: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            ConnectionAvatarIcon(provider: provider, kind: provider.kind, relayKind: provider.relayKind, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(currentModel?.name ?? pendingModelName ?? L10n.tr("Choose Model"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Text(verbatim: "·")
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)

                    Text(provider.displayName)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }

                // The runtime / loading state is a notice people need to see; it is not hidden to save a line
                if let currentModel {
                    LocalModelRuntimeLabel(model: currentModel)
                }
            }
        }
        .padding(.leading, 2)
        .contentShape(.rect)
    }

    /// System toolbar items for the vertical bar. Each has both an icon and a title; the system leaves title-only or custom-view items out of a vertical bar.
    /// Ordered per the HIG: back first, then the main actions; when space runs out Export goes first and New Chat last;
    /// the Use Memory toggle and Delete go into the system overflow menu rather than a custom "…".
    @ToolbarContentBuilder
    private var verticalBarItems: some ToolbarContent {
        if usesVerticalBar {
            // ToolbarOverflowMenu and visibilityPriority are iOS 27 API; vertical bars only appear from 27.1
            if #available(iOS 27.0, *) {
                if !navigation.isRegularWidth {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            appState.pop()
                        } label: {
                            Label(L10n.tr("Back"), systemImage: "chevron.backward")
                        }
                        .accessibilityIdentifier("chat_back_button")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.startNewChat()
                    } label: {
                        Label(L10n.tr("New Chat"), systemImage: "plus")
                    }
                }
                .visibilityPriority(.high)

                if showMemoryIndicator {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showMemoryPopover = true
                        } label: {
                            Label(L10n.tr("Memory"), systemImage: "brain")
                        }
                        .popover(isPresented: $showMemoryPopover) {
                            memoryPopoverContent
                        }
                        .accessibilityLabel(L10n.tr("This conversation is using memory", table: .chat))
                        .accessibilityHint(L10n.tr("View/edit full memory", table: .chat))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentExport()
                    } label: {
                        Label(L10n.tr("Export Conversation", table: .chat), systemImage: "square.and.arrow.up")
                    }
                    .disabled(!projection.exportsEnabled)
                }
                .visibilityPriority(.low)

                if hasInstructions {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpenSettings(true)
                        } label: {
                            Label(L10n.tr("conversation_instructions_badge", table: .chat), systemImage: "text.quote")
                        }
                        .accessibilityLabel(L10n.tr("conversation_instructions_badge_a11y", table: .chat))
                    }
                }

                ToolbarOverflowMenu {
                    conversationSettingsButton
                    if projection.activeConversationID != nil {
                        deleteButton
                    }
                }
            }
        }
    }

    private var hasInstructions: Bool {
        !ConversationSettingsLogic.currentInstructions(
            conversationID: projection.activeConversationID, appState: appState
        ).isEmpty
    }

    private var conversationSettingsButton: some View {
        Button {
            onOpenSettings(false)
        } label: {
            Label(L10n.tr("conversation_settings_title", table: .chat), systemImage: "slider.horizontal.3")
        }
    }

    /// Capsule next to the model name when this chat has instructions; tap opens settings focused on the editor.
    private var instructionsBadge: some View {
        Button {
            onOpenSettings(true)
        } label: {
            Text(L10n.tr("conversation_instructions_badge", table: .chat))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OriveoTheme.Palette.primary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(ChatToolbarPressableStyle())
        .fixedSize()
        .accessibilityLabel(L10n.tr("conversation_instructions_badge_a11y", table: .chat))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label(L10n.tr("Delete Conversation", table: .chat), systemImage: "trash")
        }
    }

    // MARK: - Export

    private func presentExport() {
        guard let summary = projection.summary,
              let url = try? ChatExport.writeMarkdownTempFile(
                summary: summary,
                messages: projection.messages
              )
        else {
            ToastManager.shared.show(L10n.tr("Export Failed"))
            return
        }
        pendingExport = ChatExportItem(url: url)
    }

    // MARK: - Memory

    /// The memory indicator follows active semantic items, not the legacy memoryText field.
    private var showMemoryIndicator: Bool {
        MemoryUsedPresentation.showsToolbarIndicator(
            useMemory: projection.useMemory, items: appState.memoryItemsCache.items
        )
    }

    private var memoryPopoverContent: some View {
        let previewText = MemoryUsedPresentation.toolbarPreview(items: appState.memoryItemsCache.items)

        return VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(OriveoTheme.Palette.primaryGradient)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Circle()
                                .stroke(OriveoTheme.Palette.hairline, lineWidth: 1)
                        )
                        .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 18, y: 10)

                    Image(systemName: "brain")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("This conversation is using memory", table: .chat))
                        .font(OriveoTheme.Typography.title2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(L10n.tr("Memory"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(OriveoTheme.Palette.primarySoft)
                        )
                }

                Spacer(minLength: 0)

                OriveoCloseButton(accessibilityLabel: L10n.tr("Dismiss")) {
                    showMemoryPopover = false
                }
                .padding(.trailing, -OriveoBackButton.edgeInset)
                .padding(.vertical, -7)
            }
            .padding(OriveoTheme.Spacing.lg)
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceChrome,
                border: OriveoTheme.Palette.borderStrong,
                shadow: .soft
            )

            MemoryPopoverPreviewCard(previewText: previewText)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                Button {
                    showMemoryPopover = false
                    appState.openMemory()
                } label: {
                    MemoryPopoverActionLabel(
                        title: L10n.tr("View/edit full memory", table: .chat),
                        systemImage: "square.and.pencil",
                        foreground: .white,
                        iconBackground: .white.opacity(0.16),
                        iconForeground: .white
                    )
                }
                .buttonStyle(MemoryPopoverCardButtonStyle(tone: .primary))

                Button {
                    if let conversationID = projection.activeConversationID {
                        appState.setConversationUseMemory(conversationID, useMemory: false)
                    }
                    showMemoryPopover = false
                } label: {
                    MemoryPopoverActionLabel(
                        title: L10n.tr("Don't use memory for this conversation", table: .chat),
                        systemImage: "eye.slash",
                        foreground: OriveoTheme.Palette.danger,
                        iconBackground: OriveoTheme.Palette.danger.opacity(0.12),
                        iconForeground: OriveoTheme.Palette.danger
                    )
                }
                .buttonStyle(MemoryPopoverCardButtonStyle(tone: .danger))
            }
        }
        .padding(OriveoTheme.Spacing.lg)
        .frame(minWidth: 320, idealWidth: 340)
        .presentationCompactAdaptation(.popover)
    }

}

// MARK: - Embedded toolbar components

private struct MemoryPopoverPreviewCard: View {
    let previewText: String

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            HStack {
                Text(L10n.tr("Memory"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)

                Spacer()

                Image(systemName: "brain")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary.opacity(0.65))
            }

            ScrollView(.vertical, showsIndicators: false) {
                Text(previewText)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150, alignment: .top)
        }
        .padding(OriveoTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OriveoTheme.Palette.primarySoft.opacity(0.45),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                .stroke(OriveoTheme.Palette.border, lineWidth: 1)
        )
    }
}

private struct MemoryPopoverActionLabel: View {
    let title: String
    let systemImage: String
    let foreground: Color
    let iconBackground: Color
    let iconForeground: Color

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 32, height: 32)

                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }

            Text(title)
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(foreground.opacity(0.72))
        }
    }
}

private struct MemoryPopoverCardButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case danger
    }

    let tone: Tone
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 58)
            .background(backgroundFill(isPressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(
                color: shadowColor.opacity(configuration.isPressed ? 0.45 : 1),
                radius: tone == .primary ? (colorScheme == .dark ? 18 : 10) : 0,
                y: tone == .primary ? (colorScheme == .dark ? 10 : 6) : 0
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
    }

    private func backgroundFill(isPressed: Bool) -> some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
            .fill(backgroundStyle(isPressed: isPressed))
    }

    private func backgroundStyle(isPressed: Bool) -> AnyShapeStyle {
        switch tone {
        case .primary:
            return AnyShapeStyle(
                isPressed ?
                    OriveoTheme.Palette.primaryGradientPressed :
                    OriveoTheme.Palette.primaryGradient
            )
        case .danger:
            return AnyShapeStyle(OriveoTheme.Palette.dangerSoft)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return OriveoTheme.Palette.hairline.opacity(colorScheme == .dark ? 1 : 0.65)
        case .danger:
            return OriveoTheme.Palette.danger.opacity(colorScheme == .dark ? 0.24 : 0.18)
        }
    }

    private var shadowColor: Color {
        switch tone {
        case .primary:
            return OriveoTheme.Palette.primaryGlow
        case .danger:
            return .clear
        }
    }
}


private struct ChatToolbarIconCapsule: View {
    let systemImage: String
    var rotation: Double = 0

    var body: some View {
        Image(systemName: systemImage)
            .rotationEffect(.degrees(rotation))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .frame(width: 36, height: 36)
            .contentShape(.rect)
    }
}

private struct ChatCostPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(OriveoTheme.Palette.primary)
    }
}

private struct ChatToolbarPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Chat navigation chrome

extension EnvironmentValues {
    /// The system runs the navigation bar vertically along a side here. Injected by `chatNavigationChrome` from `toolbarVerticalEdge`.
    @Entry var chatUsesVerticalBar = false
}

extension View {
    /// The chat page's navigation chrome. Usually the same as `oriveoNavigationChrome`: the system navigation bar
    /// is hidden and the top bar is drawn by the page. Where the system wants vertical bars (the Duo cover screen,
    /// the detail column of the unfolded Duo held sideways) the system navigation bar is shown so back, new chat
    /// and the rest go into the vertical bar — a custom top bar never turns vertical, only system bars do (HIG
    /// Vertical controls). On an ordinary iPhone or iPad the condition is false and nothing changes. With
    /// `showsSystemBar` false (the empty detail column, no toolbar items) no system bar appears even then.
    func chatNavigationChrome(showsSystemBar: Bool = true) -> some View {
        modifier(ChatNavigationChrome(showsSystemBar: showsSystemBar))
            .readingToolbarVerticalEdge()
    }

    /// Reads the system's vertical bar edge into `chatUsesVerticalBar`. Per the system documentation the value reflects the preferred edge
    /// whether or not a vertical bar is visible, so it can be read while the navigation bar is hidden and showing the bar cannot flip it back.
    @ViewBuilder
    fileprivate func readingToolbarVerticalEdge() -> some View {
        // The 27.0 SDK has no vertical bar API (the project sets this condition by SDK name, see project.pbxproj)
        #if ORIVEO_SDK_BEFORE_27_1
        self
        #else
        if #available(iOS 27.1, *) {
            modifier(ToolbarVerticalEdgeReader())
        } else {
            self
        }
        #endif
    }
}

private struct ChatNavigationChrome: ViewModifier {
    let showsSystemBar: Bool
    @Environment(\.chatUsesVerticalBar) private var usesVerticalBar

    func body(content: Content) -> some View {
        // Only the visibility value changes, the modifier is never attached conditionally: the view keeps its identity across folding and the page keeps its state
        content
            .navigationBarBackButtonHidden(true)
            .toolbar(showsSystemBar && usesVerticalBar ? .visible : .hidden, for: .navigationBar)
    }
}

#if !ORIVEO_SDK_BEFORE_27_1
@available(iOS 27.1, *)
private struct ToolbarVerticalEdgeReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        content.environment(\.chatUsesVerticalBar, edge != nil)
    }
}
#endif
