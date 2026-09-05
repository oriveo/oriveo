import Foundation



nonisolated enum ModelControlCapabilityEscape: Equatable, Sendable {
    case none
    case supportedModels
    case advancedSettings
}


struct ModelControlTier: Equatable, Identifiable {
    let id: String
    let label: String
    let isEnabled: Bool
    let unavailableReason: String?
}


enum ModelControlReasoningLayout {
    static let automaticIntent = "automatic"
    static let tierOrder = ["off", "low", "balanced", "deep", "max"]

    enum Form: Equatable, Sendable {
        case pillRow
        case statusRow
    }

    struct Layout: Equatable {
        let form: Form
        let options: [ModelControlIntentOption]
        let selection: String
        let selectedAnnotation: String
        let footnote: String?
        let statusText: String
        let explanation: String?
        let escape: ModelControlCapabilityEscape
    }

    /// - Parameters:
    static func layout(
        status: CapabilityControlPresentation,
        intents: [String],
        selectedIntent: String?,
        isEditable: Bool,
        hasCustomSchema: Bool = true
    ) -> Layout {
        let selection = selectedIntent ?? automaticIntent
        switch status {
        case .unsupported, .externalConnectorOnly:
            return statusRow(
                text: L10n.tr("Not supported by this model", table: .chat),
                explanation: L10n.tr("This capability is unavailable for this connection.", table: .chat),
                escape: .supportedModels,
                selection: selection
            )
        case .customOnly:
            let text = L10n.tr("This connection supports custom configuration only.", table: .chat)
            return statusRow(
                text: text, explanation: text,
                escape: hasCustomSchema ? .advancedSettings : .supportedModels,
                selection: selection
            )
        case .pending, .unknown:
            return statusRow(
                text: L10n.tr("Cannot adjust yet", table: .chat),
                explanation: L10n.tr(
                    "This model has no official thinking configuration yet. Oriveo doesn’t guess.",
                    table: .chat
                ),
                escape: .supportedModels,
                selection: selection
            )
        case .automaticAvailable, .forceUnsupported:
            guard isEditable else {
                return statusRow(
                    text: ModelControlIntentLabel.text(selection),
                    explanation: nil, escape: .none, selection: selection
                )
            }
            guard !intents.isEmpty else {
                return statusRow(
                    text: fixedTierNote(), explanation: nil, escape: .none, selection: selection
                )
            }
            return pillRow(intents: intents, selection: selection)
        }
    }

    private static func pillRow(intents: [String], selection: String) -> Layout {
        let available = Set(intents)
        var options: [ModelControlIntentOption] = []
        if available.contains("off") { options.append(option(for: "off")) }
        options.append(option(for: automaticIntent))
        for id in tierOrder where id != "off" && available.contains(id) {
            options.append(option(for: id))
        }
        let effective = options.contains { $0.id == selection } ? selection : automaticIntent
        return Layout(
            form: .pillRow,
            options: options,
            selection: effective,
            selectedAnnotation: caption(for: effective),
            footnote: available.contains("off") ? nil : cannotTurnOffNote(intents: intents),
            statusText: "",
            explanation: nil,
            escape: .none
        )
    }

    private static func cannotTurnOffNote(intents: [String]) -> String? {
        ModelControlReasoningNotes.all(isConfigurable: true, intents: intents)
            .first { $0.kind == .cannotTurnOff }?
            .text
    }

    private static func fixedTierNote() -> String {
        ModelControlReasoningNotes.all(isConfigurable: true, intents: [])
            .first { $0.kind == .fixedTier }?
            .text ?? ""
    }

    private static func option(for intent: String) -> ModelControlIntentOption {
        ModelControlIntentOption(id: intent, label: ModelControlIntentLabel.text(intent))
    }

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

    private static func statusRow(
        text: String, explanation: String?, escape: ModelControlCapabilityEscape, selection: String
    ) -> Layout {
        Layout(
            form: .statusRow, options: [], selection: selection, selectedAnnotation: "",
            footnote: nil, statusText: text, explanation: explanation, escape: escape
        )
    }
}


enum ModelControlCapabilityFooter {
    enum Context: Equatable, Sendable {
        case panelCard
        case behaviorPageHeader
    }

    enum Tone: Equatable, Sendable {
        case tertiary
        case warning
    }

    enum Entry: Equatable {
        case note(text: String, systemImage: String?, tone: Tone)
        case supportedModelsLink
        case advancedSettingsLink
    }

    struct Input {
        var context: Context = .panelCard
        var overridden: Bool = false
        var readOnlyReason: String?
        var isConfigurable: Bool = true
        var statusText: String = ""
        var upstreamRejected: Bool = false
        var riskTiers: [String] = []
        var showsSupportedModelsAction: Bool = false
        var hasSupportedModelCandidates: Bool = false
        var showsAdvancedSettingsAction: Bool = false
        var statusRowEscape: ModelControlCapabilityEscape = .none
    }

