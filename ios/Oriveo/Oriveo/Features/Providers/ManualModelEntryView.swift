import SwiftUI

struct ManualModelEntryView: View {
    let providerID: UUID
    let context: ManualModelEntryContext

    @Environment(AppState.self) private var appState

    @State private var modelID = ""
    @State private var retryError: OriveoError?
    @FocusState private var modelIDFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var isRelayMode: Bool { provider?.kind == .relay }

    private var board: ManualModelBoardModel {
        ManualModelBoardModel.make(isRelay: isRelayMode, input: modelID)
    }

    private var trimmedModelID: String { board.trimmedModelID }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .oriveoContentWidth()

            if provider == nil {
                Spacer()
                ProgressView()
                    .tint(OriveoTheme.Palette.primary)
                Spacer()
            } else {
                content
            }
        }
        .oriveoScreenBackground()
        .safeAreaInset(edge: .bottom) {
            if provider != nil {
                bottomBar
            }
        }
    }

    /// One input slot with notes underneath; both modes share the same layout and differ only in the board model.
    private var content: some View {
        let board = self.board
        return ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                modelSlot(board)

                if let retryError {
                    OriveoErrorCard(error: retryError) {
                        self.retryError = nil
                    }
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.sm)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
            .oriveoContentWidth()
        }
    }

    // MARK: - Input

    private func modelSlot(_ board: ManualModelBoardModel) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.tr(board.slotTitle.key, table: board.slotTitle.table))
                .font(OriveoTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .padding(.leading, 2)
                .accessibilityHidden(true)

            HStack(spacing: OriveoTheme.Spacing.sm) {
                TextField(
                    "",
                    text: $modelID,
                    prompt: placeholderText(board.placeholder)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(OriveoTheme.Typography.body.monospaced())
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .focused($modelIDFocused)
                .accessibilityLabel(L10n.tr(board.slotTitle.key, table: board.slotTitle.table))
                .environment(\.layoutDirection, board.forcesLeftToRightValue ? .leftToRight : layoutDirection)

                if board.showsClear {
                    Button {
                        modelID = ""
                        modelIDFocused = true
                    } label: {
                        PhosphorIcon.x.image(.regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Clear"))
                    .transition(.opacity)
                }
            }
            .padding(.leading, OriveoTheme.Spacing.lg)
            .padding(.trailing, board.showsClear ? 0 : OriveoTheme.Spacing.lg)
            .frame(minHeight: 50)
            // Same soft fill as the input slot on the setup page, with no outline.
            .background {
                let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                ZStack {
                    shape.fill(OriveoTheme.Palette.surfaceInset)
                    shape.fill(OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 0.68 : 0.62))
                }
            }
            .animation(.easeInOut(duration: 0.16), value: board.showsClear)

            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                ForEach(board.notes, id: \.key) { note in
                    Text(L10n.tr(note.key, table: note.table))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
        }
    }

    private func placeholderText(_ placeholder: ManualModelBoardModel.Placeholder) -> Text {
        switch placeholder {
        case let .verbatim(value): Text(verbatim: value)
        case let .localized(copy): Text(L10n.tr(copy.key, table: copy.table))
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        let board = self.board
        let disabled = !board.isPrimaryEnabled

        return VStack(spacing: OriveoTheme.Spacing.md) {
            Button(L10n.tr(board.primaryAction.key, table: board.primaryAction.table)) {
                saveManualModel()
            }
            .buttonStyle(OriveoPrimaryButtonStyle())
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.18), value: disabled)

            if let secondary = board.secondaryAction {
                Button(L10n.tr(secondary.key, table: secondary.table)) {
                    Task { await retrySync() }
                }
                .buttonStyle(OriveoSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.lg)
        .oriveoContentWidth()
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
        }
    }

    private var topBar: some View {
        HStack {
            OriveoBackButton {
                appState.pop()
            }
            .padding(.leading, -OriveoBackButton.edgeInset)

            Spacer()

            Text(L10n.tr(board.title.key, table: board.title.table))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Color.clear
                .frame(width: OriveoBackButton.hitSize - OriveoBackButton.edgeInset, height: 32)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
    }

    private func retrySync() async {
        guard let provider else { return }

        if provider.kind.supportsModelCatalogSync {
            do {
                try await appState.resyncProvider(providerID: provider.id)
                retryError = nil

                if context == .onboarding {
                    appState.completeProviderSetup(providerID: provider.id, entryPoint: .welcome)
                } else if context == .skillEdit {
                    appState.pop()
                    appState.pop()
                } else {
                    appState.pop()
                }
            } catch {
                retryError = makeProviderError(error, actionTitle: L10n.tr("Try Again"))
            }
        } else {
            retryError = OriveoError(
                id: UUID(),
                title: L10n.tr("Model Sync Failed", table: .providers),
                message: L10n.tr("This provider does not currently guarantee stable automatic model sync. Please continue with a manual model ID.", table: .providers),
                actionTitle: L10n.tr("Got It"),
                detail: L10n.tr("This provider does not support automatic model sync. You can manually enter a model ID instead.", table: .providers),
                severity: .warning
            )
        }
    }

    private func saveManualModel() {
        let trimmed = trimmedModelID
        guard !trimmed.isEmpty else { return }

        let didSave = appState.saveManualModel(
            providerID: providerID,
            modelID: trimmed,
            context: context
        )
        guard !didSave else { return }

        retryError = makeProviderError(
            ProviderServiceError.invalidConfiguration(
                detail: "This connection does not accept a manually entered model id."
            ),
            actionTitle: L10n.tr("Got It")
        )
    }
}
