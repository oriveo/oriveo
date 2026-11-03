import AVFoundation
import Foundation
import Observation

/// One engine row on the voice settings page: the system engine or a model on a cloud connection.
struct VoiceEngineRow: Hashable, Sendable {
    let title: String
    let subtitle: String
    let isCloud: Bool
    /// Provider of a cloud row (the view picks the logo from it); nil for the system row.
    let providerKind: ProviderKind?

    init(title: String, subtitle: String, isCloud: Bool, providerKind: ProviderKind? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.isCloud = isCloud
        self.providerKind = providerKind
    }
}

/// One row of the realtime voice group in settings: a realtime model on an official connection.
struct VoiceRealtimeRow: Hashable, Sendable, Identifiable {
    let providerID: UUID
    let providerKind: ProviderKind
    let model: String
    /// "Realtime voice · interrupt anytime · connection name".
    let subtitle: String
    /// Whether this is the Home realtime selection.
    let isSelected: Bool

    var id: String { "\(providerID.uuidString)|\(model)" }
}

/// State of the realtime voice group in settings: catalog not ready (progress row) / load failed (retry) / no usable row (add provider) / has rows.
enum VoiceRealtimeGroupState: Hashable, Sendable {
    case loading
    case failed
    case empty
    case rows([VoiceRealtimeRow])
}

/// Parameters for the settings page voice preview, matching the signature of `ReadAloudController.preview`.
struct VoicePreviewRequest {
    let entry: VoiceTTSEntry
    let provider: Provider
    let voice: String
    /// Effective speed: the shared speed clamped to the entry's speedRange.
    let speed: Double
}

/// One item in the speaking voice list: id is the voice id in the catalog, title is the capitalized display name.
struct VoiceSpeakingVoiceRow: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
}

/// One item in the recognition language menu; a nil code means automatic.
struct VoiceRecognitionLanguageOption: Hashable, Sendable, Identifiable {
    let code: String?
    let title: String

    var id: String { code ?? "auto" }
}

/// Presentation model of the voice settings page: catalog state + connections + local settings -> engine rows, footers,
/// recognition language, fallback notices, speaking voices, speed, the system voice download hint, engine sheet
/// models and preview parameters. The view only renders values computed here and never queries the catalog or connections itself.
@MainActor
@Observable
final class VoiceSettingsModel {
    /// nil means the page has not been entered yet (the catalog has no verdict).
    private(set) var catalogState: VoiceCatalogState?
    private(set) var dictationEngine: VoiceEngineRow
    private(set) var readAloudEngine: VoiceEngineRow
    /// Fallback notices under the engine rows; set only on the page entry that finds a fallback (or picks up a pending notice).
    private(set) var dictationNotice: String?
    private(set) var readAloudNotice: String?
    private(set) var recognitionLanguage: String?
    /// Stored read-aloud selection (the voice rows and speed adjustability are derived from it).
    private(set) var readAloudSelection: VoiceEngineSelection
    /// Read-aloud speed multiplier, shared by both engines.
    private(set) var speechRate: Double
    /// Quality of the best system voice for the interface language; nil when no system voice is available.
    private(set) var interfaceVoiceQuality: AVSpeechSynthesisVoiceQuality?

    @ObservationIgnored private let settings: VoiceEngineSettings
    @ObservationIgnored private let refreshCatalog: () async -> VoiceCatalogState
    @ObservationIgnored private let providers: () -> [Provider]
    @ObservationIgnored private let interfaceLanguage: @MainActor () -> String
    @ObservationIgnored private let systemVoiceQuality: @MainActor (String) -> AVSpeechSynthesisVoiceQuality?
    /// Home realtime selection (AppState in-memory state); read fresh each time, the check follows the Home selection.
    @ObservationIgnored private let realtimeSelection: @MainActor () -> RealtimeModelSelection?

