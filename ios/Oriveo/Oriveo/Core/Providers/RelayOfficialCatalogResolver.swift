//  RelayOfficialCatalogResolver.swift

import Foundation

enum RelayOfficialCatalogResolver {
    /// The only function that matches a Relay model to the official catalog (canonicalModelId of the model first, otherwise id);
    /// shared by capability inheritance, delivery pricing and the price label. `modelID` overrides the key used when matching by id (a hand-entered model passes the normalized remote id).
    static func officialMatch(
        for model: AIModel,
        provider: Provider,
        metadata: MetadataClient,
        modelID: String? = nil
    ) -> MetadataClient.RelayCatalogMatchResult? {
        officialMatch(
            modelID: modelID ?? model.id,
            canonicalModelId: model.canonicalModelId,
            transportPriority: RelayRuntimeSupport.transportProviderKind(for: provider, model: model),
            metadata: metadata
        )
    }

    /// Matching by key: canonicalModelId is used first only when it is non-empty after trimming, then id; the Service layer, which only has a model id and canonical, also goes through here.
    static func officialMatch(
        modelID: String,
        canonicalModelId: String?,
        transportPriority: ProviderKind?,
        metadata: MetadataClient
    ) -> MetadataClient.RelayCatalogMatchResult? {
        let canonical = canonicalModelId
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0 == modelID ? nil : $0 }
        for key in [canonical, modelID].compactMap({ $0 }) {
            if let match = metadata.syncResolveCatalogModelAcrossProvidersWithProvider(
                modelID: key, transportPriority: transportPriority
            ) {
                return match
            }
        }
        return nil
    }
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
                runtimeConfig: runtimeConfig,
                metadata: metadata
            )
        }

        let envelope = RelayRuntimeSupport.envelopeKey(for: provider, model: localModel)
            .flatMap { runtimeConfig.transportEnvelopes[$0] }

        guard let match = officialMatch(for: localModel, provider: provider, metadata: metadata) else {
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
        let nativeFile = nativeFileInheritance(match: match, envelope: envelope, model: localModel)

        return AIModel(
            id: localModel.id,
            name: match.metadata.displayName ?? localModel.name,
            capabilities: effectiveCaps,
            reasoningModeAvailable: effectiveCaps.contains(.reasoning) && reasoningProfile != nil,
            isAvailable: localModel.isAvailable,
            isDefault: localModel.isDefault,
            priceTier: storedPriceTier(pricing.priceTier, match: match, localModel: localModel),
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
            generationProfile: match.metadata.generationProfile,
            attachmentExtraction: nativeFile.extraction,
            nativeFileMimes: nativeFile.mimes,
            pdfNativeDefault: nativeFile.pdfNativeDefault
        )
    }

    /// A manually entered model that exactly matches the catalog (by its raw id or with the date suffix
    /// stripped) inherits capabilities (union), profiles and pricing the same way catalog models do.
    /// The user's own name and summary are kept, the user's own capabilities are kept, and profiles
    /// always follow the official data.
    private static func enrichManualOfficialPricing(
        localModel: AIModel,
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
        metadata: MetadataClient
    ) -> AIModel {
        let remoteModelID = ModelResolver.resolvedProviderModelIdentifier(
            localModel.id,
            providerKind: provider.kind
        )
        guard let match = officialMatch(
            for: localModel, provider: provider, metadata: metadata, modelID: remoteModelID
        ) else {
            return localModel
        }

        let pricing = CatalogModelBuilder.pricePresentation(from: match.metadata)
        let envelope = RelayRuntimeSupport.envelopeKey(for: provider, model: localModel)
            .flatMap { runtimeConfig.transportEnvelopes[$0] }
        let nativeFile = nativeFileInheritance(match: match, envelope: envelope, model: localModel)
        var enriched = localModel
        let officialCaps = match.metadata.capabilities.isEmpty ? [.text] : match.metadata.capabilities
        let intersected = intersectCapabilities(officialCaps, envelope: envelope)
        let effectiveCaps = mergeUnique(base: intersected.isEmpty ? [.text] : intersected, add: localModel.capabilities)
        enriched.capabilities = effectiveCaps
        // Profiles follow the same rule as catalog models: official data wins, and a missing official
        // profile (or a capability that is not present) clears any stale local value. Same on all platforms.
        enriched.reasoningProfile = effectiveCaps.contains(.reasoning) ? match.metadata.profiles.reasoning : nil
        enriched.webSearchProfile = effectiveCaps.contains(.web) ? match.metadata.profiles.webSearch : nil
        enriched.imageGenProfile = effectiveCaps.contains(.imageGen) ? match.metadata.profiles.imageGen : nil
        enriched.generationProfile = match.metadata.generationProfile
        enriched.reasoningModeAvailable = effectiveCaps.contains(.reasoning) && enriched.reasoningProfile != nil
        // Written back even when empty, so a stale allowlist on a stored model is cleared.
        enriched.nativeFileMimes = nativeFile.mimes
        enriched.pdfNativeDefault = nativeFile.pdfNativeDefault
        enriched.attachmentExtraction = nativeFile.extraction
        enriched.canonicalModelId = match.canonicalModelId
        enriched.priceTier = storedPriceTier(pricing.priceTier, match: match, localModel: localModel)
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

    /// Stored string: when the catalog has a price, store it (USD uses the "$" form, non-USD stores empty); the local hand-entered string is kept only when the catalog has no price label and the currency is USD.
    /// A non-USD price keeps no local string: display reads the catalog price and currency through `CatalogModelBuilder.connectionPriced`.
    private static func storedPriceTier(
        _ catalogTier: String,
        match: MetadataClient.RelayCatalogMatchResult,
        localModel: AIModel
    ) -> String {
        guard catalogTier.isEmpty,
              CostCalculator.currencyCode(of: match.metadata) == CostCalculator.usd else { return catalogTier }
        return localModel.priceTier
    }

    // MARK: - Native File Allowlist

    /// The catalog's native-file fields describe what the vendor's own protocol accepts, so they
    /// only carry over when the match comes from the provider that owns this transport. A
    /// cross-provider match, or an envelope that turns native files off, yields empty values.
    /// A missing envelope does not count as off.
    /// If the model's protocol was only established by a 1-token probe (`reachable`), the probe cannot
    /// prove that file blocks are accepted as-is, so the allowlist and the PDF default are not inherited;
    /// the extraction limits still are. `observed` / `user` sources and following the connection are unchanged.
    private static func nativeFileInheritance(
        match: MetadataClient.RelayCatalogMatchResult,
        envelope: MetadataClient.RelayTransportEnvelope?,
        model: AIModel
    ) -> (mimes: [String], pdfNativeDefault: Bool, extraction: AttachmentExtractionLimits?) {
        guard match.source == .transportFirst, envelope?.nativeFile != false else {
            return ([], false, nil)
        }
        if model.relayTransport != nil, model.relayTransportSource == .reachable {
            return ([], false, match.metadata.attachmentExtraction)
        }
        return (
            match.metadata.nativeFileMimes,
            match.metadata.pdfNativeDefault,
            match.metadata.attachmentExtraction
        )
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
