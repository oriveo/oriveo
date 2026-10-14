import Foundation

nonisolated enum ProviderSelectionSnapshot {
    static func enabledModels(in provider: Provider) -> [AIModel] {
        provider.models
    }

    static func defaultModel(
        in provider: Provider,
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        let enabled = enabledModels(in: provider)
        guard !enabled.isEmpty else { return nil }

        // A relay has no default model, so the old isDefault is not read; for the fallback that carries the last used model see `relayFallbackModel`.
        guard provider.kind != .relay else { return enabled.first }

        if let explicitDefault = enabled.first(where: \.isDefault) {
            return explicitDefault
        }

        if provider.kind != .relay,
           let metadataDefaultID = metadata.syncProviderDefaultModelID(providerKind: provider.kind),
           let metadataDefault = ModelResolver.matchingModel(
            modelID: metadataDefaultID,
            in: enabled,
            providerKind: provider.kind
           ) {
            return metadataDefault
        }

        return enabled.first
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
        metadata: MetadataClient = .shared
    ) -> AIModel? {
        guard let storedModelID,
              !storedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModel(in: provider, metadata: metadata)
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
    }

    /// Relay only: a non-empty model id stored in the session that is not among the enabled models -> removed; an empty id goes to the fallback and does not count as removed.
    static func conversationModelState(
        storedModelID: String?,
        in provider: Provider
    ) -> ConversationModelState {
        guard provider.kind == .relay else { return .resolved }
        let trimmed = storedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .resolved }
        let isEnabled = ModelResolver.resolveStoredModel(
            trimmed,
            in: enabledModels(in: provider),
            providerKind: provider.kind
        ) != nil
        return isEnabled ? .resolved : .removed(connectionName: provider.displayName)
    }

    static func activeModel(
        in providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?
    ) -> (provider: Provider, model: AIModel)? {
        if let ref = lastUsedModelRef,
           let provider = providers.first(where: { $0.id == ref.providerID }),
           let model = currentModel(storedModelID: ref.modelID, in: provider) {
            return (provider, model)
        }

        if let provider = providers.first(where: { if case .connected = $0.status { return true }; return false })
            ?? providers.first,
           let model = defaultModel(in: provider) {
            return (provider, model)
        }

        return nil
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
