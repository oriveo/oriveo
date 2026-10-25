import Foundation

/// Where a tap inside a capability card leads. A shape only names the destination; the panel does the navigation and the writes.
nonisolated enum ModelOptionCapabilityAction: Hashable, Sendable, CaseIterable {
    /// Which models in this connection can adjust this capability.
    case openSupportedModels
    /// The additional request body in advanced settings.
    case openAdditionalRequestBody
    /// The protocol choice in the connection's settings.
    case openConnectionProtocol
    /// Switch to another connection.
    case switchConnection
    /// The relay connection's web search settings page.
    case openConnectionWebSearch
    /// The relay model's Advanced page (re-test after the template is rejected; the test button is on that page and no test starts automatically).
    case openTestCapabilities
}

/// **What to draw** for one capability (web search / thinking) in the model options panel.
///
/// The view layer only switches over these cases and decides no business condition itself. A shape follows from
/// facts that are already resolved: the presentation, the levels delivered by the catalog, writability, whether
/// the protocol is decided, and the levels the upstream rejected. Nothing here reads a singleton or guesses a capability from a provider or model name; without an official configuration it says so and offers a way forward.
///
/// A shape carries no color: tone is expressed as `NoteTone`, and the view layer picks the colors.
nonisolated enum ModelOptionCapabilityShape: Equatable, Sendable {
    /// A toggle.
    case toggle(Toggle)
    /// A row of level segments.
    case tiers(Tiers)
    /// A toggle that is on, plus a timing row below it.
    case toggleWithTiming(Toggle, Timing)
    /// A status at the top right, a paragraph, and a way forward.
    case notice(Notice)
    /// One status row; tappable as a whole when it has a destination.
    case disclosure(Disclosure)
    /// The protocol is undecided: this item and the whole card collapse into that one thing.
    case protocolUndecided(Callout)

    nonisolated enum Capability: String, Sendable {
        case web
        case reasoning
    }

    /// The kind of connection.
    nonisolated enum Connection: Sendable {
        /// An official provider; the official configuration decides the capability.
        case official
        /// A custom LLM or a local engine, with no official configuration.
        case custom
    }

    /// Where flipping the toggle writes.
    nonisolated enum ToggleTarget: Equatable, Sendable {
        /// Writes the capability preference: on = `on`, off = `off`.
        case capabilityPreference(on: String, off: String)
        /// Writes the chat template's thinking switch in the additional request body.
        case chatTemplateThinking
    }

    nonisolated enum NoteTone: Equatable, Sendable {
        case neutral
        case warning
    }

    nonisolated struct Link: Equatable, Sendable {
        let title: String
        let action: ModelOptionCapabilityAction
    }

    nonisolated struct Option: Equatable, Identifiable, Sendable {
        let id: String
        let label: String
    }

    nonisolated struct Toggle: Equatable, Sendable {
        let isOn: Bool
        /// The sentence under the title.
        let caption: String?
        let target: ToggleTarget
        /// A secondary destination attached to this row.
        let link: Link?
        /// false = dimmed and not tappable (relay web search overridden off or rejected).
        var isEnabled: Bool = true
    }

    nonisolated struct Tiers: Equatable, Sendable {
        /// The selectable levels; every segment can be tapped. Rejected levels are not among them.
        let options: [Option]
        /// The selected level; nil = never chosen, no segment is highlighted.
        let selection: String?
        /// Whether the levels include Off. Without it that segment is not drawn.
        let includesOff: Bool
        /// The sentence at the top right.
        let headerNote: String?
        let headerTone: NoteTone
        /// Notes under the segments, joined in order into one paragraph.
        let footnotes: [String]
        /// Levels the upstream rejected, already removed from the segments.
        let rejected: [String]
    }

    nonisolated struct Timing: Equatable, Sendable {
        let options: [Option]
        let selection: String
    }

    nonisolated struct Notice: Equatable, Sendable {
        let status: String
        let body: String
        let link: Link?
    }

    nonisolated struct Disclosure: Equatable, Sendable {
        let status: String
        /// nil = the row is read-only and cannot be tapped.
        let action: ModelOptionCapabilityAction?
    }

    nonisolated struct Callout: Equatable, Sendable {
        let title: String
        let body: String
        let link: Link
    }

    /// Facts behind a relay connection's web search row (fixture web-probe.v1.json `presentationCases`), supplied by `RelayWebProbe.panelFact`.
    nonisolated enum RelayWeb: Equatable, Sendable {
        /// Local engine connection: web search does not apply.
        case localEngine
        /// The first protocol is not decided yet (outside the probe's scope).
        case undecided
        /// A chat switch plus a status line.
        case relay(RelayWebFact)
    }

    nonisolated struct Input: Equatable, Sendable {
        var capability: Capability
        var presentation: CapabilityControlPresentation
        /// Levels delivered by the catalog. For web search, passed only when an official configuration exists.
        var availableIntents: [String] = []
        /// The stored choice: a level for thinking, `off` / `automatic` / `force` for web search; nil = never chosen.
        var selectedIntent: String? = nil
        var connection: Connection = .official
        /// Whether the panel can store a choice right now.
        var isWritable: Bool = true
        /// The custom connection's protocol is still on Auto.
        var protocolUndecided: Bool = false
        /// Levels the upstream has rejected for this model.
        var rejectedIntents: [String] = []
        /// Whether the chat template's thinking switch in the additional request body is on. Only meaningful for thinking on a custom connection.
        var chatTemplateThinkingIsOn: Bool = false
        /// Whether this custom connection's protocol applies a chat template (Chat Completions). Other protocols do not
        /// know `chat_template_kwargs`; sending it there may get the request rejected outright, so the toggle is not offered.
        var supportsChatTemplate: Bool = true
        /// The thinking row of a local connection (one with an engineProfile) follows the write-path table, not the
        /// protocol. nil = not a local connection, or the table has no entry, so the existing Relay rules apply.
        var localEngineThinking: LocalEngineThinking? = nil
        /// Whether the model shows its thinking process (used by read-only thinking rows).
        var showsThinking: Bool = false
        /// Facts for the relay web search row; nil = not a relay connection.
        var relayWeb: RelayWeb? = nil
    }

    /// Value of `showsThinking`: the catalog's explicit truth wins, and the legacy `capabilities` array is the fallback.
    static func showsThinking(provider: Provider, model: AIModel) -> Bool {
        CapabilityDisplayFacts.thinking(provider: provider, model: model)
    }

    /// How the thinking row of a local connection is written.
    nonisolated enum LocalEngineThinking: Equatable, Sendable {
        /// Writable: the chat template thinking switch.
        case chatTemplateToggle
        /// Non-Chat channel (native llama.cpp): keep the existing non-Chat explanation.
        case nonChatNotice
        /// Cannot be written: show the "use the model default" explanation.
        case modelDefault
        /// The engine declares that this model has no thinking.
        case unsupported
    }
}

