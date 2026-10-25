import Foundation

nonisolated enum ProviderSelectionSnapshot {
    static func enabledModels(in provider: Provider) -> [AIModel] {
        provider.models
    }

    /// The connection's default model: connection isDefault > catalog defaultModelId > the first available. Used only for the "default" mark and as the
    /// fallback when a non-empty stored value cannot be resolved; a new chat (including starting a chat from a connection, and a session with an empty modelID)
    /// always goes through `newChatModel` / `activeModel` and never reads isDefault.
    static func defaultModel(
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        defaultModel(in: provider, metadata: metadata, honorConnectionDefault: true, isAvailable: nil)
    }

    /// Starts a new chat limited to one connection (the detail page / card "start chat"; the toolbar new chat in the chat screen is not limited to a connection):
    /// the last used model that points to this connection, is enabled and not retired > catalog defaultModelId > the first available; the connection isDefault is not read.
    /// A relay behaves like `relayFallbackModel`.
    static func newChatModel(
        in provider: Provider,
        lastUsedModelRef: LastUsedModelRef?,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        guard provider.kind != .relay else {
            return relayFallbackModel(in: provider, lastUsedModelRef: lastUsedModelRef)
        }
        // The last used model and the default tier share one catalog source read (one lock), and each candidate is only sliced.
        let isAvailable = enabledModelAvailability(in: provider, metadata: metadata)
        if let ref = lastUsedModelRef,
           ref.providerID == provider.id,
           let lastUsed = ModelResolver.resolveStoredModel(
            ref.modelID,
            in: enabledModels(in: provider),
            providerKind: provider.kind
           ), isAvailable(lastUsed) {
            return lastUsed
        }
        return defaultModel(in: provider, metadata: metadata, honorConnectionDefault: false, isAvailable: isAvailable)
    }

    /// The enabled and available model a stored value resolves back to (shared by the last-used tier and the skill-recommended tier):
    /// not enabled, retired, or absent from the catalog all return nil.
    static func availableEnabledModel(
        storedModelID: String,
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        guard let model = ModelResolver.resolveStoredModel(
            storedModelID,
            in: enabledModels(in: provider),
            providerKind: provider.kind
        ), enabledModelAvailability(in: provider, metadata: metadata)(model) else { return nil }
        return model
    }

    private static func defaultModel(
        in provider: Provider,
        metadata: MetadataClient,
        honorConnectionDefault: Bool,
        isAvailable sharedAvailability: ((AIModel) -> Bool)?
    ) -> AIModel? {
        let enabled = enabledModels(in: provider)
        guard !enabled.isEmpty else { return nil }

        // A relay has no default model, so the old isDefault is not read; for the fallback that carries the last used model see `relayFallbackModel`.
        guard provider.kind != .relay else { return enabled.first }

        // Pick only among available models: retired models and models absent from the catalog (missing, except under the bundled snapshot) are never the default;
        // when every enabled model is unavailable there is no available default and this returns nil.
        // Candidates are judged lazily and the first hit stops: the unavailable set of all enabled models is not computed up front, because with 810
        // enabled models judging the whole list takes about 54 ms while this is called synchronously from a view body / the main actor. The result equals filtering first and then picking.
        let isAvailable = sharedAvailability ?? enabledModelAvailability(in: provider, metadata: metadata)

        if honorConnectionDefault, let explicitDefault = enabled.first(where: { $0.isDefault && isAvailable($0) }) {
            return explicitDefault
        }

        if provider.kind != .relay,
           let metadataDefaultID = metadata.syncProviderDefaultModelID(providerKind: provider.kind),
           let metadataDefault = firstAvailableMatch(
            modelID: metadataDefaultID,
            in: enabled,
            providerKind: provider.kind,
            isAvailable: defaultTierAvailability(
                metadataDefaultID: metadataDefaultID, in: provider, metadata: metadata, isAvailable: isAvailable
            )
           ) {
            return metadataDefault
        }

        return enabled.first(where: isAvailable)
    }

    /// Availability judgment of the default tier: an enabled model that hits the catalog default through an alias counts as in the catalog when the catalog default itself is available;
    /// its own id still stays skipped when it is in the tombstones or deprecated past its shutdown date. Used only for the default tier; the last-used tier and the first-available tier still use `isAvailable`.
    private static func defaultTierAvailability(
        metadataDefaultID: String,
        in provider: Provider,
        metadata: MetadataClient,
        isAvailable: @escaping (AIModel) -> Bool,
        now: Date = Date()
    ) -> (AIModel) -> Bool {
        guard judgesCatalogAvailability(provider) else { return isAvailable }
        let source = retirementSource(for: provider, metadata: metadata)
        let defaultRead = source.read(modelIDs: [metadataDefaultID])
        guard defaultRead.catalog != nil,
              isCatalogAvailable(metadataDefaultID, canonicalID: nil, read: defaultRead, now: now) else {
            return isAvailable
        }
        return { model in
            if isAvailable(model) { return true }
            let read = source.read(modelIDs: [model.id])
            guard read.catalog != nil else { return true }
            return ConversationModelRetirement.conversationStatus(
                catalog: read.catalog, userModels: [], modelId: model.id, storedName: nil, now: now
            ).status != .retired
        }
    }

    /// Equivalent to `ModelResolver.matchingModel(modelID:in: available subset)`: the match priority depends only on the model itself and its position,
    /// so after dropping an unavailable model that sorts first and matching again, the result is the highest-priority match within the available subset; only the matched candidates are judged.
    private static func firstAvailableMatch(
        modelID: String,
        in models: [AIModel],
        providerKind: ProviderKind,
        isAvailable: (AIModel) -> Bool
    ) -> AIModel? {
        var remaining = models
        while let match = ModelResolver.matchingModel(modelID: modelID, in: remaining, providerKind: providerKind) {
            if isAvailable(match) { return match }
            guard let index = remaining.firstIndex(where: { $0.id == match.id }) else { return nil }
            remaining.remove(at: index)
        }
        return nil
    }

    /// Whether a single enabled model is usable for a new chat (same rule as `unavailableEnabledModelIDs`): the catalog source is taken only once at the start (one lock),
    /// and each candidate slices only the entries of that model id and its canonical. Connections that are not judged are always usable.
    /// Results are remembered by id within one call and never cached beyond it (so they do not go stale after a catalog revision).
    private static func enabledModelAvailability(
        in provider: Provider,
        metadata: MetadataClient,
        now: Date = Date()
    ) -> (AIModel) -> Bool {
        guard judgesCatalogAvailability(provider) else { return { _ in true } }
        let source = retirementSource(for: provider, metadata: metadata)
        var memo: [String: Bool] = [:]
        return { model in
            if let known = memo[model.id] { return known }
            let read = source.read(modelIDs: [model.id] + (model.canonicalModelId.map { [$0] } ?? []))
            let available = read.catalog == nil || isCatalogAvailable(
                model.id, canonicalID: model.canonicalModelId, read: read, now: now
            )
            memo[model.id] = available
            return available
        }
    }

    static func selectedModel(
        storedModelID: String?,
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        guard let storedModelID,
              !storedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Stored-value resolution: for relays the literal wins, with a unique canonical hit as the fallback (read compatibility); official providers are the same as matchingModel
        return ModelResolver.resolveStoredModel(
            storedModelID,
            in: enabledModels(in: provider),
            providerKind: provider.kind
        ) ?? metadataBackedHistoricalModel(
            storedModelID: storedModelID,
            in: provider,
            metadata: metadata
        )
    }

    static func persistedModelID(
        requestedModelID: String?,
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> String? {
        let trimmedModelID = requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedModelID.isEmpty else { return nil }

        if let selectedModel = selectedModel(
            storedModelID: trimmedModelID,
            in: provider,
            metadata: metadata
        ) {
            return ModelResolver.preferredStoredModelIdentifier(
                for: selectedModel,
                providerKind: provider.kind
            )
        }

        return ModelResolver.resolvedProviderModelIdentifier(
            trimmedModelID,
            providerKind: provider.kind
        )
    }

    static func currentModel(
        storedModelID: String?,
        in provider: Provider,
        lastUsedModelRef: LastUsedModelRef? = nil,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        guard let storedModelID,
              !storedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An empty id takes the new-chat chain and does not read the connection isDefault.
            return newChatModel(in: provider, lastUsedModelRef: lastUsedModelRef, metadata: metadata)
        }

        return selectedModel(
            storedModelID: storedModelID,
            in: provider,
            metadata: metadata
        ) ?? defaultModel(in: provider, metadata: metadata)
    }

    // MARK: - Relay fallback model and session model state

    /// Relay fallback model: if the last used model points to this connection and is still enabled -> it; otherwise the first enabled model.
    static func relayFallbackModel(
        in provider: Provider,
        lastUsedModelRef: LastUsedModelRef?
    ) -> AIModel? {
        let enabled = enabledModels(in: provider)
        if let ref = lastUsedModelRef,
           ref.providerID == provider.id,
           let lastUsed = ModelResolver.resolveStoredModel(
            ref.modelID,
            in: enabled,
            providerKind: provider.kind
           ) {
            return lastUsed
        }
        return enabled.first
    }

    /// Verification sample: fallback model -> first catalog model -> nil (nil sends no request and goes through the existing missing-model error).
    static func relayVerificationSampleModelID(
        in provider: Provider,
        lastUsedModelRef: LastUsedModelRef?
    ) -> String? {
        if let fallback = relayFallbackModel(in: provider, lastUsedModelRef: lastUsedModelRef) {
            return fallback.id
        }
        return provider.catalogModels.first?.id
    }

    enum ConversationModelState: Equatable, Sendable {
        case resolved
        /// The model stored in the relay session is no longer among the connection's enabled models; it is not silently replaced and the user must pick again.
        case removed(connectionName: String)
        /// The official session model is retired (tombstoned or past shutdownAt); successorId is the successor that is still available now.
        case retired(displayName: String, successorId: String?)
        /// The official session model cannot be found in the confirmed catalog.
        case missing(displayName: String)

        /// removed / retired / missing all send no request and wait for the user to pick again.
        var blocksSend: Bool { self != .resolved }
    }

    /// Relay: a non-empty model id stored in the session that is not among the enabled models -> removed; an empty id goes to the fallback and does not count as removed.
    /// Official BYOK goes through `ConversationModelRetirement.conversationStatus`; subscription logins are not judged.
    /// A pending catalog / no catalog counts as available; under the bundled snapshot missing counts as available while retired stays retired.
    static func conversationModelState(
        storedModelID: String?,
        in provider: Provider,
        metadata: MetadataClient = .shared,
        now: Date = Date()
    ) -> ConversationModelState {
        let trimmed = storedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .resolved }
        if provider.kind == .relay {
            let isEnabled = ModelResolver.resolveStoredModel(
                trimmed,
                in: enabledModels(in: provider),
                providerKind: provider.kind
            ) != nil
            return isEnabled ? .resolved : .removed(connectionName: provider.displayName)
        }
        guard provider.authMode != .subscription else { return .resolved }

        let read = retirementRead(for: provider, modelIDs: [trimmed], metadata: metadata)
        let catalog = read.catalog
        let enabled = enabledModels(in: provider)
        var userModels = enabled.map(\.id)
        // A stored value that resolves to an enabled model under the existing rules (canonical / prefix) also counts as enabled by the user.
        if ModelResolver.resolveStoredModel(trimmed, in: enabled, providerKind: provider.kind) != nil {
            userModels.append(trimmed)
        }
        let result = ConversationModelRetirement.conversationStatus(
            catalog: catalog,
            userModels: userModels,
            modelId: trimmed,
            storedName: nil,
            now: now
        )
        switch result.status {
        case .available:
            return .resolved
        case .retired:
            return .retired(displayName: result.displayName, successorId: result.successorId)
        case .missing:
            if read.servingBundledSnapshot { return .resolved }
            return .missing(displayName: result.displayName)
        }
    }

    /// Enabled model ids that are unavailable for a new chat: available = in the catalog and not retired; absent from the catalog (missing) is also unavailable,
    /// and under the bundled snapshot missing counts as available (same as `conversationModelState`). A pending catalog / no catalog is all available;
    /// relays and subscription logins are not judged and return empty. When a model id is not in the catalog, its own canonical is checked next.
    static func unavailableEnabledModelIDs(
        in provider: Provider,
        metadata: MetadataClient = .shared,
        now: Date = Date()
    ) -> Set<String> {
        guard judgesCatalogAvailability(provider) else { return [] }
        let enabled = enabledModels(in: provider)
        guard !enabled.isEmpty else { return [] }
        let read = retirementRead(
            for: provider,
            modelIDs: enabled.map(\.id) + enabled.compactMap(\.canonicalModelId),
            metadata: metadata
        )
        guard read.catalog != nil else { return [] }
        var unavailable: Set<String> = []
        for model in enabled where !isCatalogAvailable(
            model.id, canonicalID: model.canonicalModelId, read: read, now: now
        ) {
            unavailable.insert(model.id)
        }
        return unavailable
    }

    /// The last used model is retired or cannot be found in the catalog ("hint once when the last used model was not adopted").
    /// Relays and subscription logins are not judged; one that is merely not enabled but available in the catalog does not count.
    static func lastUsedModelUnavailable(
        in providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?,
        metadata: MetadataClient = .shared,
        now: Date = Date()
    ) -> Bool {
        guard let ref = lastUsedModelRef,
              let provider = providers.first(where: { $0.id == ref.providerID }),
              judgesCatalogAvailability(provider) else { return false }
        let trimmed = ref.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let enabled = ModelResolver.resolveStoredModel(trimmed, in: enabledModels(in: provider), providerKind: provider.kind) {
            return !enabledModelAvailability(in: provider, metadata: metadata, now: now)(enabled)
        }
        let read = retirementRead(for: provider, modelIDs: [trimmed], metadata: metadata)
        guard read.catalog != nil else { return false }
        return !isCatalogAvailable(trimmed, canonicalID: nil, read: read, now: now)
    }

    private static func judgesCatalogAvailability(_ provider: Provider) -> Bool {
        provider.kind != .relay && provider.authMode != .subscription
    }

    private static func isCatalogAvailable(
        _ modelID: String,
        canonicalID: String?,
        read: MetadataClient.ConversationRetirementRead,
        now: Date
    ) -> Bool {
        // userModels is passed empty: enabled does not mean in the catalog (missing is unavailable).
        func status(_ id: String) -> ConversationModelRetirement.Status {
            ConversationModelRetirement.conversationStatus(
                catalog: read.catalog, userModels: [], modelId: id, storedName: nil, now: now
            ).status
        }
        switch status(modelID) {
        case .available:
            return true
        case .retired:
            return false
        case .missing:
            if read.servingBundledSnapshot { return true }
            if let canonicalID, !canonicalID.isEmpty, canonicalID != modelID { return status(canonicalID) == .available }
            return false
        }
    }

    /// Retired model ids that the model picker / model controls candidates hide: only retired counts (tombstoned or past the shutdown date);
    /// missing, a pending catalog and the bundled-snapshot state are never hidden. Relays and subscription logins are not judged and return empty.
    /// The catalog is read once per provider, with modelIDs being all of its enabled models.
    static func retiredEnabledModelIDs(
        in provider: Provider,
        metadata: MetadataClient = .shared,
        now: Date = Date()
    ) -> Set<String> {
        guard judgesCatalogAvailability(provider) else { return [] }
        let userModels = enabledModels(in: provider).map(\.id)
        guard !userModels.isEmpty,
              let catalog = retirementRead(for: provider, modelIDs: userModels, metadata: metadata).catalog
        else { return [] }
        var retired: Set<String> = []
        for id in userModels where ConversationModelRetirement.conversationStatus(
            catalog: catalog,
            userModels: userModels,
            modelId: id,
            storedName: nil,
            now: now
        ).status == .retired {
            retired.insert(id)
        }
        return retired
    }

    /// The catalog used by the retirement check: the entries this check needs from the metadata catalog (nil when pending / no catalog).
    static func retirementRead(
        for provider: Provider,
        modelIDs: [String],
        metadata: MetadataClient
    ) -> MetadataClient.ConversationRetirementRead {
        retirementSource(for: provider, metadata: metadata).read(modelIDs: modelIDs)
    }

    /// The two-step version of `retirementRead`: take the source once, then slice it per candidate.
    static func retirementSource(
        for provider: Provider,
        metadata: MetadataClient
    ) -> MetadataClient.ConversationRetirementSource {
        metadata.syncConversationRetirementSource(providerKind: provider.kind)
    }

    /// Hint for a new-chat fallback: when the connection of the last used model is usable (credentials present) and belongs to official BYOK,
    /// and the model is retired or cannot be found in the catalog (whether or not it is still enabled), this gives the connection and model the new chat actually falls back to:
    /// first the catalog defaultModelId > the first available on its own connection, and if none, onward in connection order
    /// (same as `activeModel`, and it hints across connections too); the connection isDefault is not read. nil means no hint is needed or no model is available anywhere.
    static func newChatRetiredFallback(
        in providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?,
        metadata: MetadataClient = .shared,
        now: Date = Date()
    ) -> (provider: Provider, model: AIModel, retiredModelID: String)? {
        // Connections missing credentials are dropped before every tier (including the one holding the last used model); the hint is judged afterwards.
        let usable = providers.filter(isUsableForNewChat)
        guard let ref = lastUsedModelRef,
              let provider = usable.first(where: { $0.id == ref.providerID }),
              provider.kind != .relay,
              lastUsedModelUnavailable(in: usable, lastUsedModelRef: ref, metadata: metadata, now: now),
              let chosen = activeModel(
                in: providers, lastUsedModelRef: ref, metadata: metadata
              ) else { return nil }
        return (chosen.provider, chosen.model, ref.modelID)
    }

    /// New-chat resolution not limited to a connection; every new-chat entry that is not limited to a connection calls it:
    /// unusable connections (missing credentials: no key / no subscription login) are skipped, while connections in an error state are not; the connection of the last used model
    /// (otherwise the primary connection) tries its new-chat chain first (last used if available and enabled > catalog default > the first available),
    /// the rest follow the user's connection order (catalog default > the first available); nil if none.
    static func activeModel(
        in providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?,
        metadata: MetadataClient = .shared
    ) -> (provider: Provider, model: AIModel)? {
        let usable = providers.filter(isUsableForNewChat)
        // With no last used model (or its connection lacks credentials) try the first usable connection in the list first; a connection with an error keeps its position.
        let first = lastUsedModelRef.flatMap { ref in usable.first(where: { $0.id == ref.providerID }) }
            ?? usable.first
        if let first,
           let model = newChatModel(in: first, lastUsedModelRef: lastUsedModelRef, metadata: metadata) {
            return (first, model)
        }
        for provider in usable where provider.id != first?.id {
            if let model = newChatModel(in: provider, lastUsedModelRef: nil, metadata: metadata) {
                return (provider, model)
            }
        }
        return nil
    }

    /// Whether a new chat can use this connection: only whether credentials are missing - an official BYOK / subscription connection with no key or login credential on this device
    /// (after a subscription login the access token is stored in apiKey), or a relay that needs credentials but has no key, is unusable; a connection in an error state (issue)
    /// stays usable and is not skipped. Every entry such as new-chat resolution and skill model selection uses this one rule.
    static func isUsableForNewChat(_ provider: Provider) -> Bool {
        if provider.kind == .relay {
            return !RelayCredentialPolicy.requiresCredential(provider.relayRequested)
                || RelayCredentialPolicy.hasStoredKey(provider.apiKey)
        }
        return !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func metadataBackedHistoricalModel(
        storedModelID: String,
        in provider: Provider,
        metadata: MetadataClient
    ) -> AIModel? {
        guard provider.kind != .relay,
              let resolved = metadata.syncResolveCatalogModel(
                modelID: storedModelID,
                providerKind: provider.kind
              ) else {
            return nil
        }

        let capabilities = resolved.capabilities.isEmpty ? [ModelCapability.text] : resolved.capabilities
        let pricing = CatalogModelBuilder.pricePresentation(from: resolved)

        return AIModel(
            id: resolved.canonicalModelId,
            name: resolved.displayName ?? resolved.canonicalModelId,
            capabilities: capabilities,
            reasoningModeAvailable: resolved.profiles.reasoning != nil,
            isAvailable: true,
            isDefault: resolved.isDefault,
            priceTier: pricing.priceTier,
            summary: CatalogModelBuilder.compactContextText(resolved.contextLength),
            contextLength: resolved.contextLength,
            groupKey: resolved.uiHints.groupKey,
            groupName: resolved.uiHints.groupName,
            promptPrice: pricing.promptPrice,
            completionPrice: pricing.completionPrice,
            canonicalModelId: resolved.canonicalModelId,
            isRecommended: resolved.uiHints.recommended,
            sortRank: resolved.uiHints.rank,
            badgeOrder: resolved.uiHints.badgeOrder,
            reasoningProfile: resolved.profiles.reasoning,
            webSearchProfile: resolved.profiles.webSearch,
            imageGenProfile: resolved.profiles.imageGen
        )
    }
}
