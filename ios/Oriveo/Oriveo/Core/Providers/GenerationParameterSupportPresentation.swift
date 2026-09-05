import Foundation

/// Wire identifier → localized product vocabulary. Unknown identifiers deliberately collapse to a
/// translated generic label instead of leaking an underscored protocol token into the UI or VoiceOver.
enum GenerationParameterVocabulary {
    static func title(_ id: String) -> String {
        switch id {
        case "max_output_tokens", "max_tokens": return L10n.tr("Max Tokens", table: .chat)
        case "stop", "stop_sequences": return L10n.tr("Stop", table: .chat)
        case "temperature": return L10n.tr("Temperature", table: .chat)
        case "top_p": return L10n.tr("Top P", table: .chat)
        case "top_k": return L10n.tr("Top K", table: .chat)
        case "min_p": return L10n.tr("Min P", table: .chat)
        case "typical_p": return L10n.tr("Typical P", table: .chat)
        case "top_n_sigma": return L10n.tr("Top-N Sigma", table: .chat)
        case "frequency_penalty": return L10n.tr("Frequency penalty", table: .chat)
        case "presence_penalty": return L10n.tr("Presence penalty", table: .chat)
        case "repeat_penalty": return L10n.tr("Repeat penalty", table: .chat)
        case "repeat_last_n", "min_keep": return L10n.tr("Repeat penalty window", table: .chat)
        case "seed": return L10n.tr("Random seed", table: .chat)
        case "response_format": return L10n.tr("Response format", table: .chat)
        case "json_schema", "json": return L10n.tr("JSON Schema", table: .chat)
        case "verbosity": return L10n.tr("Verbosity", table: .chat)
        case "logprobs": return L10n.tr("Log probabilities", table: .chat)
        case "top_logprobs": return L10n.tr("Top log probabilities", table: .chat)
        case "reasoning_effort": return L10n.tr("Reasoning effort", table: .chat)
        case "reasoning_budget": return L10n.tr("Reasoning budget", table: .chat)
        case "reasoning_mode", "reasoning": return L10n.tr("Reasoning mode", table: .chat)
        case "max_tool_loops": return L10n.tr("Advanced parameter", table: .chat)
        case "route_require_parameters": return L10n.tr("Require parameters on route", table: .chat)
        default: return L10n.tr("Advanced parameter", table: .chat)
        }
    }

    static func source(_ id: String) -> String {
        switch id {
        case "authoritative_metadata", "provider_metadata":
            return L10n.tr("Official configuration", table: .chat)
        case "relay_declared": return L10n.tr("Connection declaration", table: .chat)
        case "local_engine_profile": return L10n.tr("Runtime observation", table: .chat)
        case "operator_override": return L10n.tr("Explicit override", table: .chat)
        default: return L10n.tr("Other source", table: .chat)
        }
    }
}

enum GenerationParameterSupportPresentation {
    enum PresentationClass: String {
        case silent
        case unverified
        case notAdjustable = "not_adjustable"
        case noData = "no_data"
    }

    enum Control: String {
        case editable
        case disabled
    }

    struct Entry: Equatable {
        let presentationClass: PresentationClass
        let renders: Bool
        let control: Control
        let label: String?
        let detail: String?
        let primaryAction: String?
    }

    private static func classLabel(_ presentationClass: PresentationClass) -> String? {
        switch presentationClass {
        case .silent: return nil
        case .unverified: return L10n.tr("Will be sent • effect unverified", table: .providers)
        case .notAdjustable: return L10n.tr("Not adjustable", table: .providers)
        case .noData: return L10n.tr("No data yet", table: .providers)
        }
    }

    static var findSupportedModelsAction: String {
        L10n.tr("View models that support this parameter", table: .providers)
    }

    private static let classBySupport: [String: PresentationClass] = [
        "supported": .silent,
        "accepted": .silent,
        "accepted_unverified": .unverified,
        "fixed": .notAdjustable,
        "unsupported": .notAdjustable,
        "mode_dependent": .notAdjustable,
        "unknown": .noData,
        "future_supported": .notAdjustable,
    ]

    private static func detail(for support: String) -> String? {
        switch support {
        case "accepted_unverified":
            return L10n.tr(
                "This value is sent to the provider as-is, but we have not verified that it takes effect.",
                table: .providers
            )
        case "fixed":
            return L10n.tr("Fixed by the model; changing it has no effect.", table: .providers)
        case "unsupported":
            return L10n.tr("This model does not accept this parameter; sending it will be rejected.", table: .providers)
        case "mode_dependent":
            return L10n.tr("Depends on the current thinking level; it can change when you switch levels.", table: .providers)
        case "unknown":
            return L10n.tr("We do not have official documentation for this parameter yet.", table: .providers)
        case "future_supported":
            return L10n.tr("The provider has announced it but has not shipped it yet.", table: .providers)
        default:
            return nil
        }
    }

    static func entry(forRegistered support: String) -> Entry? {
        guard let presentationClass = classBySupport[support] else { return nil }
        return Entry(
            presentationClass: presentationClass,
            renders: presentationClass != .silent,
            control: presentationClass == .notAdjustable ? .disabled : .editable,
            label: classLabel(presentationClass),
            detail: detail(for: support),
            primaryAction: presentationClass == .notAdjustable ? findSupportedModelsAction : nil
        )
    }

    static func entry(for support: String?) -> Entry {
        guard let support, let entry = entry(forRegistered: support) else {
            return Entry(
                presentationClass: .noData,
                renders: true,
                control: .editable,
                label: classLabel(.noData),
                detail: detail(for: "unknown"),
                primaryAction: nil
            )
        }
        return entry
    }

    static var registeredSupports: Set<String> { Set(classBySupport.keys) }

    static func effectiveSupport(
        declared: String?,
        resolution: CapabilityEvidenceFacade.Resolution?
    ) -> String {
        let declared = declared ?? "unknown"
        if ["unsupported", "fixed", "mode_dependent", "future_supported"].contains(declared) {
            return declared
        }
        if resolution?.support == .unsupported { return "unsupported" }
        if resolution?.support == .supported { return "supported" }
        if declared == "supported" { return "accepted_unverified" }
        return classBySupport[declared] == nil ? "unknown" : declared
    }
}

enum GenerationParameterRowStatus {
    static func note(support: String?, source: String?) -> String? {
        let entry = GenerationParameterSupportPresentation.entry(for: support)
        guard entry.renders else { return nil }
        var parts: [String] = []
        if let label = entry.label { parts.append(label) }
        if let detail = entry.detail { parts.append(detail) }
        var text = parts.joined(separator: " • ")
        if let source, !source.isEmpty {
            text += " • \(L10n.tr("Source")): \(GenerationParameterVocabulary.source(source))"
        }
        return text.isEmpty ? nil : text
    }
}
