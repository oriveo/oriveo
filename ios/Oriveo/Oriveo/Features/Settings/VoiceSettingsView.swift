import SwiftUI

/// The engine sheet currently presented from the voice settings page.
struct VoiceEngineSheetPresentation: Identifiable {
    let direction: VoiceDirection
    let model: VoiceEngineSheetModel

    var id: VoiceDirection { direction }
}

/// Voice settings interaction flow: loads the model on appear, opens the engine sheet,
/// forwards voice previews to the read-aloud controller and stops them when the page goes away.
@MainActor
@Observable
final class VoiceSettingsFlow {
    let model: VoiceSettingsModel
    var engineSheet: VoiceEngineSheetPresentation?

    @ObservationIgnored private let preview: (VoicePreviewRequest) -> Void
    @ObservationIgnored private let stopPreview: () -> Void

    init(
        model: VoiceSettingsModel,
        preview: @escaping (VoicePreviewRequest) -> Void = { request in
            ReadAloudController.shared.preview(
                entry: request.entry,
                provider: request.provider,
                voice: request.voice,
                speed: request.speed
            )
        },
        stopPreview: @escaping () -> Void = { ReadAloudController.shared.stopPreview() }
    ) {
        self.model = model
        self.preview = preview
        self.stopPreview = stopPreview
    }

    /// Entering the page refreshes the catalog and resolves the stored selections.
    func appear() async {
        await model.load()
        #if DEBUG
        // Shots only: open the engine sheet requested by the injection, once.
        if let direction = VoiceSettingsModel.shotsInjection?.openEngineSheet {
            VoiceSettingsModel.shotsInjection?.openEngineSheet = nil
            openEngineSheet(direction)
        }
        #endif
    }

    /// Leaving the page stops any running preview.
    func disappear() {
        stopPreview()
    }

    func openEngineSheet(_ direction: VoiceDirection) {
        engineSheet = VoiceEngineSheetPresentation(direction: direction, model: model.engineSheetModel(for: direction))
    }

    /// The engine sheet went away: re-read the local settings it may have changed.
    func engineSheetDismissed() {
        engineSheet = nil
        model.reloadLocalSettings()
    }

    func selectVoice(_ id: String) {
        model.selectVoice(id)
    }

    /// Inline preview; tapping the voice being previewed again stops it (handled by the controller).
    func tapPreview(_ voice: String) {
        guard let request = model.previewRequest(voice: voice) else { return }
        preview(request)
    }
}