// MARK: - One item

extension ModelOptionCapabilityShape {
    /// Rendering order of thinking levels: Off first, then from least to most effort.
    static let tierOrder = ["off", "low", "balanced", "deep", "max"]
    /// The Automatic level: the model decides how long to think. Drawn only when the recipe declares it, as the first segment; in storage it is "never chosen" (nil).
    static let automaticIntent = "automatic"

    /// A one-sentence note for each level. It is about what the user gets from it, not the protocol's effort value.
    @MainActor
    static func caption(for intent: String) -> String {
        switch intent {
        case "off": return L10n.tr("Answer right away, no thinking time.", table: .chat)
        case automaticIntent: return L10n.tr("The model decides on its own.", table: .chat)
        case "low": return L10n.tr("Simple questions, fast answers.", table: .chat)
        case "balanced": return L10n.tr("A balance of speed and depth.", table: .chat)
        case "deep": return L10n.tr("Hard questions, take more time.", table: .chat)
        case "max": return L10n.tr("The hardest problems, whatever time it takes.", table: .chat)
        default: return ""
        }
    }

    /// A stored "search every message" that the current configuration no longer has counts as "search when needed".
    ///
    /// Whether a level is in the configuration is only asked when there really is an official configuration: without
    /// one the levels are always empty, and clamping against them would rewrite the user's stored choice just because the snapshot has not arrived.
    static func clampedWebPreference(
        _ selection: CapabilityWebPreference,
        presentation: CapabilityControlPresentation,
        availableIntents: [String]
    ) -> CapabilityWebPreference {
        guard selection == .force else { return selection }
        switch presentation {
        case .automaticAvailable, .forceUnsupported:
            return availableIntents.contains(CapabilityWebPreference.force.rawValue) ? .force : .automatic
        case .alwaysOn, .customOnly, .pending, .externalConnectorOnly, .unsupported, .unknown:
            return selection
        }
    }

