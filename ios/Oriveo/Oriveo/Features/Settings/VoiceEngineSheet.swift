import SwiftUI

/// A pending cloud-voice disclosure, presented as a sheet over the engine sheet.
struct VoiceDisclosureRequest: Identifiable, Hashable {
    let engine: VoiceCloudEngine
    let direction: VoiceDirection

    var id: String {
        "\(engine.providerKind.rawValue)|\(engine.connectionID)|\(engine.model)"
    }
}

/// Engine sheet interaction flow: forwards picks and disclosure answers to `VoiceEngineSheetModel`.
/// A disclosure closed without an answer (swipe down) counts as a decline.
@MainActor
@Observable
final class VoiceEngineSheetFlow {
    let model: VoiceEngineSheetModel
    var disclosure: VoiceDisclosureRequest?

    @ObservationIgnored private var answered = false
    @ObservationIgnored private var appliedByDisclosure = false

    init(model: VoiceEngineSheetModel) {
        self.model = model
    }

    /// Tap a row. Returns whether the engine sheet should close (the pick took effect).
    func tap(_ row: VoiceEngineSheetRow) -> Bool {
        switch model.choose(row) {
        case .applied:
            return true
        case .needsDisclosure(let engine):
            answered = false
            appliedByDisclosure = false
            disclosure = VoiceDisclosureRequest(engine: engine, direction: model.direction)
            return false
        }
    }

    #if DEBUG
    /// Shots only: present the disclosure for `engine` as if its row had been tapped, without choosing it
    /// and without writing a consent. Ignored when the engine's direction differs from this sheet's.
    func showDisclosureForShots(_ engine: VoiceCloudEngine) {
        answered = false
        appliedByDisclosure = false
        disclosure = VoiceDisclosureRequest(engine: engine, direction: model.direction)
    }
    #endif

    /// "Agree and Use" / "Not Now".
    func answerDisclosure(accepted: Bool) {
        guard let request = disclosure, !answered else { return }
        answered = true
        appliedByDisclosure = model.resolveDisclosure(request.engine, accepted: accepted)
    }

    /// Disclosure sheet went away (button or swipe). Returns whether the engine sheet should close.
    func disclosureDismissed() -> Bool {
        if !answered {
            answerDisclosure(accepted: false)
        }
        let shouldClose = appliedByDisclosure
        disclosure = nil
        answered = false
        appliedByDisclosure = false
        return shouldClose
    }

    /// "Add Connection": close the sheet first, then open provider setup.
    static func addConnection(dismiss: () -> Void, openProviderSetup: (ProviderSetupEntryPoint) -> Void) {
        dismiss()
        openProviderSetup(.providers)
    }
}

