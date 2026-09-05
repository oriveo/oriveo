import Foundation

nonisolated enum GenerationParameterLifecycleState: String, Sendable, Equatable {
    case active
    case dormant
}

enum GenerationParameterLifecycle {
    struct Partition: Equatable, Sendable {
        var active: GenerationParameterOverrides
        var dormant: GenerationParameterOverrides
        var dormantIDs: [String]
    }

    static func state(
        provider: Provider,
        model: AIModel,
        parameter: GenerationParameterRef,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        hasExplicitValue: Bool = false,
    ) -> GenerationParameterLifecycleState {
        let projection = GenerationParameterAvailability.projection(
            provider: provider,
            model: model,
            identity: identity,
            explicitParameterIDs: hasExplicitValue ? Set([parameter.id].compactMap { $0 }) : []
        )
        guard let id = parameter.id,
              let wire = projection.profile?.wire?[id],
              !wire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .dormant
        }
        let active = if hasExplicitValue {
            projection.permitsOutbound(id)
        } else {
            projection.isEditable(parameter)
        }
        return active
            ? .active
            : .dormant
    }

    static func activeParameterIDs(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = [],
    ) -> Set<String> {
        let projection = GenerationParameterAvailability.projection(
            provider: provider,
            model: model,
            identity: identity,
            explicitParameterIDs: explicitParameterIDs
        )
        guard let profile = projection.profile else { return [] }
        var result: Set<String> = []
        for parameter in profile.parameters ?? [] {
            guard let id = parameter.id,
                  let wire = profile.wire?[id],
                  !wire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let isActive = explicitParameterIDs.contains(id)
                ? projection.permitsOutbound(id)
                : projection.isEditable(parameter)
            if isActive { result.insert(id) }
        }
        return result
    }

    /// (`generation_parameter_contract.v1.json#lifecycleRules`).
    static func explicitParameterIDs(in values: GenerationParameterOverrides) -> Set<String> {
        Set(values.values.compactMap { key, value in value.state == .inherit ? nil : key })
    }

    static func partition(
        provider: Provider,
        model: AIModel,
        values: GenerationParameterOverrides,
        identity: CapabilityEvidenceRequestIdentity? = nil,
    ) -> Partition {
        let explicit = explicitParameterIDs(in: values)
        return partition(
            activeParameterIDs: activeParameterIDs(
                provider: provider,
                model: model,
                identity: identity,
                explicitParameterIDs: explicit,
            ),
            values: values
        )
    }

    static func partition(
        activeParameterIDs: Set<String>,
        values: GenerationParameterOverrides
    ) -> Partition {
        var active: [String: GenerationParameterOverride] = [:]
        var dormant: [String: GenerationParameterOverride] = [:]
        for (id, override) in values.values {
            if activeParameterIDs.contains(id) {
                active[id] = override
                continue
            }
            if override.state == .inherit {
                active[id] = override
                continue
            }
            dormant[id] = override
        }
        return Partition(
            active: .init(values: active),
            dormant: .init(values: dormant),
            dormantIDs: dormant.keys.sorted()
        )
    }
}