    /// Write path of the thinking row on a local connection, looked up by engineProfile x channel
    /// (`engine-expectations.v1.json` `thinking.writePaths`) instead of guessed from the protocol. Only the llama.cpp
    /// Chat channel applies the chat template thinking switch; on other Chat channels it cannot be written, so a model
    /// that declares no thinking is reported as unsupported.
    static func localEngineThinking(provider: Provider, model: AIModel) -> LocalEngineThinking? {
        guard provider.kind == .relay,
              let engine = provider.relayRequested?.engineProfile.flatMap(LocalEngineKind.init(rawValue:)) else {
            return nil
        }
        switch RelayEndpointResolver.explicitTransport(provider: provider, model: model) {
        case .llamacppNative:
            return .nonChatNotice
        case .openaiChatCompletions:
            if engine == .llamacpp { return .chatTemplateToggle }
            return model.engineDeclaration?.thinking == false ? .unsupported : .modelDefault
        default:
            // A channel the table does not know (for example the protocol was changed): hand back to the existing Relay rules.
            return nil
        }
    }

    @MainActor
    static func resolve(_ input: Input) -> Self {
        // The thinking row of a local connection is decided by the write-path table first, regardless of the catalog
        // presentation (the same holds when it inherits an official tier set). Android and Web use the same order.
        if input.connection == .custom, input.capability != .web, let local = input.localEngineThinking {
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            return localEngineThinkingShape(local, input)
        }
        // Relay web search depends only on the connection-level fragment, not on the catalog or the chat's web preference.
        if input.connection == .custom, input.capability == .web, let relayWeb = input.relayWeb {
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            return relayWebShape(relayWeb)
        }
        switch input.presentation {
        case .alwaysOn:
            // Produced only by the web search verdict (`subscription_web_always_on`); the thinking row never gets it.
            assert(input.capability == .web, "alwaysOn is web-only")
            // Release fallback: if the thinking row ever gets it, show the current value instead of borrowing web wording.
            guard input.capability == .web else {
                return .disclosure(.init(status: currentValueText(input), action: nil))
            }
            return alwaysOnWeb()
        case .automaticAvailable, .forceUnsupported:
            // A custom connection that matches an official configuration is handled like an official one.
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            guard input.isWritable else {
                return .disclosure(.init(status: currentValueText(input), action: nil))
            }
            return input.capability == .web ? webControl(input) : reasoningControl(input)
        case .customOnly:
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            return manualSetup(input.capability)
        case .unsupported, .externalConnectorOnly:
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            if input.connection == .custom, input.capability == .web { return connectionCannot() }
            return .disclosure(.init(
                status: input.capability == .web
                    ? L10n.tr("This model can’t search the web", table: .chat)
                    : L10n.tr("This model has no thinking mode", table: .chat),
                action: .openSupportedModels
            ))
        case .pending, .unknown:
            if input.protocolUndecided { return .protocolUndecided(protocolCallout()) }
            if input.connection == .custom {
                if input.capability == .web { return connectionCannot() }
                return input.supportsChatTemplate ? chatTemplateThinkingToggle(input) : manualSetup(.reasoning)
            }
            return noOfficialConfiguration(input.capability)
        }
    }

    // MARK: Thinking

