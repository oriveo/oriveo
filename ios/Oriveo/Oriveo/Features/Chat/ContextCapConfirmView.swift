import SwiftUI

/// Dialog state for a send held at the pre-send confirmation gate (P9 U8 contract item 2).
/// The checkbox exists only when the prompt shows it and starts unchecked; swipe-down = cancel.
struct ContextCapConfirmDialogModel: Equatable {
    let text: ContextCapConfirmPresentation.Text
    var dontAsk = false

    init(text: ContextCapConfirmPresentation.Text) {
        self.text = text
    }

    var showsDontAsk: Bool { text.showsDontAsk }

    /// "Send anyway": the checkbox only counts when it was shown.
    func sendChoice() -> ContextCapConfirmChoice {
        .send(dontAsk: showsDontAsk && dontAsk)
    }

    /// Cancel button and interactive dismiss.
    static let dismissChoice: ContextCapConfirmChoice = .cancel
}

/// Rolled-back send → composer: refilled only when the composer has neither text nor attachments.
nonisolated enum ContextCapComposerRestore {
    static func restoration(
        for rollback: ContextCapSendRollback,
        composerText: String,
        composerAttachments: [Attachment]
    ) -> ContextCapSendRollback? {
        guard composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              composerAttachments.isEmpty
        else { return nil }
        return rollback
    }
}

struct ContextCapConfirmView: View {
    @State private var model: ContextCapConfirmDialogModel
    let onChoose: (ContextCapConfirmChoice) -> Void

    init(text: ContextCapConfirmPresentation.Text, onChoose: @escaping (ContextCapConfirmChoice) -> Void) {
        _model = State(initialValue: ContextCapConfirmDialogModel(text: text))
        self.onChoose = onChoose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text.title)
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(model.text.body)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)

            if model.showsDontAsk {
                Toggle(isOn: $model.dontAsk) {
                    Text(L10n.tr("context_confirm_dont_ask", table: .chat))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                }
                .toggleStyle(ContextCapConfirmCheckboxToggleStyle())
            }

            // Neither button is the default action: Return must not send (contract item 2).
            HStack(spacing: 12) {
                Button {
                    onChoose(ContextCapConfirmDialogModel.dismissChoice)
                } label: {
                    Text(L10n.tr("Cancel"))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onChoose(model.sendChoice())
                } label: {
                    Text(L10n.tr("context_confirm_send", table: .chat))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(OriveoTheme.Palette.primary)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }
}

/// Same look as the memory organize sheet checkbox.
private struct ContextCapConfirmCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(configuration.isOn ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Presentation

private struct ContextCapConfirmHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Sheet container sized to its content (same approach as the library confirmation sheet).
private struct ContextCapConfirmSheetContainer: View {
    let pending: PendingContextCapConfirmation
    let onChoose: (ContextCapConfirmChoice) -> Void

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ContextCapConfirmView(text: pending.prompt.text, onChoose: onChoose)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContextCapConfirmHeightKey.self, value: proxy.size.height)
                    }
                }
            Spacer(minLength: 0)
        }
        .onPreferenceChange(ContextCapConfirmHeightKey.self) { measuredHeight = $0 }
        .presentationDetents([.height(measuredHeight > 0 ? min(measuredHeight, 560) : 300)])
        .presentationDragIndicator(.visible)
    }
}

/// Shows only the held send of the conversation on screen; swipe-down resolves it as cancel.
private struct ContextCapConfirmPresenter: ViewModifier {
    @Environment(AppState.self) private var appState
    let conversationID: UUID?

    private var confirmation: Binding<PendingContextCapConfirmation?> {
        let coordinator = appState.contextCapConfirmCoordinator
        let conversationID = conversationID
        return Binding<PendingContextCapConfirmation?>(
            get: { conversationID.flatMap { coordinator.pending(for: $0) } },
            set: { newValue in
                // Interactive dismiss: still pending means the user swiped it away = cancel.
                guard newValue == nil, let conversationID,
                      let pending = coordinator.pending(for: conversationID) else { return }
                appState.resolveContextCapConfirmation(id: pending.id, choice: ContextCapConfirmDialogModel.dismissChoice)
            }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: confirmation) { pending in
            ContextCapConfirmSheetContainer(pending: pending) { choice in
                appState.resolveContextCapConfirmation(id: pending.id, choice: choice)
            }
        }
    }
}

extension View {
    func contextCapConfirmPresenter(conversationID: UUID?) -> some View {
        modifier(ContextCapConfirmPresenter(conversationID: conversationID))
    }
}
