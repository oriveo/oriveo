//  CatalogModelBuilder.swift

import Foundation

enum CatalogModelBuilder {

    static func buildCatalogModel(
        providerKind: ProviderKind,
        runtimeModelId: String,
        fallbackName: String,
        fallbackContextLength: Int? = nil,
        fallbackSummary: String? = nil,
        createdAt: Double? = nil,
        metadataClient: MetadataClient = .shared
    ) async -> AIModel {
        let metadata = await metadataClient.resolveCatalogModel(
            modelID: runtimeModelId,
            providerKind: providerKind
        )

        let capabilities = metadata?.capabilities.isEmpty == false
            ? metadata!.capabilities
            : [.text]
        let pricing = pricePresentation(from: metadata)

        let summary = fallbackSummary
            ?? compactContextText(metadata?.contextLength ?? fallbackContextLength)

        return AIModel(
            id: runtimeModelId,
            name: metadata?.displayName ?? fallbackName,
            capabilities: capabilities,
            reasoningModeAvailable: metadata?.profiles.reasoning != nil,
            isAvailable: true,
            isDefault: metadata?.isDefault ?? false,
            priceTier: pricing.priceTier,
            summary: summary,
            contextLength: metadata?.contextLength ?? fallbackContextLength,
            maxOutputTokens: metadata?.maxOutputTokens,
            groupKey: metadata?.uiHints.groupKey,
            groupName: metadata?.uiHints.groupName,
            createdAt: createdAt,
            promptPrice: pricing.promptPrice,
            completionPrice: pricing.completionPrice,
            billingSku: metadata?.billingSku,
            pricingUnit: metadata?.pricingUnit ?? "per_token",
            sourceSummary: metadata?.sourceSummary.map {
                ModelSourceSummary(
                    sourceKind: $0.sourceKind,
                    sourceName: $0.sourceName,
                    fetchedAt: $0.fetchedAt
                )
            },
            costPerUnit: metadata?.costPerUnit,
            costInputBatches: metadata?.costInputBatches,
            costOutputBatches: metadata?.costOutputBatches,
            costInputPriority: metadata?.costInputPriority,
            costOutputPriority: metadata?.costOutputPriority,
            cacheReadInputPerMToken: metadata?.cacheReadInputPerMToken,
            cacheCreationInputPerMToken: metadata?.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken: metadata?.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken: metadata?.cacheWrite1hPerMToken,
            supportsPdfInput: metadata?.supportsPdfInput ?? false,
            supportsServiceTier: metadata?.supportsServiceTier ?? false,
            canonicalModelId: metadata?.canonicalModelId,
            isRecommended: metadata?.uiHints.recommended ?? false,
            sortRank: metadata?.uiHints.rank,
            badgeOrder: metadata?.uiHints.badgeOrder,
            reasoningProfile: metadata?.profiles.reasoning,
            webSearchProfile: metadata?.profiles.webSearch,
            imageGenProfile: metadata?.profiles.imageGen,
            generationProfile: metadata?.generationProfile,
            toolCall: metadata?.toolCall,
            libraryAgentic: metadata?.libraryAgentic
        )
    }