    @MainActor
    private static func reasoningControl(_ input: Input) -> Self {
        let declared = Set(input.availableIntents)
        let rejected = tierOrder.filter { declared.contains($0) && input.rejectedIntents.contains($0) }
        let levels = tierOrder.filter { $0 != "off" && declared.contains($0) }
        let includesOff = declared.contains("off")
        let hasAutomatic = declared.contains(automaticIntent)
        let choiceCount = levels.count + (includesOff ? 1 : 0) + (hasAutomatic ? 1 : 0)

        // Nothing to choose: a single fixed level, or nothing delivered at all.
        guard choiceCount > 1 else {
            return .notice(.init(
                status: L10n.tr("Always thinks before answering", table: .chat),
                body: L10n.tr("This model runs at a fixed thinking level and can’t be adjusted.", table: .chat),
                link: nil
            ))
        }
        // On and off only: a plain toggle.
        if includesOff, levels.count == 1, !hasAutomatic, rejected.isEmpty {
            return .toggle(.init(
                isOn: input.selectedIntent == levels[0],
                caption: L10n.tr("Thinks it through first, so answers take a little longer", table: .chat),
                target: .capabilityPreference(on: levels[0], off: "off"),
                link: nil
            ))
        }

        // Automatic is drawn as the first segment, the rest as before: Off first, then from least to most effort.
        let remaining = ([automaticIntent] + tierOrder).filter { declared.contains($0) && !rejected.contains($0) }
        // Never chosen (or the stored level is no longer in the configuration): highlight Automatic when the configuration has it, otherwise highlight nothing.
        // This only decides what to draw; it does not store a value on the user's behalf.
        let selection = effectiveTier(selected: input.selectedIntent, remaining: remaining, rejected: rejected)
            ?? (hasAutomatic ? automaticIntent : nil)
        let options = remaining.map { Option(id: $0, label: ModelControlIntentLabel.text($0)) }
        let caption = selection.map(caption(for:))
        let modelDefault = L10n.tr("Uses the model’s default", table: .chat)
        let costNote = L10n.tr("Higher levels take longer and may cost more.", table: .chat)

        if !rejected.isEmpty {
            // Names the level the user just picked; when no rejected level was picked, names the highest one.
            let named = rejected.first { $0 == input.selectedIntent } ?? rejected[rejected.count - 1]
            let namedLabel = ModelControlIntentLabel.text(named)
            var footnotes: [String] = []
            if let selection {
                footnotes.append(String(
                    format: L10n.tr(
                        "This model isn’t accepting “%1$@” right now, so it’s back on “%2$@”. The level will return on its own once the model supports it again.",
                        table: .chat
                    ),
                    namedLabel, ModelControlIntentLabel.text(selection)
                ))
            }
            return .tiers(.init(
                options: options, selection: selection, includesOff: remaining.contains("off"),
                headerNote: String(format: L10n.tr("“%@” was rejected", table: .chat), namedLabel),
                headerTone: .warning, footnotes: footnotes, rejected: rejected
            ))
        }
        if includesOff {
            return .tiers(.init(
                options: options, selection: selection, includesOff: true,
                headerNote: caption ?? modelDefault, headerTone: .neutral, footnotes: [], rejected: []
            ))
        }
        // Cannot be turned off: no dead Off segment, just a note at the top right.
        guard let caption else {
            return .tiers(.init(
                options: options, selection: nil, includesOff: false,
                headerNote: modelDefault, headerTone: .neutral, footnotes: [costNote], rejected: []
            ))
        }
        return .tiers(.init(
            options: options, selection: selection, includesOff: false,
            headerNote: L10n.tr("Always thinks before answering", table: .chat),
            headerTone: .neutral, footnotes: [caption, costNote], rejected: []
        ))
    }

    /// When the selected level has been rejected, falls to the nearest remaining level: lower first, then higher.
    /// Off takes no part in this: a rejected level must not switch thinking off along the way.
    private static func effectiveTier(selected: String?, remaining: [String], rejected: [String]) -> String? {
        guard let selected else { return nil }
        if remaining.contains(selected) { return selected }
        guard rejected.contains(selected), let index = tierOrder.firstIndex(of: selected) else { return nil }
        let levels = remaining.filter { $0 != "off" && $0 != automaticIntent }
        let lower = tierOrder[..<index].reversed().first { levels.contains($0) }
        return lower ?? tierOrder[(index + 1)...].first { levels.contains($0) }
    }

