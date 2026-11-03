import Foundation

/// `ModelCapabilityEvidencePresentation` → `CapabilityControlResolution.resolve`.
enum ModelPickerCapabilityFilter {
    enum Capability: String, CaseIterable, Identifiable, Hashable {
        case web
        case reasoning
        /// Realtime voice: not a text-model capability; it only filters the realtime rows of the picker, and no chip appears when this context has no realtime rows.
        case realtime

        var id: String { rawValue }

        /// The realtime chip maps to no text-model capability (nil), so text rows never light its badge.
        var modelCapability: ModelCapability? {
            switch self {
            case .web: return .web
            case .reasoning: return .reasoning
            case .realtime: return nil
            }
        }

        var pickerFilter: RealtimeModelPolicy.PickerFilter {
            switch self {
            case .web: return .webSearch
            case .reasoning: return .thinking
            case .realtime: return .realtime
            }
        }

        var symbolName: String {
            switch self {
            case .web: return "globe"
            case .reasoning: return "brain"
            case .realtime: return "waveform"
            }
        }

        var chipTitle: String {
            switch self {
            case .web: return L10n.tr("Can search the web", table: .providers)
            case .reasoning: return L10n.tr("Can think", table: .providers)
            case .realtime: return L10n.tr("Realtime Voice", table: .voice)
            }
        }
    }

    static func intentCapabilities(model: AIModel, provider: Provider) -> [Capability] {
        intentCapabilities(visibleCapabilities: visibleCapabilities(model: model, provider: provider))
    }

    static func intentCapabilities(visibleCapabilities: [ModelCapability]) -> [Capability] {
        Capability.allCases.filter { capability in
            capability.modelCapability.map(visibleCapabilities.contains) ?? false
        }
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
            result[.realtime, default: 0] += section.realtimeModels.count
        }
        return result
    }

    /// Whether this context has any realtime row (the realtime chip checks only this).
    static func showsRealtimeFilter(sections: [ModelPickerSection]) -> Bool {
        sections.contains { !$0.realtimeModels.isEmpty }
    }

    /// When several chips are selected, the filter takes the **intersection** ("both web search and thinking"), the usual filter semantics.
    /// Empty set = no filtering, returned as-is.
    ///
    /// The intersection and "drop groups emptied by the filter" are decided by `RealtimeModelPolicy.pickerRows` (same contract as Android / Web):
    /// realtime rows carry neither web search nor thinking, so selecting them together is empty; the realtime chip keeps only realtime rows; without realtime rows the realtime chip is ignored.
    static func apply(
        sections: [ModelPickerSection], active: Set<Capability>, index: IntentIndex = [:]
    ) -> [ModelPickerSection] {
        guard !active.isEmpty else { return sections }
        // Groups and text rows are keyed by index: the Relay catalog can hold the same id twice, and looking up by id would merge two same-named rows that declare different things;
        // realtime rows are already resolved by context and connection when the groups are built, so each group hands its catalog over unchanged here.
        var catalog: RealtimeModelPolicy.RealtimeCatalog = [:]
        let connections = sections.enumerated().map { sectionIndex, section in
            let key = String(sectionIndex)
            catalog[key] = section.realtimeModels.map { RealtimeModelPolicy.RealtimeCatalogEntry(model: $0, isDefault: false) }
            return RealtimeModelPolicy.Connection(
                id: key,
                providerKind: key,
                auth: .apiKey,
                textModels: section.models.enumerated().map { modelIndex, model in
                    let intent = intentCapabilities(model: model, provider: section.provider, index: index)
                    return RealtimeModelPolicy.TextModel(
                        model: String(modelIndex),
                        webSearch: intent.contains(.web),
                        thinking: intent.contains(.reasoning)
                    )
                }
            )
        }
        let result = RealtimeModelPolicy.pickerRows(RealtimeModelPolicy.PickerInput(
            context: .chat,
            filters: Capability.allCases.filter(active.contains).map(\.pickerFilter),
            connections: connections,
            realtimeCatalog: catalog
        ))
        // A provider with no models left disappears entirely; keeping an empty heading would look more like a bug than dropping it.
        return result.groups.compactMap { group in
            guard let sectionIndex = Int(group.connectionId), sections.indices.contains(sectionIndex) else { return nil }
            let section = sections[sectionIndex]
            let models = group.rows.compactMap { row -> AIModel? in
                guard row.kind == .text, let modelIndex = Int(row.model), section.models.indices.contains(modelIndex) else {
                    return nil
                }
                return section.models[modelIndex]
            }
            let realtime = group.rows.filter { $0.kind == .realtime }.map(\.model)
            return ModelPickerSection(provider: section.provider, models: models, realtimeModels: realtime)
        }
    }
}
