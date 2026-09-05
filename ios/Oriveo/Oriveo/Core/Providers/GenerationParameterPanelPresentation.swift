import Foundation

nonisolated enum GenerationParameterEmptyState: String, Sendable, Equatable, CaseIterable {
    case notVerified
    case catalogManaged
    case allUnsupported

    var title: String {
        switch self {
        case .notVerified:
            return L10n.tr("No adjustable parameters for this model yet", table: .providers)
        case .catalogManaged:
            return L10n.tr("This model's parameters are now managed by the official catalog and can't be customized here.", table: .providers)
        case .allUnsupported:
            return L10n.tr("This model doesn't accept adjustable parameters on this connection.", table: .providers)
        }
    }

    var detail: String? {
        guard self == .notVerified else { return nil }
        return L10n.tr(
            "We only enable controls after we've verified a parameter actually takes effect, and we haven't tested this model on this connection. Its reasoning ability is unaffected.",
            table: .providers
        )
    }

}

nonisolated enum GenerationParameterPanelPresentation {

    static func visibleParameters(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> [GenerationParameterRef] {
        switch scope {
        case .session:
            return GenerationParameterAvailability.sessionActionable(
                provider: provider, model: model, identity: identity
            )
        case .connectionDefaults:
            return GenerationParameterAvailability.connectionConfigurable(
                provider: provider,
                model: model,
                identity: identity
            )
        }
    }

    static func emptyState(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        hasSeenNonEmptyProfile: Bool,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) -> GenerationParameterEmptyState? {
        let visible = visibleParameters(
            provider: provider,
            model: model,
            scope: scope,
            identity: identity
        )
        guard visible.isEmpty else { return nil }

        let declared = GenerationParameterAvailability.profile(
            provider: provider, model: model, identity: identity
        )?.parameters ?? []
        if declared.isEmpty {
            return hasSeenNonEmptyProfile ? .catalogManaged : .notVerified
        }

        return .allUnsupported
    }

    static func showsUnverifiedBadge(
        parameter: GenerationParameterRef,
        projection: GenerationParameterEvidenceProjection
    ) -> Bool {
        if let id = parameter.id, let resolution = projection.resolution(for: id) {
            return resolution.support == .unknown
                && resolution.source == .relayDeclaration
                && (resolution.grade == .acceptedUnverified || resolution.grade == .declared)
        }
        return false
    }

    static func showsUnverifiedGroupNote(
        parameters: [GenerationParameterRef],
        projection: GenerationParameterEvidenceProjection
    ) -> Bool {
        parameters.contains {
            showsUnverifiedBadge(parameter: $0, projection: projection)
        }
    }
}

final class GenerationParameterProfileHistory: @unchecked Sendable {
    static let shared = GenerationParameterProfileHistory()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "generation_parameter_profile_seen.v1"
    private let maximumEntryCount = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasSeenNonEmptyProfile(providerID: UUID, modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries().contains(Self.entryKey(providerID: providerID, modelID: modelID))
    }

    func recordSeenProfile(providerID: UUID, modelID: String, parameterCount: Int) {
        guard parameterCount > 0, !modelID.isEmpty else { return }
        let key = Self.entryKey(providerID: providerID, modelID: modelID)
        lock.lock()
        defer { lock.unlock() }
        var current = entries()
        guard !current.contains(key) else { return }
        current.append(key)
        if current.count > maximumEntryCount {
            current.removeFirst(current.count - maximumEntryCount)
        }
        defaults.set(current, forKey: storageKey)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private func entries() -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    private static func entryKey(providerID: UUID, modelID: String) -> String {
        "\(providerID.uuidString)|\(modelID)"
    }
}