    init(
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        refreshCatalog: @escaping () async -> VoiceCatalogState = { await VoiceCatalogClient.shared.refresh() },
        providers: @escaping () -> [Provider],
        interfaceLanguage: @escaping @MainActor () -> String = { AppLocalization.currentLanguage.rawValue },
        systemVoiceQuality: @escaping @MainActor (String) -> AVSpeechSynthesisVoiceQuality? = { VoiceSettingsModel.bestSystemVoiceQuality(for: $0) },
        realtimeSelection: @escaping @MainActor () -> RealtimeModelSelection? = { nil }
    ) {
        var settings = settings
        var refreshCatalog = refreshCatalog
        var providers = providers
        #if DEBUG
        if let injection = Self.shotsInjection {
            settings = injection.settings
            let state = injection.catalogState
            refreshCatalog = { state }
            let list = injection.providers
            providers = { list }
        }
        #endif
        self.settings = settings
        self.refreshCatalog = refreshCatalog
        self.providers = providers
        self.interfaceLanguage = interfaceLanguage
        self.systemVoiceQuality = systemVoiceQuality
        self.realtimeSelection = realtimeSelection
        self.dictationEngine = Self.row(for: settings.selection(for: .stt))
        self.readAloudSelection = settings.selection(for: .tts)
        self.readAloudEngine = Self.row(for: settings.selection(for: .tts))
        self.recognitionLanguage = settings.recognitionLanguage
        self.speechRate = settings.speechRate
        self.interfaceVoiceQuality = systemVoiceQuality(interfaceLanguage())
    }

    #if DEBUG
    /// Screenshot tooling only (VoiceShots): once set, newly created models use this settings store, catalog and connections instead, with no network and no real connections.
    struct ShotsInjection {
        let settings: VoiceEngineSettings
        let catalogState: VoiceCatalogState
        let providers: [Provider]
        /// Engine sheet direction to open after entering the page; cleared once used.
        var openEngineSheet: VoiceDirection?
        /// Engine whose disclosure is raised once the engine sheet opens (not selected, no consent written); cleared once used.
        var disclosure: VoiceCloudEngine? = nil
    }

    static var shotsInjection: ShotsInjection?
    #endif

    // MARK: - Page entry

    /// Entering the page refreshes the catalog, then resolves the stored selection per direction: a fallback is rewritten to System
    /// and noted once under that direction's engine row. A pending notice left by a call site that found the fallback first is shown here once too (cleared when taken).
    func load() async {
        let state = await refreshCatalog()
        catalogState = state
        let connections = Self.connections(providers())
        dictationNotice = resolveNotice(direction: .stt, catalog: state.catalog, connections: connections)
        readAloudNotice = resolveNotice(direction: .tts, catalog: state.catalog, connections: connections)
        reloadLocalSettings()
    }

    /// Re-reads only the local settings (engine selections, recognition language, speed, system voice quality) without fetching the catalog or resolving fallbacks;
    /// used after the engine sheet closes.
    func reloadLocalSettings() {
        dictationEngine = Self.row(for: settings.selection(for: .stt))
        refreshReadAloud()
        recognitionLanguage = settings.recognitionLanguage
        speechRate = settings.speechRate
        interfaceVoiceQuality = systemVoiceQuality(interfaceLanguage())
    }

    /// The same connection summary used by dictation / read-aloud resolution (authMode, whether a key exists).
    private static func connections(_ providers: [Provider]) -> [VoiceConnection] {
        providers.map(VoiceConnection.init(provider:))
    }

    // MARK: - Engine sheet

    /// The engine sheet model for a direction. Catalog state and connections are read live (this model's catalogState, providers()),
    /// so an open sheet follows connections or a catalog that arrive late or change; with no catalog verdict yet it has only the system row and no footer.
    func engineSheetModel(for direction: VoiceDirection) -> VoiceEngineSheetModel {
        let providers = self.providers
        return VoiceEngineSheetModel(
            direction: direction,
            catalogState: { [weak self] in self?.catalogState },
            connections: {
                let list = providers()
                return VoiceEngineSheetConnections(
                    Self.connections(list),
                    names: Dictionary(list.map { ($0.id.uuidString, $0.displayName) }, uniquingKeysWith: { first, _ in first })
                )
            },
            chooser: VoiceEngineChooser(settings: settings)
        )
    }

    private func refreshReadAloud() {
        readAloudSelection = settings.selection(for: .tts)
        readAloudEngine = Self.row(for: readAloudSelection)
    }

    private func resolveNotice(
        direction: VoiceDirection,
        catalog: VoiceCatalog?,
        connections: [VoiceConnection]
    ) -> String? {
        let pending = settings.takePendingNotice(site: .settings, direction: direction)
        // Without a usable catalog nothing is resolved or rewritten (same as the call sites); only the stored selection is shown.
        var fellBack = false
        if let catalog {
            fellBack = settings.resolve(
                direction: direction,
                catalog: catalog,
                connections: connections,
                site: .settings
            ).notice
        }
        guard fellBack || pending != nil else { return nil }
        return L10n.tr("The selected engine is no longer available. Switched back to System.", table: .voice)
    }

