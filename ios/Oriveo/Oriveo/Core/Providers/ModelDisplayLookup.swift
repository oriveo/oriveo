import Foundation

nonisolated struct ModelDisplayLookup: Sendable {
    nonisolated fileprivate struct Entry: Sendable {
        let providerKind: ProviderKind
        let providerDisplayName: String
        let modelDisplayNamesByKey: [String: String]
        let contextLengthsByKey: [String: Int]
        let relayKind: RelayKind?
        /// The avatar of a relay connection; nil for official and local connections.
        let relayAvatar: RelayAvatar?
        /// The enabled models this entry was built from. When a conversation row falls back to searching the
        /// enabled models, the index below is used only if the caller's Provider holds this same array (shared
        /// storage makes the comparison O(1)); otherwise it compares one by one as before.
        let enabledModels: [AIModel]
        let enabledModelIndex: SharedMatchingModelIndex
    }

    /// A shared `ModelResolver.MatchingModelIndex`: the lookup is a value type passed between views, so the index is
    /// built once on demand and then shared by every holder. It is locked because a background prewarm and a
    /// main-thread query can overlap.
    nonisolated final class SharedMatchingModelIndex: @unchecked Sendable {
        private let models: [AIModel]
        private let providerKind: ProviderKind
        private let lock = NSLock()
        private var index: ModelResolver.MatchingModelIndex?

        init(_ models: [AIModel], providerKind: ProviderKind) {
            self.models = models
            self.providerKind = providerKind
        }

        func resolveStored(_ modelID: String) -> AIModel? {
            lock.lock()
            defer { lock.unlock() }
            var built = index ?? ModelResolver.MatchingModelIndex(models, providerKind: providerKind)
            let result = built.resolveStored(modelID)
            index = built
            return result
        }

        /// Builds both the exact and the fuzzy layer now (for a relay the fuzzy layer is the canonical read compatibility).
        func prewarm() {
            lock.lock()
            defer { lock.unlock() }
            var built = index ?? ModelResolver.MatchingModelIndex(models, providerKind: providerKind)
            built.prepareStoredIdentifierIndex()
            index = built
        }
    }

    private let entriesByProviderID: [UUID: Entry]
    private let metadata: MetadataClient

    private init(entriesByProviderID: [UUID: Entry], metadata: MetadataClient) {
        self.entriesByProviderID = entriesByProviderID
        self.metadata = metadata
    }

    /// `relayAvatarChoices`: a snapshot of the on-device relay avatar choices (`RelayAvatarChoiceStore.choices`); message headers draw from it.
    nonisolated init(
        providers: [Provider],
        metadata: MetadataClient = .shared,
        relayAvatarChoices: [String: String] = [:]
    ) {
        self.metadata = metadata
        self.entriesByProviderID = ModelDisplayLookupBuilder.makeEntries(
            providers: providers,
            metadata: metadata,
            relayAvatarChoices: relayAvatarChoices
        )
    }

    nonisolated static let empty = ModelDisplayLookup(entriesByProviderID: [:], metadata: .shared)

    nonisolated static func fingerprint(
        providers: [Provider],
        metadata: MetadataClient = .shared,
        relayAvatarChoices: [String: String] = [:]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(metadata.syncMetadataSnapshotVersion() ?? -1)
        // A changed avatar choice also forces a rebuild, so message headers keep up.
        for key in relayAvatarChoices.keys.sorted() {
            hasher.combine(key)
            hasher.combine(relayAvatarChoices[key])
        }
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

    /// Exactly equivalent to `ModelResolver.resolveStoredModel(_:in: provider.models, providerKind:)`. When this
    /// lookup was built from `provider`'s current enabled models it queries the index (after "Add all" the enabled
    /// models are the whole relay catalog, and comparing one by one per row grows with the catalog); otherwise it
    /// compares one by one as before.
    nonisolated func matchingEnabledModel(modelID: String, in provider: Provider) -> AIModel? {
        guard let entry = entriesByProviderID[provider.id],
              entry.providerKind == provider.kind,
              entry.enabledModels == provider.models else {
            return ModelResolver.resolveStoredModel(modelID, in: provider.models, providerKind: provider.kind)
        }
        return entry.enabledModelIndex.resolveStored(modelID)
    }

    /// Builds every Provider's enabled-model index now. Call it off the main thread.
    nonisolated func prewarm() {
        for entry in entriesByProviderID.values {
            entry.enabledModelIndex.prewarm()
        }
    }

    nonisolated func providerDisplayName(providerID: UUID) -> String? {
        entriesByProviderID[providerID]?.providerDisplayName
    }

    nonisolated func relayKind(providerID: UUID) -> RelayKind? {
        entriesByProviderID[providerID]?.relayKind
    }

    /// The relay avatar for a message header: taken from the conversation's connection; generic when the connection is gone or was never recorded; nil for a non-relay message (which uses the original logo).
    nonisolated func relayAvatar(providerID: UUID?, providerKind: ProviderKind) -> RelayAvatar? {
        guard providerKind == .relay else { return nil }
        guard let providerID, let entry = entriesByProviderID[providerID] else { return .generic }
        return entry.relayAvatar
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

        // A relay literal miss: read-compatible with old canonical stored values on the same terms as
        // `ModelResolver.resolveStoredModel`; the name is taken only when exactly one enabled model's canonical
        // equals the stored value, and with several it falls back to the fallback name.
        if entry.providerKind == .relay {
            guard let resolved = entry.enabledModelIndex.resolveStored(trimmedModelID) else { return fallback }
            return entry.modelDisplayNamesByKey[ModelResolver.relayIdentityKey(resolved.id)] ?? resolved.name
        }

        if let resolved = metadata.syncResolveCatalogModel(
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
        // A relay is matched by the literal key only: a canonical / date-stripped key would give a stored gpt-4o the name of the dated snapshot's row.
        if providerKind == .relay {
            let key = ModelResolver.relayIdentityKey(model.id)
            return key.isEmpty ? [] : [key]
        }
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
        metadata: MetadataClient,
        relayAvatarChoices: [String: String]
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
                    relayKind: provider.kind == .relay ? provider.relayKind : nil,
                    relayAvatar: RelayAvatarResolver.avatar(
                        for: provider,
                        choice: relayAvatarChoices[provider.id.uuidString]
                    ),
                    enabledModels: provider.models,
                    enabledModelIndex: ModelDisplayLookup.SharedMatchingModelIndex(
                        provider.models,
                        providerKind: provider.kind
                    )
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
