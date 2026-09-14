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

    /// `providerID/modelID` -> that row's intent badges, so each model builds its capability
    /// presentation once. Counts walk the catalog once per capability, and with a chip selected the
    /// filter re-runs over the whole catalog on every body evaluation (typing a search, expanding or
    /// collapsing a group); evaluating row by row that is over a thousand presentations for 810
    /// models. The rule is still only `intentCapabilities`.
    typealias IntentIndex = [String: [Capability]]

    static func indexKey(providerID: UUID, modelID: String) -> String {
        "\(providerID.uuidString)/\(modelID)"
    }

    /// A model id repeated under the same provider (a messy relay catalog) stays out of the index and
    /// is evaluated row by row, so two same-named models with different declarations never share a result.
    static func intentIndex(sections: [ModelPickerSection]) -> IntentIndex {
        var index: IntentIndex = [:]
        var duplicated: Set<String> = []
        for section in sections {
            for model in section.models {
                let key = indexKey(providerID: section.provider.id, modelID: model.id)
                guard !duplicated.contains(key) else { continue }
                if index[key] != nil {
                    index.removeValue(forKey: key)
                    duplicated.insert(key)
                    continue
                }
                index[key] = intentCapabilities(model: model, provider: section.provider)
            }
        }
        return index
    }

    private static func intentCapabilities(
        model: AIModel, provider: Provider, index: IntentIndex
    ) -> [Capability] {
        index[indexKey(providerID: provider.id, modelID: model.id)]
            ?? intentCapabilities(model: model, provider: provider)
    }

    static func counts(sections: [ModelPickerSection], index: IntentIndex = [:]) -> [Capability: Int] {
        var result = Dictionary(uniqueKeysWithValues: Capability.allCases.map { ($0, 0) })
        for section in sections {
            for model in section.models {
                for capability in intentCapabilities(model: model, provider: section.provider, index: index) {
                    result[capability, default: 0] += 1
                }
            }
        }
        return result
    }

    static func apply(
        sections: [ModelPickerSection], active: Set<Capability>, index: IntentIndex = [:]
    ) -> [ModelPickerSection] {
        guard !active.isEmpty else { return sections }
        return sections.compactMap { section in
            let models = section.models.filter { model in
                let intent = intentCapabilities(model: model, provider: section.provider, index: index)
                return active.allSatisfy { intent.contains($0) }
            }
            return models.isEmpty ? nil : ModelPickerSection(provider: section.provider, models: models)
        }
    }
}
