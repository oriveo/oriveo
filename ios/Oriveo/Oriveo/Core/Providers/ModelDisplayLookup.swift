import Foundation

nonisolated struct ModelDisplayLookup: Sendable {
    nonisolated fileprivate struct Entry: Sendable {
        let providerKind: ProviderKind
        let providerDisplayName: String
        let modelDisplayNamesByKey: [String: String]
        let contextLengthsByKey: [String: Int]
        let relayKind: RelayKind?
    }

    private let entriesByProviderID: [UUID: Entry]
    private let metadata: MetadataClient

    private init(entriesByProviderID: [UUID: Entry], metadata: MetadataClient) {
        self.entriesByProviderID = entriesByProviderID
        self.metadata = metadata
    }

    nonisolated init(providers: [Provider], metadata: MetadataClient = .shared) {
        self.metadata = metadata
        self.entriesByProviderID = ModelDisplayLookupBuilder.makeEntries(
            providers: providers,
            metadata: metadata
        )
    }

    nonisolated static let empty = ModelDisplayLookup(entriesByProviderID: [:], metadata: .shared)

    nonisolated static func fingerprint(
        providers: [Provider],
        metadata: MetadataClient = .shared
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(metadata.syncMetadataSnapshotVersion() ?? -1)
        hasher.combine(providers.count)
        for provider in providers {
            hasher.combine(provider.id)
            hasher.combine(provider.kind)
            hasher.combine(provider.customName)
            hasher.combine(provider.kind == .relay ? provider.relayKind : nil)
            hasher.combine(provider.models.count)
            for model in provider.models {
                hasher.combine(model.id)
                hasher.combine(model.name)
                hasher.combine(model.canonicalModelId)
                hasher.combine(model.contextLength)
            }
            for model in provider.catalogModels {
                hasher.combine(model.id)
                hasher.combine(model.name)
                hasher.combine(model.canonicalModelId)
                hasher.combine(model.contextLength)
            }
        }
        return hasher.finalize()
    }

    nonisolated func providerDisplayName(providerID: UUID) -> String? {
        entriesByProviderID[providerID]?.providerDisplayName
    }

    nonisolated func relayKind(providerID: UUID) -> RelayKind? {
        entriesByProviderID[providerID]?.relayKind
    }

    nonisolated func modelDisplayName(
        providerID: UUID,
        modelID: String,
        fallback: String? = nil
    ) -> String? {
        guard let entry = entriesByProviderID[providerID] else { return fallback }
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return fallback }

        for candidate in ModelResolver.normalizedLookupCandidates(
            for: trimmedModelID,
            providerKind: entry.providerKind
        ) {
            if let displayName = entry.modelDisplayNamesByKey[candidate.lowercased()] {
                return displayName
            }
        }

        if entry.providerKind != .relay,
           let resolved = metadata.syncResolveCatalogModel(
            modelID: trimmedModelID,
            providerKind: entry.providerKind
           ) {
            return resolved.displayName ?? fallback
        }

        return fallback
    }

    nonisolated func contextLength(providerID: UUID, modelID: String) -> Int? {
        guard let entry = entriesByProviderID[providerID] else { return nil }
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return nil }

        for candidate in ModelResolver.normalizedLookupCandidates(
            for: trimmedModelID,
            providerKind: entry.providerKind
        ) {
            if let contextLength = entry.contextLengthsByKey[candidate.lowercased()] {
                return contextLength
            }
        }

        if entry.providerKind != .relay,
           let resolved = metadata.syncResolveCatalogModel(
            modelID: trimmedModelID,
            providerKind: entry.providerKind
           ) {
            return resolved.contextLength
        }

        return nil
    }
    fileprivate nonisolated static func localLookupKeys(for model: AIModel, providerKind: ProviderKind) -> [String] {
        let rawValues = [
            model.id,
            ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind),
            model.canonicalModelId,
            model.canonicalModelId.map {
                ModelResolver.resolvedProviderModelIdentifier($0, providerKind: providerKind)
            }
        ].compactMap { $0 }

        var keys: [String] = []
        for rawValue in rawValues {
            for candidate in ModelResolver.normalizedLookupCandidates(
                for: rawValue,
                providerKind: providerKind
            ) {
                let normalized = candidate.lowercased()
                guard !normalized.isEmpty else { continue }
                guard !keys.contains(normalized) else { continue }
                keys.append(normalized)
            }
        }
        return keys
    }
}

private enum ModelDisplayLookupBuilder {
    nonisolated static func makeEntries(
        providers: [Provider],
        metadata: MetadataClient
    ) -> [UUID: ModelDisplayLookup.Entry] {
        Dictionary(uniqueKeysWithValues: providers.map { provider in
            (
                provider.id,
                ModelDisplayLookup.Entry(
                    providerKind: provider.kind,
                    providerDisplayName: resolvedProviderDisplayName(
                        provider: provider,
                        metadata: metadata
                    ),
                    modelDisplayNamesByKey: makeModelDisplayNames(
                        provider: provider,
                        metadata: metadata
                    ),
                    contextLengthsByKey: makeContextLengths(
                        provider: provider,
                        metadata: metadata
                    ),
                    relayKind: provider.kind == .relay ? provider.relayKind : nil
                )
            )
        })
    }

    private nonisolated static func resolvedProviderDisplayName(
        provider: Provider,
        metadata: MetadataClient
    ) -> String {
        if provider.kind == .relay {
            return provider.customName ?? ProviderKind.relay.displayName
        }
        return metadata.syncProviderDisplayName(providerKind: provider.kind) ?? provider.kind.displayName
    }

    private nonisolated static func sourceModels(for provider: Provider) -> [AIModel] {
        provider.kind == .relay
            ? (provider.catalogModels.isEmpty ? provider.models : provider.catalogModels + provider.models)
            : provider.models + provider.catalogModels
    }

    private nonisolated static func makeContextLengths(
        provider: Provider,
        metadata: MetadataClient
    ) -> [String: Int] {
        var contextLengthsByKey: [String: Int] = [:]
        for model in sourceModels(for: provider) {
            let resolved = metadata.syncResolveCatalogModel(
                modelID: model.id,
                providerKind: provider.kind
            )?.contextLength ?? model.contextLength
            guard let resolved, resolved > 0 else { continue }

            for key in ModelDisplayLookup.localLookupKeys(for: model, providerKind: provider.kind) {
                contextLengthsByKey[key] = resolved
            }
        }
        return contextLengthsByKey
    }

    private nonisolated static func makeModelDisplayNames(
        provider: Provider,
        metadata: MetadataClient
    ) -> [String: String] {
        let sourceModels = sourceModels(for: provider)

        var namesByKey: [String: String] = [:]
        for model in sourceModels {
            let resolvedDisplayName = metadata.syncResolveCatalogModel(
                modelID: model.id,
                providerKind: provider.kind
            )?.displayName ?? model.name

            for key in ModelDisplayLookup.localLookupKeys(for: model, providerKind: provider.kind) {
                namesByKey[key] = resolvedDisplayName
            }
        }
        return namesByKey
    }
}
