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

        return ModelResolver.matchingModel(
            modelID: storedModelID,
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
