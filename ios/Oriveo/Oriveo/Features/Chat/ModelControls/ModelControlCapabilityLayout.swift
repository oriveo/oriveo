import CoreGraphics
import Foundation

/// Decides **what the whole model options panel draws**, entirely in pure functions.
///
/// The shape of a single capability comes from `ModelOptionCapabilityShape`; this file handles what lies outside it:
/// the status seal under the title, which of the two rows comes first, whether a way forward that leads nowhere is removed, the notes at the bottom of the card, the summary on the "Advanced settings" row,
/// and how tall the panel should be. The panel view only draws a `ModelOptionsPanelModel`; it reads no storage and decides no business condition,
/// so the debug samples and the real panel take the same path.

// MARK: - Status seal

/// The small seal under the title: who provides the settings on this connection.
nonisolated enum ModelOptionsSeal: Equatable, Sendable, CaseIterable {
    /// At least one of web search and thinking has an official configuration.
    case officialConfiguration
    /// A custom LLM or a local engine: sent according to the protocol, verified by no one.
    case unverified

    static func resolve(
        connection: ModelOptionCapabilityShape.Connection,
        presentations: [CapabilityControlPresentation]
    ) -> Self? {
        let hasOfficialConfiguration = presentations.contains { presentation in
            switch presentation {
            case .pending, .unknown: return false
            case .automaticAvailable, .alwaysOn, .forceUnsupported, .customOnly, .externalConnectorOnly, .unsupported:
                return true
            }
        }
        if hasOfficialConfiguration { return .officialConfiguration }
        // A model on an official connection that is not in the catalog yet gets no seal: it is neither "official configuration" nor "unverified".
        return connection == .custom ? .unverified : nil
    }

    @MainActor var title: String {
        switch self {
        case .officialConfiguration: return L10n.tr("Official configuration", table: .chat)
        case .unverified: return L10n.tr("Unverified", table: .providers)
        }
    }
}

// MARK: - Panel height

/// The panel is as tall as its content; when that cannot be measured it falls back to half the screen instead of silently growing to full height.
nonisolated enum ModelOptionsSheetHeight: Equatable, Sendable {
    case fitted(CGFloat)
    case half
    case full

    /// A reading above this is not a real content height (lazy containers, or a view not laid out yet, report such values).
    static let implausibleContentHeight: CGFloat = 10_000

    /// The detent height is the content height itself. `.height` measures the part inside the safe area, and the system
    /// reserves the bottom safe area below it; adding it again would leave a blank strip as tall as the safe area under the panel.
    static func resolve(contentHeight: CGFloat, hasPushedPage: Bool) -> Self {
        // A second-level page is a full page and fills the screen.
        if hasPushedPage { return .full }
        guard contentHeight.isFinite, contentHeight > 0, contentHeight < implausibleContentHeight else {
            return .half
        }
        return .fitted(contentHeight.rounded(.up))
    }
}

// MARK: - Notes

nonisolated enum ModelOptionsText {
    /// Joins several notes into one paragraph. After a sentence that ends in full-width punctuation the next one follows directly
    /// (full-width punctuation brings its own spacing); otherwise a space is added.
    static func joined(_ sentences: [String]) -> String {
        var result = ""
        for sentence in sentences where !sentence.isEmpty {
            if let last = result.last, !"\u{3002}\u{FF01}\u{FF1F}\u{FF1B}\u{FF0C}\u{3001}\u{FF1A}\u{2026}".contains(last) { result += " " }
            result += sentence
        }
        return result
    }
}

// MARK: - Header subtitle