    static func entries(_ input: Input) -> [Entry] {
        var entries: [Entry] = []

        let showsSupportedModels = !input.overridden && input.showsSupportedModelsAction
            && input.statusRowEscape != .supportedModels
        let saysNoCandidates = showsSupportedModels && !input.hasSupportedModelCandidates

        if input.overridden {
            entries.append(.note(
                text: L10n.tr(
                    "Custom request fields are on for this control, so the preference above is not sent.",
                    table: .chat
                ),
                systemImage: "curlybraces",
                tone: .warning
            ))
        } else if let readOnlyReason = input.readOnlyReason {
            if input.context == .behaviorPageHeader {
                entries.append(.note(text: readOnlyReason, systemImage: "lock.fill", tone: .tertiary))
            }
        } else if !input.isConfigurable, !saysNoCandidates, input.context == .behaviorPageHeader {
            entries.append(.note(text: input.statusText, systemImage: nil, tone: .tertiary))
        }

        if input.upstreamRejected {
            entries.append(.note(
                text: L10n.tr(
                    "The provider rejected this setting for this model. Send again without it, or pick another model.",
                    table: .chat
                ),
                systemImage: "xmark.octagon",
                tone: .warning
            ))
        }

        if input.overridden || input.context == .behaviorPageHeader {
            for tier in input.riskTiers {
                let privacy = tier == "privacy_impacting"
                entries.append(.note(
                    text: privacy
                        ? L10n.tr("This field can send your data to a third-party service.", table: .chat)
                        : L10n.tr("This field can increase what the provider charges.", table: .chat),
                    systemImage: privacy ? "hand.raised.fill" : "creditcard.fill",
                    tone: .warning
                ))
            }
        }

        if showsSupportedModels {
            entries.append(
                saysNoCandidates
                    ? .note(
                        text: L10n.tr(
                            "No models in this connection support this capability yet.", table: .chat
                        ),
                        systemImage: nil,
                        tone: .tertiary
                    )
                    : .supportedModelsLink
            )
        }

        if input.showsAdvancedSettingsAction {
            entries.append(.advancedSettingsLink)
        }

        return entries
    }
}


enum ModelControlWebLayout {
    enum Form: Equatable, Sendable {
        case toggle
        case statusRow
    }

    struct Layout: Equatable {
        let form: Form
        let isOn: Bool
        let caption: String?
        let timingOptions: [ModelControlIntentOption]
        let timingSelection: String
        let statusText: String
        let explanation: String?
        let escape: ModelControlCapabilityEscape
        let effectiveSelection: CapabilityWebPreference
    }

    static func clamp(
        _ selection: CapabilityWebPreference,
        status: CapabilityControlPresentation,
        availableIntents: [String]
    ) -> CapabilityWebPreference {
        guard selection == .force else { return selection }
        switch status {
        case .automaticAvailable, .forceUnsupported:
            return availableIntents.contains(CapabilityWebPreference.force.rawValue) ? .force : .automatic
        case .customOnly, .pending, .externalConnectorOnly,
             .unsupported, .unknown:
            return selection
        }
    }

    static func layout(
        status: CapabilityControlPresentation,
        availableIntents: [String],
        selection rawSelection: CapabilityWebPreference,
        isEditable: Bool,
        hasCustomSchema: Bool = true
    ) -> Layout {
        let selection = clamp(rawSelection, status: status, availableIntents: availableIntents)
        switch status {
        case .unsupported, .externalConnectorOnly:
            return statusRow(
                text: L10n.tr("Not supported by this model", table: .chat),
                explanation: L10n.tr(
                    "This model has no official web search configuration. Oriveo doesn’t guess, to avoid failed requests.",
                    table: .chat
                ),
                escape: .supportedModels,
                selection: selection
            )
        case .customOnly:
            let text = L10n.tr("This connection supports custom configuration only.", table: .chat)
            return statusRow(
                text: text, explanation: text,
                escape: hasCustomSchema ? .advancedSettings : .supportedModels,
                selection: selection
            )
        case .pending, .unknown:
            return statusRow(
                text: L10n.tr("Cannot adjust yet", table: .chat),
                explanation: L10n.tr(
                    "This model has no official web search configuration. Oriveo doesn’t guess, to avoid failed requests.",
                    table: .chat
                ),
                escape: .supportedModels,
                selection: selection
            )
        case .automaticAvailable, .forceUnsupported:
            guard isEditable else {
                return statusRow(
                    text: ModelControlIntentLabel.webText(selection),
                    explanation: nil, escape: .none, selection: selection
                )
            }
            return toggle(availableIntents: availableIntents, selection: selection)
        }
    }

    private static func toggle(
        availableIntents: [String],
        selection: CapabilityWebPreference
    ) -> Layout {
        let isOn = selection != .off
        let supportsForce = availableIntents.contains(CapabilityWebPreference.force.rawValue)
        return Layout(
            form: .toggle,
            isOn: isOn,
            caption: L10n.tr(
                "When on, the model searches the web when it helps before answering.", table: .chat
            ),
            timingOptions: isOn && supportsForce ? timingOptions() : [],
            timingSelection: (selection == .force ? CapabilityWebPreference.force : .automatic).rawValue,
            statusText: "",
            explanation: nil,
            escape: .none,
            effectiveSelection: selection
        )
    }

    private static func timingOptions() -> [ModelControlIntentOption] {
        [
            ModelControlIntentOption(
                id: CapabilityWebPreference.automatic.rawValue,
                label: L10n.tr("Search when needed", table: .chat)
            ),
            ModelControlIntentOption(
                id: CapabilityWebPreference.force.rawValue,
                label: L10n.tr("Search every message", table: .chat)
            ),
        ]
    }

    private static func statusRow(
        text: String,
        explanation: String?,
        escape: ModelControlCapabilityEscape,
        selection: CapabilityWebPreference
    ) -> Layout {
        Layout(
            form: .statusRow,
            isOn: selection != .off,
            caption: nil,
            timingOptions: [],
            timingSelection: (selection == .force ? CapabilityWebPreference.force : .automatic).rawValue,
            statusText: text,
            explanation: explanation,
            escape: escape,
            effectiveSelection: selection
        )
    }
}
