//  RelayOfficialCatalogResolver.swift

import Foundation

enum RelayOfficialCatalogResolver {
    static func enrich(
        localModel: AIModel,
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
        metadata: MetadataClient = .shared
    ) -> AIModel {
        if ModelResolver.isManualModel(localModel, providerKind: provider.kind) {
            return enrichManualOfficialPricing(
                localModel: localModel,
                provider: provider,
                metadata: metadata
            )
        }

        let envelope = RelayRuntimeSupport.envelopeKey(for: provider)
            .flatMap { runtimeConfig.transportEnvelopes[$0] }

        let priority = RelayRuntimeSupport.transportProviderKind(for: provider)
        guard let match = metadata.syncResolveCatalogModelAcrossProvidersWithProvider(
            modelID: localModel.id,
            transportPriority: priority
        ) else {
            return localModel
        }

        let officialCaps = match.metadata.capabilities.isEmpty ? [.text] : match.metadata.capabilities
        let intersected = intersectCapabilities(officialCaps, envelope: envelope)
        let autoCaps: [ModelCapability] = intersected.isEmpty ? [.text] : intersected

        let modelCaps = localModel.capabilities.isEmpty ? [] : localModel.capabilities
        var effectiveCaps = mergeUnique(base: autoCaps, add: modelCaps)

        if localModel.capabilities.contains(.imageGen), !effectiveCaps.contains(.imageGen) {
            effectiveCaps.append(.imageGen)
        }

        let reasoningProfile = effectiveCaps.contains(.reasoning) ? match.metadata.profiles.reasoning : nil
        let webSearchProfile = effectiveCaps.contains(.web) ? match.metadata.profiles.webSearch : nil
        let imageGenProfile = effectiveCaps.contains(.imageGen)
            ? match.metadata.profiles.imageGen
            : nil

        let pricing = CatalogModelBuilder.pricePresentation(from: match.metadata)

        return AIModel(
            id: localModel.id,
            name: match.metadata.displayName ?? localModel.name,
            capabilities: effectiveCaps,
            reasoningModeAvailable: effectiveCaps.contains(.reasoning) && reasoningProfile != nil,
            isAvailable: localModel.isAvailable,
            isDefault: localModel.isDefault,
            priceTier: pricing.priceTier.isEmpty ? localModel.priceTier : pricing.priceTier,
            summary: localModel.summary ?? CatalogModelBuilder.compactContextText(match.metadata.contextLength),
            contextLength: match.metadata.contextLength ?? localModel.contextLength,
            groupKey: match.metadata.uiHints.groupKey ?? localModel.groupKey,
            groupName: match.metadata.uiHints.groupName ?? localModel.groupName,
            promptPrice: pricing.promptPrice ?? localModel.promptPrice,
            completionPrice: pricing.completionPrice ?? localModel.completionPrice,
            canonicalModelId: match.canonicalModelId,
            isRecommended: match.metadata.uiHints.recommended || (localModel.isRecommended ?? false),
            sortRank: match.metadata.uiHints.rank ?? localModel.sortRank,
            badgeOrder: match.metadata.uiHints.badgeOrder?.filter { effectiveCaps.contains($0) && $0 != .text } ?? localModel.badgeOrder,
            reasoningProfile: reasoningProfile,
            webSearchProfile: webSearchProfile,
            imageGenProfile: imageGenProfile,
            generationProfile: match.metadata.generationProfile
        )
    }

    private static func enrichManualOfficialPricing(
        localModel: AIModel,
        provider: Provider,
        metadata: MetadataClient
    ) -> AIModel {
        let remoteModelID = ModelResolver.resolvedProviderModelIdentifier(
            localModel.id,
            providerKind: provider.kind
        )
        let priority = RelayRuntimeSupport.transportProviderKind(for: provider)
        guard let match = metadata.syncResolveCatalogModelAcrossProvidersWithProvider(
            modelID: remoteModelID,
            transportPriority: priority
        ) else {
            return localModel
        }

        let pricing = CatalogModelBuilder.pricePresentation(from: match.metadata)
        var enriched = localModel
        enriched.canonicalModelId = match.canonicalModelId
        enriched.priceTier = pricing.priceTier.isEmpty ? localModel.priceTier : pricing.priceTier
        enriched.promptPrice = pricing.promptPrice ?? localModel.promptPrice
        enriched.completionPrice = pricing.completionPrice ?? localModel.completionPrice
        enriched.billingSku = match.metadata.billingSku ?? localModel.billingSku
        enriched.pricingUnit = match.metadata.pricingUnit
        enriched.sourceSummary = match.metadata.sourceSummary.map {
            ModelSourceSummary(
                sourceKind: $0.sourceKind,
                sourceName: $0.sourceName,
                fetchedAt: $0.fetchedAt
            )
        } ?? localModel.sourceSummary
        enriched.costPerUnit = match.metadata.costPerUnit ?? localModel.costPerUnit
        enriched.costInputBatches = match.metadata.costInputBatches ?? localModel.costInputBatches
        enriched.costOutputBatches = match.metadata.costOutputBatches ?? localModel.costOutputBatches
        enriched.costInputPriority = match.metadata.costInputPriority ?? localModel.costInputPriority
        enriched.costOutputPriority = match.metadata.costOutputPriority ?? localModel.costOutputPriority
        enriched.cacheReadInputPerMToken = match.metadata.cacheReadInputPerMToken ?? localModel.cacheReadInputPerMToken
        enriched.cacheCreationInputPerMToken = match.metadata.cacheCreationInputPerMToken ?? localModel.cacheCreationInputPerMToken
        return enriched
    }

    static func enrichCatalog(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
        metadata: MetadataClient = .shared
    ) -> [AIModel] {
        return provider.catalogModels.map { local in
            enrich(localModel: local, provider: provider, runtimeConfig: runtimeConfig, metadata: metadata)
        }
    }

    // MARK: - Capability Intersection

    private static func intersectCapabilities(
        _ capabilities: [ModelCapability],
        envelope: MetadataClient.RelayTransportEnvelope?
    ) -> [ModelCapability] {
        guard let envelope else { return capabilities }
        return capabilities.filter { envelopeAllows(envelope: envelope, capability: $0) }
    }

    private static func envelopeAllows(
        envelope: MetadataClient.RelayTransportEnvelope,
        capability: ModelCapability
    ) -> Bool {
        switch capability {
        case .image: return envelope.image
        case .video: return false
        case .file: return envelope.nativeFile || envelope.textFileInline
        case .web: return envelope.webSearch
        case .imageGen: return envelope.imageGeneration
        case .reasoning: return envelope.reasoning
        case .text: return true
        case .nativePdf: return false
        case .toolCall: return false
        }
    }

    private static func mergeUnique(
        base: [ModelCapability],
        add: [ModelCapability]
    ) -> [ModelCapability] {
        var seen = Set<ModelCapability>()
        var out: [ModelCapability] = []
        for cap in base where seen.insert(cap).inserted { out.append(cap) }
        for cap in add where seen.insert(cap).inserted { out.append(cap) }
        return out
    }
}