/// The first two segments of the line under the title: who runs this model and how it is reached. Every criterion is a fact from the connection's configuration.
nonisolated enum ModelOptionsSubject {
    /// Shows the engine name when the connection declares an engine type, the connection name otherwise.
    static func name(connectionName: String, engineProfile: String?) -> String {
        guard let engine = engineProfile.flatMap(LocalEngineKind.init(rawValue:)) else { return connectionName }
        switch engine {
        case .llamacpp: return "llama.cpp"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .vllm: return "vLLM"
        case .openwebui: return "Open WebUI"
        }
    }

    /// Whether the host of the API root is a loopback address (the server runs on this device).
    static func isLoopback(apiRoot: String?) -> Bool {
        guard let raw = apiRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        // The user may have typed just `localhost:8080`: without a scheme the URL has no host, so add one and parse again.
        let text = raw.contains("://") ? raw : "http://" + raw
        guard let host = URLComponents(string: text)?.host?.lowercased() else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// The second segment: "On this device" when it runs on this device, the protocol otherwise.
    @MainActor
    static func detail(apiRoot: String?, protocolLabel: String?) -> String? {
        if isLoopback(apiRoot: apiRoot) { return L10n.tr("Local", table: .chat) }
        return protocolLabel.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Panel model

/// Everything the panel draws.
struct ModelOptionsPanelModel: Equatable {
    typealias Shape = ModelOptionCapabilityShape

    struct Row: Equatable, Identifiable {
        let capability: Shape.Capability
        let shape: Shape
        var id: String { capability.rawValue }
    }

    enum Card: Equatable {
        case rows([Row])
        /// Undecided protocol: the whole card says just that one thing.
        case callout(Shape.Callout)
    }

    /// Notes at the bottom of the card: a preference taken over by custom fields, web search rejected by the provider, cost and privacy notices for custom fields.
    struct Note: Equatable, Identifiable {
        let id: String
        let text: String
        let tone: Shape.NoteTone
        /// Whether this note carries a link to advanced settings.
        let opensAdvancedSettings: Bool
    }

    struct Chip: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
    }

    struct Advanced: Equatable {
        let chips: [Chip]
        let moreCount: Int
    }

    /// The read-only note at the top of the page. An undecided protocol does not come through here; the capability card says that itself.
    struct Banner: Equatable {
        enum Action: Equatable, Sendable {
            case refetch
            case chooseAnotherModel
        }

        var text: String
        var action: Action?
        var isBusy = false
        /// The sentence shown when the configuration is still missing after fetching again.
        var failureText: String?
    }

    enum ScopeUpgrade: Equatable, Sendable {
        case offer
        case confirmed
    }

    let title: String
    let connectionName: String
    let protocolLabel: String?
    let seal: ModelOptionsSeal?
    let banner: Banner?
    let card: Card
    /// The 2x2 capability tiles; empty when an undecided protocol is collapsed into a callout.
    let tiles: [ModelOptionsTiles.Tile]
    /// The items of "this turn will send"; no bar is shown when there are none.
    let summary: [String]
    let notes: [Note]
    /// The first row of the parameter card; nil when the model has no temperature parameter.
    let temperature: ModelOptionsTiles.Temperature?
    let advanced: Advanced
    let scopeUpgrade: ScopeUpgrade?

    var summaryText: String? { ModelOptionsTiles.summaryText(summary) }
}

/// All inputs of the panel model: facts that are already resolved. The real panel takes them from storage and configuration, the debug samples from fixtures.
struct ModelOptionsPanelFacts {
    typealias Shape = ModelOptionCapabilityShape

    var modelName: String
    var connectionName: String
    var protocolLabel: String?
    /// The engine type the connection declares (llamacpp / ollama / lmstudio / vllm / openwebui); nil when it declares none.
    var engineProfile: String?
    /// The connection's API root.
    var apiRoot: String?
    var web: Shape.Input
    var reasoning: Shape.Input
    /// The current state of the chat template's thinking switch in the additional request body; only meaningful for a custom connection without an official configuration.
    var chatTemplateThinking: ChatTemplateThinkingSwitch.State = .off
    /// Whether another model in this connection can adjust this capability. Without one, the "see which models" link is not offered.
    var hasWebCandidates = true
    var hasReasoningCandidates = true
    /// Capabilities whose preference is currently taken over by custom request fields.
    var takenOverByCustomFields: Set<Shape.Capability> = []
    /// Risk tiers of the custom fields that took over (`privacy_impacting` or a cost tier).
    var customFieldRiskTiers: [String] = []
    /// The provider has rejected web search for this model.
    var webRejectedUpstream = false
    var banner: ModelOptionsPanelModel.Banner?
    var advancedRows: [GenerationParameterRowModel] = []
    var scopeUpgrade: ModelOptionsPanelModel.ScopeUpgrade?
    /// The vision input projection for the current model: the same source the composer's photo entry follows; nil is shown as unknown.
    var visionInput: CapabilityEvidenceFacade.InputCapabilityProjection?
    /// The native file mode resolved by the production wire; nil when the wire cannot be determined.
    var fileMode: NativeFileMode?
    var nativeFileMimes: [String] = []
    var pdfNativeDefault = false
    /// The relay `file` negative cache has not expired.
    var relayFileRejected = false
}

extension ModelOptionsPanelModel {
    static func make(_ facts: ModelOptionsPanelFacts) -> Self {
        var reasoningInput = facts.reasoning
        reasoningInput.chatTemplateThinkingIsOn = facts.chatTemplateThinking == .on

        let card: Card
        var tiles: [ModelOptionsTiles.Tile] = []
        var summary: [String] = []
        switch ModelOptionCapabilityCard.resolve(web: facts.web, reasoning: reasoningInput) {
        case let .protocolUndecided(callout):
            card = .callout(callout)
        case let .rows(web, reasoning):
            let usesChatTemplate = reasoning.isChatTemplateThinkingToggle
            var reasoningShape = reasoning.withoutEmptyModelList(hasCandidates: facts.hasReasoningCandidates)
            if usesChatTemplate, let blocked = chatTemplateThinkingNotice(facts.chatTemplateThinking) {
                reasoningShape = .notice(blocked)
            }
            let webRow = Row(
                capability: .web, shape: web.withoutEmptyModelList(hasCandidates: facts.hasWebCandidates)
            )
            let reasoningRow = Row(capability: .reasoning, shape: reasoningShape)
            // On a custom connection only thinking can be changed, so it comes first; otherwise the order is fixed: web search, then thinking.
            let rows = usesChatTemplate ? [reasoningRow, webRow] : [webRow, reasoningRow]
            card = .rows(rows)
            tiles = rows.map(ModelOptionsTiles.tile(for:)) + [
                ModelOptionsTiles.visionTile(ModelOptionsTiles.vision(facts.visionInput)),
                ModelOptionsTiles.filesTile(ModelOptionsTiles.files(
                    mode: facts.fileMode, nativeFileMimes: facts.nativeFileMimes,
                    relayFileRejected: facts.relayFileRejected, pdfNativeDefault: facts.pdfNativeDefault
                )),
            ]
            summary = ModelOptionsTiles.summaryItems(web: webRow.shape, reasoning: reasoningRow.shape)
        }

        let (temperature, otherRows) = ModelOptionsTiles.splitTemperature(facts.advancedRows)
        let chipSummary = GenerationParameterRowModel.summary(otherRows)
        let shown = otherRows.filter(\.isSentConversationOverride).prefix(chipSummary.chips.count)

        return .init(
            title: facts.modelName,
            connectionName: ModelOptionsSubject.name(
                connectionName: facts.connectionName, engineProfile: facts.engineProfile
            ),
            protocolLabel: ModelOptionsSubject.detail(apiRoot: facts.apiRoot, protocolLabel: facts.protocolLabel),
            seal: ModelOptionsSeal.resolve(
                connection: facts.web.connection,
                // The relay web row is the connection's own switch, not an official configuration: it is left out of the seal (a rejected, dimmed row must not flip the header to official configuration).
                presentations: [facts.web.relayWeb == nil ? facts.web.presentation : .unknown, facts.reasoning.presentation]
            ),
            // With a control the user can flip in the panel, the "settings are read-only" banner is not shown: next to a working toggle it would be false.
            banner: card.hasWritableControl ? nil : facts.banner,
            card: card,
            tiles: tiles,
            summary: summary,
            notes: notes(facts),
            temperature: temperature,
            advanced: .init(
                chips: shown.map { Chip(id: $0.id, title: $0.title, value: $0.displayValue ?? "") },
                moreCount: chipSummary.moreCount
            ),
            scopeUpgrade: facts.scopeUpgrade
        )
    }

    private static func notes(_ facts: ModelOptionsPanelFacts) -> [Note] {
        var notes: [Note] = []
        if !facts.takenOverByCustomFields.isEmpty {
            notes.append(.init(
                id: "custom-fields",
                text: L10n.tr(
                    "Custom request fields are on for this control, so the preference above is not sent.",
                    table: .chat
                ),
                tone: .warning, opensAdvancedSettings: true
            ))
            // Risk is a property of the custom fields, not of the capability: nothing is said while the fields are not rewriting the request.
            for tier in facts.customFieldRiskTiers {
                let privacy = tier == "privacy_impacting"
                notes.append(.init(
                    id: "risk-\(tier)",
                    text: privacy
                        ? L10n.tr("This field can send your data to a third-party service.", table: .chat)
                        : L10n.tr("This field can increase what the provider charges.", table: .chat),
                    tone: .warning, opensAdvancedSettings: false
                ))
            }
        }
        if facts.webRejectedUpstream {
            notes.append(.init(
                id: "web-rejected",
                text: L10n.tr(
                    "The provider rejected this setting for this model. Send again without it, or pick another model.",
                    table: .chat
                ),
                tone: .warning, opensAdvancedSettings: false
            ))
        }
        return notes
    }

    /// When this toggle cannot write the additional request body right now, the thinking row explains why and points to where that can be fixed.
    private static func chatTemplateThinkingNotice(_ state: ChatTemplateThinkingSwitch.State) -> Shape.Notice? {
        let body: String
        switch state {
        case .on, .off:
            return nil
        case .blocked:
            body = L10n.tr(
                "The additional request body has a problem, so this switch can’t change it. Fix it there first.",
                table: .chat
            )
        case .notSending:
            // The stored content has other fields too: flipping this toggle must not start sending them along.
            body = L10n.tr(
                "The additional request body isn’t being sent with requests right now. Turn that on there first.",
                table: .chat
            )
        }
        return .init(
            status: L10n.tr("Can’t switch here yet", table: .chat),
            body: body,
            link: .init(
                title: L10n.tr("Open additional request body", table: .chat), action: .openAdditionalRequestBody
            )
        )
    }
}

extension ModelOptionsPanelModel.Card {
    /// Whether the card has a control the user can flip right now.
    var hasWritableControl: Bool {
        guard case let .rows(rows) = self else { return false }
        return rows.contains { row in
            switch row.shape {
            case .toggle, .tiers, .toggleWithTiming, .toggleWithSource: return true
            case .notice, .disclosure, .protocolUndecided: return false
            }
        }
    }
}

extension ModelOptionCapabilityShape.Tiers {
    /// Without an Automatic segment, tapping the selected level again goes back to "never chosen" (the model's default).
    /// With Automatic, that segment is the way back and no second gesture is needed.
    var allowsClearing: Bool {
        !options.contains { $0.id == ModelOptionCapabilityShape.automaticIntent }
    }
}

extension ModelOptionCapabilityShape {
    /// The value behind the switch in the card's top-right corner; nil when the shape is not a toggle.
    var toggleValue: Toggle? {
        switch self {
        case let .toggle(toggle), let .toggleWithTiming(toggle, _), let .toggleWithSource(toggle, _): return toggle
        case .tiers, .notice, .disclosure, .protocolUndecided: return nil
        }
    }

    /// The toggle that writes the chat template's thinking switch in the additional request body.
    var isChatTemplateThinkingToggle: Bool {
        if case let .toggle(toggle) = self { return toggle.target == .chatTemplateThinking }
        return false
    }

    /// When this connection has no other model to switch to, the "see which models can" link is removed:
    /// it would open an empty list, which is worse than no link.
    func withoutEmptyModelList(hasCandidates: Bool) -> Self {
        guard !hasCandidates else { return self }
        switch self {
        case let .disclosure(disclosure) where disclosure.action == .openSupportedModels:
            return .disclosure(.init(status: disclosure.status, action: nil))
        case let .notice(notice) where notice.link?.action == .openSupportedModels:
            return .notice(.init(status: notice.status, body: notice.body, link: nil, cta: notice.cta))
        case .toggle, .tiers, .toggleWithTiming, .toggleWithSource, .notice, .disclosure, .protocolUndecided:
            return self
        }
    }
}

// MARK: - Capability tiles

/// The 2x2 capability tiles, the "this turn will send" summary and the temperature row of the parameter card.
/// It only lays out shapes and facts that are already resolved: it reads no storage and re-decides no capability.
/// The vision and file facts come from the production functions via the panel (see `ModelControlsSheet.panelFacts`).
enum ModelOptionsTiles {
    typealias Shape = ModelOptionCapabilityShape

    enum Kind: String, Equatable {
        case web, reasoning, vision, files
    }

    /// What sits in the top-right corner of a tile.
    enum Accessory: Equatable {
        case toggle(isOn: Bool)
        /// Number of thinking levels ("%lld levels").
        case levelCount(Int)
        case check
        case question
        case cross
        /// The whole tile is tappable (an explanation, a status line, or an undecided protocol that carries a way out).
        case chevron
        case none
    }

    enum VisionState: Equatable {
        case available, unknown
        case unavailable(CapabilityEvidenceFacade.InputDisabledReason)
    }

    enum FileState: Equatable {
        case pdfNative, nativeWhenSupported, text
    }

    struct Tile: Equatable, Identifiable {
        let kind: Kind
        let title: String
        let accessory: Accessory
        /// The status line under the title; not drawn when nil.
        let status: String?
        /// Small text under the status line (the body of an explanation tile).
        let detail: String?
        /// The row behind the web and thinking tiles; vision and files are information tiles and have none.
        let row: ModelOptionsPanelModel.Row?

        var id: String { kind.rawValue }

        /// The whole tile is tappable when an explanation, a status line or an undecided protocol carries a way out.
        var isTappable: Bool { tapAction != nil }

        var tapAction: ModelOptionCapabilityAction? {
            switch row?.shape {
            // An explanation card with a primary button is not tappable as a whole: each of the two ways out is its own button.
            case let .notice(notice)?: return notice.cta == nil ? notice.link?.action : nil
            case let .disclosure(disclosure)?: return disclosure.action
            case let .protocolUndecided(callout)?: return callout.link.action
            default: return nil
            }
        }

        var levelCountText: String? {
            guard case let .levelCount(count) = accessory else { return nil }
            return String(format: L10n.tr("%lld levels", table: .chat), count)
        }
    }

    struct Temperature: Equatable {
        let title: String
        let value: String
    }

    // MARK: Web search and thinking

    static func tile(for row: ModelOptionsPanelModel.Row) -> Tile {
        let title: String = switch row.capability {
        case .web: L10n.tr("Web Search", table: .chat)
        case .reasoning: L10n.tr("Thinking Mode", table: .chat)
        }
        let kind: Kind = row.capability == .web ? .web : .reasoning
        func make(_ accessory: Accessory, _ status: String?, _ detail: String? = nil) -> Tile {
            Tile(kind: kind, title: title, accessory: accessory, status: status, detail: detail, row: row)
        }
        switch row.shape {
        case let .toggle(toggle):
            return make(.toggle(isOn: toggle.isOn), toggle.caption, toggle.detail)
        case let .toggleWithTiming(toggle, _):
            return make(.toggle(isOn: toggle.isOn), toggle.caption, toggle.detail)
        case let .toggleWithSource(toggle, source):
            return make(.toggle(isOn: toggle.isOn), toggle.caption, source.detail)
        case let .tiers(tiers):
            // With no level selected, the status line falls back to the top-right sentence the shape provides (mostly "model default").
            let selected = tiers.options.first { $0.id == tiers.selection }?.label
            return make(.levelCount(tiers.options.count), selected ?? tiers.headerNote)
        case let .notice(notice):
            return make(
                notice.link == nil || notice.cta != nil ? .none : .chevron, notice.status,
                notice.body.isEmpty ? nil : notice.body
            )
        case let .disclosure(disclosure):
            return make(disclosure.action == nil ? .none : .chevron, disclosure.status)
        case let .protocolUndecided(callout):
            return make(.chevron, callout.title, callout.body)
        }
    }

    // MARK: Vision

    /// Entry not visible: unavailable. Visible but a relay connection with no positive evidence: unknown. Otherwise visible: available.
    static func vision(_ input: CapabilityEvidenceFacade.InputCapabilityProjection?) -> VisionState {
        guard let input else { return .unknown }
        if input.visible { return .available }
        if let reason = input.disabledReason { return .unavailable(reason) }
        return .unknown
    }

    static func visionTile(_ state: VisionState) -> Tile {
        let (accessory, status, detail): (Accessory, String, String?) = switch state {
        case .available: (.check, L10n.tr("Available · photo picker shown", table: .chat), nil)
        case .unknown: (.question, L10n.tr("Unknown · remembered after sending", table: .chat), nil)
        case let .unavailable(reason):
            (.cross, L10n.tr("Unavailable", table: .chat), InputCapabilityCopy.disabled(reason, .image))
        }
        return Tile(
            kind: .vision, title: L10n.tr("Vision", table: .chat),
            accessory: accessory, status: status, detail: detail, row: nil
        )
    }

    // MARK: Files

    /// Wire mode off (including an undeterminable wire), no native allow-list for the model, or an unexpired relay `file`
    /// negative cache: converted to text. Otherwise `pdfNativeDefault` means PDF goes native; otherwise supported formats go native.
    static func files(
        mode: NativeFileMode?, nativeFileMimes: [String], relayFileRejected: Bool, pdfNativeDefault: Bool
    ) -> FileState {
        guard let mode, mode != .off, !nativeFileMimes.isEmpty, !relayFileRejected else { return .text }
        return pdfNativeDefault ? .pdfNative : .nativeWhenSupported
    }

    /// All three states show a check: a file can always be delivered, only the way it is delivered differs.
    static func filesTile(_ state: FileState) -> Tile {
        let status: String = switch state {
        case .pdfNative: L10n.tr("PDF native · others as text", table: .chat)
        case .nativeWhenSupported: L10n.tr("Native when supported · others as text", table: .chat)
        case .text: L10n.tr("Sent as text", table: .chat)
        }
        return Tile(
            kind: .files, title: L10n.tr("Files", table: .providers),
            accessory: .check, status: status, detail: nil, row: nil
        )
    }

    // MARK: What this turn sends

    /// Lists only the controls that are on right now: web search on, a selected non-automatic thinking level, or the thinking toggle on.
    static func summaryItems(web: Shape, reasoning: Shape) -> [String] {
        var items: [String] = []
        switch web {
        case let .toggle(toggle) where toggle.isOn, let .toggleWithTiming(toggle, _) where toggle.isOn,
             let .toggleWithSource(toggle, _) where toggle.isOn:
            items.append(L10n.tr("Web search on", table: .chat))
        default:
            break
        }
        switch reasoning {
        case let .tiers(tiers):
            if let selection = tiers.selection, selection != Shape.automaticIntent,
               let label = tiers.options.first(where: { $0.id == selection })?.label {
                items.append(String(format: L10n.tr("Thinking: %@", table: .chat), label))
            }
        case let .toggle(toggle) where toggle.isOn, let .toggleWithTiming(toggle, _) where toggle.isOn:
            items.append(L10n.tr("Thinking on", table: .chat))
        default:
            break
        }
        return items
    }

    static func summaryText(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        return String(format: L10n.tr("This turn will send: %@", table: .chat), items.joined(separator: " · "))
    }

    // MARK: Parameter card

    /// Temperature becomes the first row of the parameter card on its own; the remaining rows go to the "Advanced settings"
    /// entry row as a capsule summary.
    static func splitTemperature(
        _ rows: [GenerationParameterRowModel]
    ) -> (Temperature?, [GenerationParameterRowModel]) {
        guard let row = rows.first(where: { $0.id == "temperature" }) else { return (nil, rows) }
        let temperature = Temperature(
            title: row.title,
            value: row.displayValue ?? GenerationParameterPresentationFacts.unsetLabel(parameterID: row.id)
        )
        return (temperature, rows.filter { $0.id != "temperature" })
    }
}