    nonisolated static func enrichStoredModel(
        _ model: AIModel,
        providerKind: ProviderKind,
        metadataClient: MetadataClient = .shared
    ) -> AIModel {
        let strippedID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
        let metadata = metadataClient.syncResolveCatalogModel(
            modelID: strippedID,
            providerKind: providerKind
        )
        guard let metadata else {
            return model
        }

        let capabilities = metadata.capabilities.isEmpty ? model.capabilities : metadata.capabilities
        let pricing = pricePresentation(from: metadata)

        var enriched = model
        enriched.canonicalModelId = metadata.canonicalModelId
        enriched.name = metadata.displayName ?? model.name
        enriched.capabilities = capabilities
        enriched.reasoningModeAvailable = metadata.profiles.reasoning != nil
        enriched.isRecommended = metadata.uiHints.recommended
        enriched.priceTier = pricing.priceTier
        enriched.summary = model.summary ?? compactContextText(metadata.contextLength ?? model.contextLength)
        enriched.groupKey = metadata.uiHints.groupKey
        enriched.groupName = metadata.uiHints.groupName
        enriched.sortRank = metadata.uiHints.rank
        enriched.badgeOrder = metadata.uiHints.badgeOrder
        enriched.promptPrice = pricing.promptPrice
        enriched.completionPrice = pricing.completionPrice
        enriched.billingSku = metadata.billingSku
        enriched.pricingUnit = metadata.pricingUnit
        enriched.sourceSummary = metadata.sourceSummary.map {
            ModelSourceSummary(
                sourceKind: $0.sourceKind,
                sourceName: $0.sourceName,
                fetchedAt: $0.fetchedAt
            )
        }
        enriched.costPerUnit = metadata.costPerUnit
        enriched.costInputBatches = metadata.costInputBatches
        enriched.costOutputBatches = metadata.costOutputBatches
        enriched.costInputPriority = metadata.costInputPriority
        enriched.costOutputPriority = metadata.costOutputPriority
        enriched.cacheReadInputPerMToken = metadata.cacheReadInputPerMToken
        enriched.cacheCreationInputPerMToken = metadata.cacheCreationInputPerMToken
        enriched.cacheWrite5mPerMToken = metadata.cacheWrite5mPerMToken
        enriched.cacheWrite1hPerMToken = metadata.cacheWrite1hPerMToken
        enriched.supportsPdfInput = metadata.supportsPdfInput
        enriched.supportsServiceTier = metadata.supportsServiceTier
        enriched.contextLength = metadata.contextLength ?? model.contextLength
        enriched.maxOutputTokens = metadata.maxOutputTokens ?? model.maxOutputTokens
        enriched.reasoningProfile = metadata.profiles.reasoning
        enriched.webSearchProfile = metadata.profiles.webSearch
        enriched.imageGenProfile = metadata.profiles.imageGen
        enriched.generationProfile = metadata.generationProfile
        let capabilityNullsAreAuthoritative = (metadata.capabilityContractVersion ?? 0)
            >= MetadataClient.authoritativeCapabilityContractVersion
        if capabilityNullsAreAuthoritative {
            enriched.toolCall = metadata.toolCall
            enriched.libraryAgentic = metadata.libraryAgentic
        } else {
            enriched.toolCall = metadata.toolCall ?? model.toolCall
            enriched.libraryAgentic = metadata.libraryAgentic ?? model.libraryAgentic
        }

        return enriched
    }

    nonisolated static func pricePresentation(
        from metadata: MetadataClient.ResolvedModelMetadata?
    ) -> (priceTier: String, promptPrice: Double?, completionPrice: Double?) {
        guard let metadata else {
            return ("", nil, nil)
        }

        switch metadata.pricingStatus {
        case "priced":
            if metadata.pricingUnit != "per_token" {
                return (L10n.tr("Non-standard billing"), nil, nil)
            }
            let effectivePrice = metadata.promptPerToken.flatMap { $0 > 0 ? $0 : nil }
                ?? metadata.completionPerToken.flatMap { $0 > 0 ? $0 : nil }
            return (
                effectivePrice.map(CostFormatter.formatPerMillion) ?? "",
                metadata.promptPerToken,
                metadata.completionPerToken
            )
        case "free":
            return (L10n.tr("Free"), metadata.promptPerToken ?? 0, metadata.completionPerToken ?? 0)
        default:
            return (L10n.tr("Price unknown"), nil, nil)
        }
    }

    nonisolated static func enrichProvider(
        _ provider: Provider,
        metadataClient: MetadataClient = .shared
    ) -> Provider {
        guard provider.kind != .relay else { return provider }

        let enrichedModels = provider.models.map { model in
            enrichStoredModel(model, providerKind: provider.kind, metadataClient: metadataClient)
        }

        guard enrichedModels != provider.models else { return provider }

        var updated = provider
        updated.models = enrichedModels
        return updated
    }


    private static func compareCatalogModels(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        let lhsRank = lhs.sortRank ?? 0
        let rhsRank = rhs.sortRank ?? 0
        if lhsRank != rhsRank { return lhsRank > rhsRank }

        let lhsCreated = lhs.createdAt ?? 0
        let rhsCreated = rhs.createdAt ?? 0
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }

        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    nonisolated static func compactContextText(_ contextLength: Int?) -> String? {
        guard let ctx = contextLength, ctx > 0 else { return nil }
        if ctx >= 1_000_000 { return "\(ctx / 1_000_000)M" }
        if ctx >= 1_000 { return "\(ctx / 1_000)K" }
        return "\(ctx)"
    }


    private static let dateSuffixRegex = try! NSRegularExpression(pattern: #"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$"#)

    static func canonicalKey(for model: AIModel) -> String {
        if let canonical = model.canonicalModelId, !canonical.isEmpty {
            return canonical
        }
        let id = model.id
        let range = NSRange(id.startIndex..., in: id)
        return dateSuffixRegex.stringByReplacingMatches(in: id, range: range, withTemplate: "")
    }

    static func deduplicateByCanonical(_ models: [AIModel]) -> [AIModel] {
        var seen = [String: Int]()
        var result: [AIModel] = []
        for model in models {
            let key = canonicalKey(for: model)
            if let idx = seen[key] {
                if model.id == key { result[idx] = model }
            } else {
                seen[key] = result.count
                result.append(model)
            }
        }
        return result
    }
}
