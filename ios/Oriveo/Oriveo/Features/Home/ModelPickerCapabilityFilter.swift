import Foundation

/// `ModelCapabilityEvidencePresentation` → `CapabilityControlResolution.resolve`.
enum ModelPickerCapabilityFilter {
    enum Capability: String, CaseIterable, Identifiable, Hashable {
        case web
        case reasoning

        var id: String { rawValue }

        var modelCapability: ModelCapability {
            switch self {
            case .web: return .web
            case .reasoning: return .reasoning
            }
        }

        var symbolName: String {
            switch self {
            case .web: return "globe"
            case .reasoning: return "brain"
            }
        }

        var chipTitle: String {
            switch self {
            case .web: return L10n.tr("Can search the web", table: .providers)
            case .reasoning: return L10n.tr("Can think", table: .providers)
            }
        }

        var badgeAccessibilityLabel: String {
            switch self {
            case .web: return L10n.tr("Web")
            case .reasoning: return L10n.tr("Reasoning", table: .providers)
            }
        }
    }

    static func intentCapabilities(model: AIModel, provider: Provider) -> [Capability] {
        intentCapabilities(visibleCapabilities: visibleCapabilities(model: model, provider: provider))
    }

    static func intentCapabilities(visibleCapabilities: [ModelCapability]) -> [Capability] {
        Capability.allCases.filter { visibleCapabilities.contains($0.modelCapability) }
    }

    static func visibleCapabilities(model: AIModel, provider: Provider) -> [ModelCapability] {
        model.visibleMetadataCapabilities(
            provider: provider,
            maxCapabilities: ModelCapability.allCases.count
        )
    }

    static func matches(model: AIModel, provider: Provider, capability: Capability) -> Bool {
        intentCapabilities(model: model, provider: provider).contains(capability)
    }

    static func counts(sections: [ModelPickerSection]) -> [Capability: Int] {
        var result: [Capability: Int] = [:]
        for capability in Capability.allCases {
            result[capability] = sections.reduce(0) { partial, section in
                partial + section.models.reduce(0) { inner, model in
                    inner + (matches(model: model, provider: section.provider, capability: capability) ? 1 : 0)
                }
            }
        }
        return result
    }

    static func apply(
        sections: [ModelPickerSection], active: Set<Capability>
    ) -> [ModelPickerSection] {
        guard !active.isEmpty else { return sections }
        return sections.compactMap { section in
            let models = section.models.filter { model in
                active.allSatisfy { matches(model: model, provider: section.provider, capability: $0) }
            }
            return models.isEmpty ? nil : ModelPickerSection(provider: section.provider, models: models)
        }
    }
}