    /// Page header: dictation, read aloud and voice conversations all default to the system.
    static var pageHeader: String {
        L10n.tr("Dictation and read aloud use your device's built-in voice for free. For better accuracy or a more natural voice, switch to a provider you've connected. Realtime voice talks to your provider's model directly and is billed to your account with that provider.", table: .voice)
    }

    // MARK: - Realtime voice group

    /// Catalog has no verdict yet -> progress row; load failed -> retry; otherwise list the realtime models of all official connections in connection order
    /// (same exit as the Home picker); no rows gives the empty state.
    var realtimeGroup: VoiceRealtimeGroupState {
        guard let state = catalogState else { return .loading }
        if case .loadFailed = state { return .failed }
        let list = providers()
        let byProvider = modelPickerRealtimeModels(context: .home, providers: list, catalog: state.catalog).byProvider
        let selected = realtimeSelection()
        let subtitle = L10n.tr("Realtime voice · Interrupt anytime", table: .voice)
        let rows = list.flatMap { provider in
            (byProvider[provider.id] ?? []).map { model in
                VoiceRealtimeRow(
                    providerID: provider.id,
                    providerKind: provider.kind,
                    model: model,
                    subtitle: "\(subtitle) · \(provider.displayName)",
                    isSelected: selected?.providerID == provider.id && selected?.model == model
                )
            }
        }
        return rows.isEmpty ? .empty : .rows(rows)
    }

    /// Reload the catalog: the group shows a progress row meanwhile; once it arrives, the stored selection is resolved the same way as on page entry.
    func retryRealtime() async {
        catalogState = nil
        await load()
    }

    var realtimeFooter: String {
        L10n.tr(
            "Pick one and Home shows the voice stage — tap the orb to start talking. Any chat's model picker has it too; pick a text model to go back to typing.",
            table: .voice
        )
    }

    var realtimeEmptyText: String {
        L10n.tr("Add an official API key from a provider with realtime voice to use it here.", table: .voice)
    }

    var realtimeAddProviderTitle: String {
        L10n.tr("Add Provider")
    }

    var realtimeFailedText: String {
        L10n.tr("Couldn't load realtime voice models", table: .voice)
    }

    var realtimeRetryTitle: String {
        L10n.tr("Try Again", table: .voice)
    }

    // MARK: - Dictation group

    var dictationFooter: String {
        dictationEngine.isCloud
            ? L10n.tr(
                "Recordings are sent only to the provider you choose. If transcription fails, the recording stays on this device for up to 7 days. Voice conversations listen with this engine too.",
                table: .voice
            )
            : L10n.tr(
                "System dictation may be processed by Apple. If transcription fails, the recording stays on this device for up to 7 days. Voice conversations listen with this engine too.",
                table: .voice
            )
    }

    /// Automatic plus the 16 languages the app supports, each named in its own language.
    var recognitionLanguageOptions: [VoiceRecognitionLanguageOption] {
        Self.recognitionLanguageOptions()
    }

    var recognitionLanguageTitle: String {
        RecognitionLanguageSheetModel.displayName(recognitionLanguage)
    }

    func setRecognitionLanguage(_ code: String?) {
        settings.recognitionLanguage = code
        recognitionLanguage = settings.recognitionLanguage
    }

    static func recognitionLanguageOptions() -> [VoiceRecognitionLanguageOption] {
        let languages = LanguageOption.allCases
            .filter { $0 != .system }
            .map { VoiceRecognitionLanguageOption(code: $0.effectiveLanguage.rawValue, title: $0.displayName) }
        return [VoiceRecognitionLanguageOption(code: nil, title: L10n.tr("Automatic", table: .voice))] + languages
    }

    // MARK: - Read-aloud group

    /// Catalog entry of the current cloud read-aloud selection; nil for system read aloud or when the catalog has no such entry.
    private var readAloudEntry: VoiceTTSEntry? {
        guard case .cloud(let engine) = readAloudSelection, let catalog = catalogState?.catalog else { return nil }
        return catalog.ttsEntries(engine.providerKind).first { $0.model == engine.model }
    }

    /// Voice rows exist only for cloud read aloud: the entry's voices in catalog order, with the stored voice checked (the entry's default voice when none is stored).
    var voiceRows: [VoiceSpeakingVoiceRow] {
        guard case .cloud(let engine) = readAloudSelection, let entry = readAloudEntry else { return [] }
        let selected = engine.voice ?? entry.defaultVoice?.id
        return entry.voices.map { voice in
            VoiceSpeakingVoiceRow(id: voice.id, title: Self.voiceTitle(voice.id), isSelected: voice.id == selected)
        }
    }