/// Dictation / read-aloud engine picker: white card list, provider logo on the left, purple checkmark on the right.
/// "Add Connection" is the last row of the card; the footer sits below the card.
struct VoiceEngineSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var flow: VoiceEngineSheetFlow

    init(model: VoiceEngineSheetModel) {
        _flow = State(initialValue: VoiceEngineSheetFlow(model: model))
    }

    private var model: VoiceEngineSheetModel { flow.model }

    var body: some View {
        @Bindable var flow = flow
        NavigationStack {
            List {
                Section {
                    ForEach(model.rows) { row in
                        engineRow(row)
                    }
                    addConnectionRow
                } footer: {
                    if let footer = model.footer {
                        Text(footer)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.title)
            // Inline display mode keeps the title centered under the grabber (design 10: no toolbar buttons).
            .navigationBarTitleDisplayMode(.inline)
        }
        // Design 10: a half-height native sheet; long lists can still be dragged to full height.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if DEBUG
        .task {
            // Shots only: wait for the engine sheet to finish presenting, then raise the requested disclosure once.
            guard let engine = VoiceSettingsModel.shotsInjection?.disclosure else { return }
            VoiceSettingsModel.shotsInjection?.disclosure = nil
            try? await Task.sleep(nanoseconds: 800_000_000)
            flow.showDisclosureForShots(engine)
        }
        #endif
        .sheet(item: $flow.disclosure, onDismiss: {
            if flow.disclosureDismissed() {
                dismiss()
            }
        }) { request in
            VoiceDisclosureSheet(
                provider: request.engine.providerKind,
                direction: request.direction,
                onAnswer: { accepted in flow.answerDisclosure(accepted: accepted) }
            )
        }
    }

    @ViewBuilder
    private func engineRow(_ row: VoiceEngineSheetRow) -> some View {
        Button {
            if flow.tap(row) {
                dismiss()
            }
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                rowIcon(row.option)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(row.subtitle)
                        .font(.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                Spacer()
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(OriveoTheme.Palette.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func rowIcon(_ option: VoiceEngineOption) -> some View {
        switch option {
        case .system:
            Image(systemName: "iphone")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 32, height: 32)
        case .cloud(let providerKind, _, _, _):
            ProviderBadgeIcon(kind: providerKind, size: 32)
        }
    }

    private var addConnectionRow: some View {
        Button {
            VoiceEngineSheetFlow.addConnection(
                dismiss: { dismiss() },
                openProviderSetup: { appState.openProviderSetup(from: $0) }
            )
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(width: 32, height: 32)
                Text(model.addConnectionTitle)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                Spacer()
            }
        }
    }
}

/// Cloud voice disclosure shown the first time a provider is picked for dictation, read aloud, or voice conversations.
/// Swiping down is allowed and counts as a decline (handled by the presenter's onDismiss).
struct VoiceDisclosureSheet: View {
    let provider: ProviderKind
    let direction: VoiceDirection
    let onAnswer: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0
    @State private var buttonsHeight: CGFloat = 0

    static func title(provider: ProviderKind, direction: VoiceDirection) -> String {
        switch direction {
        case .stt:
            return L10n.format(L10n.tr("Use %@ for Dictation?", table: .voice), provider.displayName)
        case .tts:
            return L10n.format(L10n.tr("Use %@ for Read Aloud?", table: .voice), provider.displayName)
        case .realtime:
            return L10n.format(L10n.tr("Use %1$@ for Voice Conversations?", table: .voice), provider.displayName)
        }
    }

    static func message(provider: ProviderKind, direction: VoiceDirection) -> String {
        switch direction {
        case .stt:
            return L10n.format(
                L10n.tr("Your recordings will be sent to %@ to be transcribed. Oriveo doesn't keep them, and the provider's privacy policy applies.", table: .voice),
                provider.displayName
            )
        case .tts:
            return L10n.format(
                L10n.tr("Replies you play will be sent as text to %@ to generate speech. Oriveo doesn't keep them, and the provider's privacy policy applies.", table: .voice),
                provider.displayName
            )
        case .realtime:
            // The provider name appears three times; %1$@ fills all of them from one argument.
            return L10n.format(
                L10n.tr("In voice conversations, %1$@ answers instead of this chat's model. Your voice and this chat's history are sent to %1$@, usage is billed to your connection, and %1$@'s privacy policy applies.", table: .voice),
                provider.displayName
            )
        }
    }

    static func policyURL(provider: ProviderKind) -> URL? {
        provider.privacyPolicyURL
    }

    var body: some View {
        VStack(spacing: 0) {
            // Body scrolls when it outgrows the sheet (accessibility text sizes, long translations);
            // the buttons below stay pinned outside the scroll view so they are always reachable.
            ScrollView {
                VStack(spacing: 0) {
                    ProviderBadgeIcon(kind: provider, size: 56)
                        .padding(.top, 28)
                        .padding(.bottom, 16)

                    Text(Self.title(provider: provider, direction: direction))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    Text(Self.message(provider: provider, direction: direction))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                    if let policyURL = Self.policyURL(provider: provider) {
                        Link(destination: policyURL) {
                            HStack(spacing: 4) {
                                Text(L10n.tr("Privacy Policy", table: .voice))
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .padding(.bottom, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 12) {
                Button {
                    onAnswer(true)
                    dismiss()
                } label: {
                    Text(L10n.tr("Agree and Use", table: .voice))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OriveoTheme.Palette.primaryTextSafe)
                        .foregroundStyle(OriveoTheme.Palette.onPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button {
                    onAnswer(false)
                    dismiss()
                } label: {
                    Text(L10n.tr("Not Now", table: .voice))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
        }
        // The asset catalog AccentColor is empty, so the link would fall back to system blue.
        .tint(OriveoTheme.Palette.primary)
        // Size the sheet to its content (a fixed .medium squeezed long titles into an ellipsis), capped at 640pt;
        // .large is the fallback when the content is taller than that.
        .presentationDetents([.height(fittedHeight), .large])
        // A second detent would surface the drag indicator; keep the default-size look unchanged.
        .presentationDragIndicator(.hidden)
    }

    private var fittedHeight: CGFloat {
        let measured = contentHeight + buttonsHeight
        return contentHeight > 0 ? min(measured, 640) : 420
    }
}