    @MainActor
    private static func chatTemplateThinkingToggle(_ input: Input) -> Self {
        // While the panel is read-only, show the current value instead of a toggle that cannot be flipped.
        guard input.isWritable else {
            return .disclosure(.init(
                status: input.chatTemplateThinkingIsOn
                    ? L10n.tr("On", table: .chat)
                    : ModelControlIntentLabel.text("off"),
                action: nil
            ))
        }
        return .toggle(.init(
            isOn: input.chatTemplateThinkingIsOn,
            caption: L10n.tr(
                "Turns thinking on or off through the chat template. Whether it works depends on your server.",
                table: .chat
            ),
            target: .chatTemplateThinking,
            link: additionalRequestBodyLink()
        ))
    }

    // MARK: Web search

    @MainActor
    private static func webControl(_ input: Input) -> Self {
        let automatic = CapabilityWebPreference.automatic.rawValue
        let force = CapabilityWebPreference.force.rawValue
        let supportsForce = input.availableIntents.contains(force)
        // A stored "search every message" that the current configuration no longer has counts as "search when needed".
        let isOn = input.selectedIntent == automatic || input.selectedIntent == force
        let target = ToggleTarget.capabilityPreference(on: automatic, off: CapabilityWebPreference.off.rawValue)
        guard isOn, supportsForce else {
            return .toggle(.init(
                isOn: isOn,
                caption: L10n.tr("Searches the web first when a question needs it", table: .chat),
                target: target, link: nil
            ))
        }
        // When the timing row appears below, no caption sits under the title.
        return .toggleWithTiming(.init(isOn: true, caption: nil, target: target, link: nil), .init(
            options: [
                Option(id: automatic, label: ModelControlIntentLabel.webText(.automatic)),
                Option(id: force, label: ModelControlIntentLabel.webText(.force)),
            ],
            selection: input.selectedIntent == force ? force : automatic
        ))
    }

    /// Searches the web on every turn and the user cannot turn it off: a read-only note that is not tappable.
    @MainActor
    private static func alwaysOnWeb() -> Self {
        .notice(.init(
            status: L10n.tr("Always on", table: .chat),
            body: L10n.tr("This subscription always searches the web for this model.", table: .chat),
            link: nil
        ))
    }

    @MainActor
    private static func relayWebShape(_ relayWeb: RelayWeb) -> Self {
        switch relayWeb {
        case .localEngine:
            return connectionCannot()
        case .undecided:
            return .protocolUndecided(protocolCallout())
        case let .relay(fact):
            let link: Link? = fact.retestLink.map { action in
                action == .openConnectionWebSearch
                    ? .init(title: L10n.tr("Test again in Web Search", table: .chat), action: action)
                    : .init(title: L10n.tr("Test capabilities", table: .providers), action: action)
            }
            return .toggle(.init(
                isOn: fact.isOn,
                caption: relayWebStatusText(fact.statusId),
                target: .capabilityPreference(on: CapabilityWebPreference.automatic.rawValue, off: CapabilityWebPreference.off.rawValue),
                link: link,
                isEnabled: fact.row == .toggle
            ))
        }
    }

    /// Relay web search status id to copy (web_user_on uses the source badge "Set by you").
    @MainActor
    static func relayWebStatusText(_ status: RelayWebFact.StatusID) -> String {
        switch status {
        case .searched: L10n.tr("Search confirmed", table: .chat)
        case .silent: L10n.tr("Didn’t search when tested", table: .chat)
        case .rejected: L10n.tr("This model rejects the web search settings", table: .chat)
        case .unverified: L10n.tr("Set · not verified", table: .chat)
        case .untested: L10n.tr("Not tested yet", table: .providers)
        case .userOff: L10n.tr("Turned off in this model’s Advanced settings", table: .providers)
        case .userOn: L10n.tr("Set by you", table: .providers)
        }
    }

    @MainActor
    private static func localEngineThinkingShape(_ local: LocalEngineThinking, _ input: Input) -> Self {
        switch local {
        case .chatTemplateToggle: return chatTemplateThinkingToggle(input)
        case .nonChatNotice: return manualSetup(.reasoning)
        case .modelDefault: return noOfficialConfiguration(.reasoning)
        case .unsupported:
            return .disclosure(.init(
                status: L10n.tr("This model has no thinking mode", table: .chat),
                action: .openSupportedModels
            ))
        }
    }