    var voiceRowsTitle: String {
        L10n.tr("Speaking Voice", table: .voice)
    }

    /// Picking a voice writes it into the tts selection (the engine is unchanged).
    func selectVoice(_ id: String) {
        guard case .cloud(let engine) = readAloudSelection else { return }
        let updated = VoiceCloudEngine(
            providerKind: engine.providerKind,
            connectionID: engine.connectionID,
            model: engine.model,
            voice: id
        )
        settings.setSelection(.cloud(updated), for: .tts)
        refreshReadAloud()
    }

    /// Preview parameters for a voice: the current cloud read-aloud entry, its connection and the effective speed; nil when the entry or connection is missing.
    func previewRequest(voice: String) -> VoicePreviewRequest? {
        guard case .cloud(let engine) = readAloudSelection,
              let entry = readAloudEntry,
              let provider = providers().first(where: { $0.id.uuidString == engine.connectionID })
        else { return nil }
        return VoicePreviewRequest(
            entry: entry,
            provider: provider,
            voice: voice,
            speed: CloudReadAloudRules.effectiveSpeed(slider: speechRate, entry: entry)
        )
    }

    var speedTitle: String {
        L10n.tr("Speed", table: .voice)
    }

    var speedRange: ClosedRange<Double> {
        CloudReadAloudRules.speedSliderMin...CloudReadAloudRules.speedSliderMax
    }

    var speedStep: Double {
        CloudReadAloudRules.speedSliderStep
    }

    /// Speed text: one decimal plus ×.
    var speedText: String {
        L10n.format("%.1f×", speechRate)
    }

    /// The system engine is always adjustable; a cloud entry is adjustable only when it has a speedRange.
    var speedEnabled: Bool {
        switch readAloudSelection {
        case .system: return true
        case .cloud: return readAloudEntry?.speedRange != nil
        }
    }

    var speedFooter: String? {
        speedEnabled ? nil : L10n.tr("This engine doesn't support speed control.", table: .voice)
    }

    /// Writes the speed shared by both engines, clamped to the slider range and snapped to the step.
    func setSpeechRate(_ rate: Double) {
        let scale = (1 / CloudReadAloudRules.speedSliderStep).rounded()
        let clamped = min(max(rate, CloudReadAloudRules.speedSliderMin), CloudReadAloudRules.speedSliderMax)
        settings.speechRate = (clamped * scale).rounded() / scale
        speechRate = settings.speechRate
    }

    /// With system read aloud, when the best system voice for the interface language is only default quality, hints at downloading an Enhanced voice.
    var systemVoiceDownloadHint: String? {
        guard readAloudSelection == .system, interfaceVoiceQuality == .default else { return nil }
        return L10n.tr(
            "For a more natural voice, download an Enhanced or Premium voice in Settings > Accessibility > Spoken Content > Voices.",
            table: .voice
        )
    }

    var readAloudFooter: String {
        L10n.tr("Read aloud skips thinking and code. If the cloud voice is unavailable, the system voice takes over. Voice conversations speak with this voice and speed too.", table: .voice)
    }

    static func voiceTitle(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Same rule as system read aloud's voice picking (novelty voices and personal voices are excluded).
    static func bestSystemVoiceQuality(for language: String) -> AVSpeechSynthesisVoiceQuality? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return SystemSpeechEngine.bestVoice(for: language, among: voices)?.quality
    }

    // MARK: - Engine rows

    /// Engine row title (system -> "System", cloud -> provider display name). The value of the Voice tile on the Settings home and the read-aloud row on the voice page share this source.
    static func engineDisplayName(for selection: VoiceEngineSelection) -> String {
        switch selection {
        case .system:
            return L10n.tr("System", table: .voice)
        case .cloud(let engine):
            return engine.providerKind.displayName
        }
    }

    static func row(for selection: VoiceEngineSelection) -> VoiceEngineRow {
        switch selection {
        case .system:
            return VoiceEngineRow(
                title: engineDisplayName(for: selection),
                subtitle: L10n.tr("Built into your device, free", table: .voice),
                isCloud: false
            )
        case .cloud(let engine):
            return VoiceEngineRow(
                title: engineDisplayName(for: selection),
                subtitle: L10n.format(L10n.tr("%@ · Billed to your connection", table: .voice), engine.model),
                isCloud: true,
                providerKind: engine.providerKind
            )
        }
    }
}