/// Settings › Voice: dictation group (engine, recognition language), read-aloud group
/// (engine, speaking voices with inline preview, speed) and voice conversation group (engine), each with a footnote. Renders `VoiceSettingsModel` only.
struct VoiceSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var flow: VoiceSettingsFlow
    @ObservedObject private var readAloud = ReadAloudController.shared

    init(flow: VoiceSettingsFlow) {
        _flow = State(initialValue: flow)
    }

    init(appState: AppState) {
        self.init(flow: VoiceSettingsFlow(model: VoiceSettingsModel(
            providers: { [weak appState] in appState?.providers ?? [] }
        )))
    }

    private var model: VoiceSettingsModel { flow.model }

    /// Scroll anchor of the voice conversation group.
    static let realtimeGroupID = "voice_settings_realtime_group"

    /// Top bar: back button and centered title, same layout as other settings sub-pages.
    private var topBar: some View {
        ZStack {
            Text(L10n.tr("Voice", table: .voice))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                OriveoBackButton {
                    appState.pop()
                }
                .accessibilityIdentifier("settings_voice_back_button")
                .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
    }

    /// Inline preview button: stop state while this row's voice is being previewed, play otherwise.
    static func previewButtonAppearance(voice: String, previewingVoice: String?) -> (systemImage: String, label: String) {
        previewingVoice == voice
            ? ("stop.fill", L10n.tr("Stop Reading", table: .voice))
            : ("play.circle", L10n.tr("Preview", table: .voice))
    }

    var body: some View {
        @Bindable var flow = flow
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(VoiceSettingsModel.pageHeader)
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                dictationGroup
                    .padding(.bottom, 12)
                readAloudGroup
                    .padding(.bottom, 12)
                realtimeGroup
                    .id(Self.realtimeGroupID)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .oriveoContentWidth()
        }
        .task {
            await flow.appear()
            #if DEBUG
            if VoiceSettingsModel.shotsInjection?.scrollToRealtimeEngine == true {
                proxy.scrollTo(Self.realtimeGroupID, anchor: .bottom)
            }
            #endif
        }
        }
        // The route hides the system navigation bar (oriveoNavigationChrome), so the page draws its own bar.
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        // Smoke / UI test page anchor: the container only carries the identifier; children stay readable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice_settings_screen")
        .oriveoScreenBackground()
        .onDisappear { flow.disappear() }
        .sheet(item: $flow.engineSheet, onDismiss: { flow.engineSheetDismissed() }) { presentation in
            VoiceEngineSheet(model: presentation.model)
        }
    }

    // MARK: Groups

    private var dictationGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L10n.tr("Dictation", table: .voice))
            flatGroup {
                flatTapRow {
                    flow.openEngineSheet(.stt)
                } label: {
                    engineRowLabel(model.dictationEngine)
                }
                insetHairline()
                recognitionLanguageRow
            }
            if let text = model.dictationNotice {
                notice(text)
            }
            footnote(model.dictationFooter)
        }
    }

    private var readAloudGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(L10n.tr("Read Aloud", table: .voice))
            flatGroup {
                flatTapRow {
                    flow.openEngineSheet(.tts)
                } label: {
                    engineRowLabel(model.readAloudEngine)
                }
                insetHairline()
                speedRow
            }
            if let text = model.readAloudNotice {
                notice(text)
            }
            if let speedFooter = model.speedFooter {
                footnote(speedFooter)
            }
            if let hint = model.systemVoiceDownloadHint {
                footnote(hint)
            }

            if !model.voiceRows.isEmpty {
                sectionHeader(model.voiceRowsTitle)
                    .padding(.top, 12)
                flatGroup {
                    ForEach(Array(model.voiceRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            insetHairline()
                        }
                        voiceRow(row)
                    }
                }
            }

            footnote(model.readAloudFooter)
        }
    }

    private var realtimeGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(VoiceSettingsModel.realtimeGroupTitle)
            flatGroup {
                flatTapRow {
                    flow.openEngineSheet(.realtime)
                } label: {
                    engineRowLabel(model.realtimeEngine)
                }
            }
            if let text = model.realtimeNotice {
                notice(text)
            }
            footnote(model.realtimeFooter)
        }
    }

    // MARK: Rows

    private func engineRowLabel(_ row: VoiceEngineRow) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            engineIcon(row.providerKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            chevron
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func engineIcon(_ providerKind: ProviderKind?) -> some View {
        if let providerKind {
            ProviderBadgeIcon(kind: providerKind, size: 32)
        } else {
            Image(systemName: "iphone")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 32, height: 32)
        }
    }

    private var recognitionLanguageRow: some View {
        flatMenuRow {
            ForEach(model.recognitionLanguageOptions) { option in
                Button {
                    model.setRecognitionLanguage(option.code)
                } label: {
                    if option.code == model.recognitionLanguage {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr("Recognition Language", table: .voice))
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 8)
                Text(model.recognitionLanguageTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                chevron
            }
        }
    }

    private func voiceRow(_ row: VoiceSpeakingVoiceRow) -> some View {
        let previewButton = Self.previewButtonAppearance(voice: row.id, previewingVoice: readAloud.previewingVoice)
        return HStack(spacing: 0) {
            flatTapRow {
                flow.selectVoice(row.id)
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(row.title)
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Spacer(minLength: 0)
                    if row.isSelected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(OriveoTheme.Palette.primary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
            }
            Button {
                flow.tapPreview(row.id)
            } label: {
                Image(systemName: previewButton.systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, OriveoTheme.Spacing.sm)
            .accessibilityLabel(Text(previewButton.label))
        }
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.speedTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer()
                Text(model.speedText)
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { model.speechRate },
                    set: { model.setSpeechRate($0) }
                ),
                in: model.speedRange,
                step: model.speedStep
            )
            .tint(OriveoTheme.Palette.primary)
            .disabled(!model.speedEnabled)
            .accessibilityLabel(Text(model.speedTitle))
            .accessibilityValue(Text(model.speedText))
        }
        .opacity(model.speedEnabled ? 1 : 0.5)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 9)
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .accessibilityHidden(true)
    }

    // MARK: Text

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.warningText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