    @MainActor
    private static func connectionCannot() -> Self {
        .disclosure(.init(
            status: L10n.tr("This connection can’t do this", table: .chat), action: .switchConnection
        ))
    }

    // MARK: Shared

    @MainActor
    private static func noOfficialConfiguration(_ capability: Capability) -> Self {
        // `Link` here is a way forward inside a shape, not SwiftUI's `Link` control; written as `.init` so it is not mistaken for the latter.
        let link: Link = .init(
            title: L10n.tr("See which models can be adjusted", table: .chat), action: .openSupportedModels
        )
        switch capability {
        case .reasoning:
            return .notice(.init(
                status: L10n.tr("Uses the model’s default", table: .chat),
                body: L10n.tr(
                    "Oriveo doesn’t have thinking settings for this model yet, so it runs on its own default.",
                    table: .chat
                ),
                link: link
            ))
        case .web:
            return .notice(.init(
                status: L10n.tr("Not available yet", table: .chat),
                body: L10n.tr(
                    "Oriveo doesn’t have web search settings for this model yet, so it can’t be turned on here.",
                    table: .chat
                ),
                link: link
            ))
        }
    }

    /// No standard switch: says the fields go into the additional request body and offers the way there.
    @MainActor
    private static func manualSetup(_ capability: Capability) -> Self {
        .notice(.init(
            status: L10n.tr("Needs manual setup", table: .chat),
            body: capability == .web
                ? L10n.tr(
                    "This provider has no standard switch for web search. Add its fields in the additional request body.",
                    table: .chat
                )
                : L10n.tr(
                    "This provider has no standard switch for thinking. Add its fields in the additional request body.",
                    table: .chat
                ),
            link: additionalRequestBodyLink()
        ))
    }

    @MainActor
    private static func additionalRequestBodyLink() -> Link {
        .init(title: L10n.tr("Open additional request body", table: .chat), action: .openAdditionalRequestBody)
    }

    @MainActor
    static func protocolCallout() -> Callout {
        Callout(
            title: L10n.tr("Choose this connection’s protocol first", table: .chat),
            body: L10n.tr(
                "The protocol is still set to Auto, so Oriveo can’t tell how to send web search and thinking settings.",
                table: .chat
            ),
            link: .init(title: L10n.tr("Choose protocol", table: .chat), action: .openConnectionProtocol)
        )
    }

    /// The current value shown on the row while the panel is read-only.
    @MainActor
    private static func currentValueText(_ input: Input) -> String {
        switch input.capability {
        case .web:
            let preference = input.selectedIntent.flatMap(CapabilityWebPreference.init(rawValue:)) ?? .off
            return ModelControlIntentLabel.webText(preference)
        case .reasoning:
            if let selected = input.selectedIntent { return ModelControlIntentLabel.text(selected) }
            return input.availableIntents.contains(automaticIntent)
                ? ModelControlIntentLabel.text(automaticIntent)
                : L10n.tr("Uses the model’s default", table: .chat)
        }
    }
}

// MARK: - The whole card

/// The capability card as a whole: normally two rows, web search and thinking; with an undecided protocol the card collapses into one thing.
nonisolated enum ModelOptionCapabilityCard: Equatable, Sendable {
    case rows(web: ModelOptionCapabilityShape, reasoning: ModelOptionCapabilityShape)
    case protocolUndecided(ModelOptionCapabilityShape.Callout)

    @MainActor
    static func resolve(
        web: ModelOptionCapabilityShape.Input, reasoning: ModelOptionCapabilityShape.Input
    ) -> Self {
        let webShape = ModelOptionCapabilityShape.resolve(web)
        let reasoningShape = ModelOptionCapabilityShape.resolve(reasoning)
        // When both rows are stuck on the protocol, show that one thing instead of two dead rows.
        if case let .protocolUndecided(callout) = webShape, case .protocolUndecided = reasoningShape {
            return .protocolUndecided(callout)
        }
        return .rows(web: webShape, reasoning: reasoningShape)
    }
}
