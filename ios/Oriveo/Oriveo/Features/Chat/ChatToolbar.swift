import SwiftUI

struct ChatToolbar: View {
    let projection: ChatScreenProjection
    let provider: Provider
    let currentModel: AIModel?
    let isSendingMessage: Bool
    var transparentChrome: Bool = false
    @Binding var showModelSwitcher: Bool
    @Binding var showDeleteConfirmation: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @State private var showMemoryPopover = false
    @State private var pendingExport: ChatExportItem?

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Button {
                appState.pop()
            } label: {
                ChatToolbarIconCapsule(systemImage: "chevron.backward")
            }
            .buttonStyle(ChatToolbarPressableStyle())
            .accessibilityLabel(L10n.tr("Back"))

            if let skillId = projection.skillID,
               let skill = appState.skillManager.skill(by: skillId) {
                Text(skill.icon)
                    .font(.title3)
                    .padding(.leading, 2)
            }

            Button {
                showModelSwitcher = true
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    ProviderBadgeIcon(kind: provider.kind, size: 26, relayKind: provider.relayKind)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentModel?.name ?? L10n.tr("Choose Model"))
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
            .buttonStyle(ChatToolbarPressableStyle())

            Spacer(minLength: 0)

            if projection.estimatedCost > 0 {
                ChatCostPill(text: CostFormatter.format(projection.estimatedCost))
            }

            if showMemoryIndicator {
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

            Menu {
                Button {
                    appState.startNewChat(preferredProviderID: provider.id)
                } label: {
                    Label(L10n.tr("New Chat"), systemImage: "plus")
                }

                Button {
                    presentExport()
                } label: {
                    Label(L10n.tr("Export Conversation", table: .chat), systemImage: "square.and.arrow.up")
                }
                .disabled(!projection.exportsEnabled)

                if projection.estimatedCost > 0 {
                    Section {
                        Text(CostFormatter.format(projection.estimatedCost))
                    }
                }

                if !appState.preferences.memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Toggle(isOn: Binding(
                        get: { projection.useMemory },
                        set: { newValue in
                            if let conversationID = projection.activeConversationID {
                                appState.setConversationUseMemory(conversationID, useMemory: newValue)
                            }
                        }
                    )) {
                        Label(L10n.tr("Use Memory", table: .chat), systemImage: "brain")
                    }
                }

                if projection.activeConversationID != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label(L10n.tr("Delete Conversation", table: .chat), systemImage: "trash")
                        }
                    }
                }
            } label: {
                ChatToolbarIconCapsule(systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(ChatToolbarPressableStyle())
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, OriveoTheme.Spacing.md)
        .padding(.bottom, OriveoTheme.Spacing.sm)
        .background {
            if !transparentChrome {
                LinearGradient(
                    stops: [
                        .init(color: OriveoTheme.Palette.background, location: 0),
                        .init(color: OriveoTheme.Palette.background, location: 0.5),
                        .init(color: OriveoTheme.Palette.background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(.container, edges: .top)
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

    private var showMemoryIndicator: Bool {
        let memoryText = appState.preferences.memoryText
        let useMemory = projection.useMemory
        return !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && useMemory
    }

    private var memoryPopoverContent: some View {
        let previewText = ChatMemoryPopoverPresenter.previewText(for: appState.preferences.memoryText)

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

                Button {
                    showMemoryPopover = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(OriveoTheme.Palette.surfaceInset)
                        )
                        .overlay(
                            Circle()
                                .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Dismiss"))
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

enum ChatMemoryPopoverPresenter {
    private static let previewLimit = 300

    static func previewText(for memoryText: String) -> String {
        let trimmed = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let preview = String(trimmed.prefix(previewLimit))
        return preview + (trimmed.count > previewLimit ? "..." : "")
    }
}


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

            Image(systemName: "chevron.right")
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
