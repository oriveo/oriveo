//  ProviderCatalogResolver.swift

import Foundation
import os


struct ResolvedModel: Sendable {
    let model: AIModel
    let isEnabled: Bool
    let isManual: Bool
}

struct ResolvedProviderCatalog: Sendable {
    let catalog: [ResolvedModel]
    let enabledModels: [ResolvedModel]
    let recommendedModels: [ResolvedModel]
    let defaultModel: ResolvedModel?
    let availableModelCount: Int
    let hasManualModels: Bool
}


enum ProviderCatalogResolver {

    nonisolated private struct MemoKey: Hashable, Sendable {
        let provider: Provider
        let metadataGeneration: UInt64
    }

    nonisolated private struct MemoState: Sendable {
        var order: [MemoKey] = []
        var entries: [MemoKey: ResolvedProviderCatalog] = [:]
    }

    nonisolated private static let memoCapacity = 8
    nonisolated private static let memo = OSAllocatedUnfairLock(initialState: MemoState())

    nonisolated private static func memoized(_ key: MemoKey) -> ResolvedProviderCatalog? {
        memo.withLock { $0.entries[key] }
    }

    nonisolated private static func storeMemo(_ value: ResolvedProviderCatalog, for key: MemoKey) {
        memo.withLock { state in
            if state.entries.updateValue(value, forKey: key) == nil {
                state.order.append(key)
            }
            while state.order.count > memoCapacity {
                let expired = state.order.removeFirst()
                state.entries[expired] = nil
            }
        }
    }

#if DEBUG
    nonisolated static func resetMemoForTesting() {
        memo.withLock { $0 = MemoState() }
    }
#endif

#if DEBUG
    private static let debugResolveComputationCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    static var debugResolveComputationCount: Int {
        get { debugResolveComputationCountLock.withLock { $0 } }
        set { debugResolveComputationCountLock.withLock { $0 = newValue } }
    }
#endif

#if DEBUG
    private static let debugResolveCallCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    static var debugResolveCallCount: Int {
        get { debugResolveCallCountLock.withLock { $0 } }
        set { debugResolveCallCountLock.withLock { $0 = newValue } }
    }
#endif

    static func resolve(provider: Provider, metadata: MetadataClient = .shared) -> ResolvedProviderCatalog {
#if DEBUG
        debugResolveCallCountLock.withLock { $0 &+= 1 }
#endif
        let memoKey: MemoKey? = metadata === MetadataClient.shared
            ? MemoKey(
                provider: provider,
                metadataGeneration: MetadataClient.sharedSnapshotGeneration()
            )
            : nil
        if let memoKey, let cached = memoized(memoKey) { return cached }
#if DEBUG
        debugResolveComputationCountLock.withLock { $0 &+= 1 }
#endif
        let resolved = compute(provider: provider, metadata: metadata)
        if let memoKey { storeMemo(resolved, for: memoKey) }
        return resolved
    }

    private static func compute(
        provider: Provider,
        metadata: MetadataClient
    ) -> ResolvedProviderCatalog {
        if provider.kind == .relay || provider.authMode == .subscription {
            return resolveFromLocal(provider: provider, metadata: metadata)
        }

        let contract = metadata.contractVersionSnapshot()
        if contract.shouldSafeDegrade {
            return degradedCatalog(provider: provider)
        }

        let metadataModelIDs = metadata.providerModelIDs(providerKind: provider.kind)
        let defaultModelId = metadata.providerDefaultModelID(providerKind: provider.kind)

        guard !metadataModelIDs.isEmpty else {
            return degradedCatalog(provider: provider)
        }

        var rawCatalog: [AIModel] = []
        for modelID in metadataModelIDs {
            let resolved = metadata.resolveCatalogModel(modelID: modelID, providerKind: provider.kind)
            let model = buildAIModel(
                modelID: modelID,
                metadata: resolved,
                isDefault: modelID == defaultModelId
            )
            rawCatalog.append(model)
        }

        let enabledIds = Set(provider.models.map(\.id))
        var enabledIndex = Set<String>()
        for model in provider.models {
            for id in collectIdentifiers(for: model, providerKind: provider.kind, metadata: metadata) {
                enabledIndex.insert(id)
            }
        }

        var catalogIndex = Set<String>()
        var catalogIdSets: [[String]] = []
        catalogIdSets.reserveCapacity(rawCatalog.count)
        for model in rawCatalog {
            let ids = collectIdentifiers(for: model, providerKind: provider.kind, metadata: metadata)
            for id in ids { catalogIndex.insert(id) }
            catalogIdSets.append(ids)
        }

        var catalog: [ResolvedModel] = []
        var enabledModels: [ResolvedModel] = []
        var recommendedModels: [ResolvedModel] = []
        var hasManualModels = false

        for (i, catalogModel) in rawCatalog.enumerated() {
            let isEnabled = enabledIds.contains(catalogModel.id)
                || catalogIdSets[i].contains { enabledIndex.contains($0) }
            let resolved = ResolvedModel(model: catalogModel, isEnabled: isEnabled, isManual: false)
            catalog.append(resolved)

            if isEnabled {
                enabledModels.append(resolved)
            } else if catalogModel.isRecommended == true && catalogModel.isAvailable {
                recommendedModels.append(resolved)
            }
        }

        for enabledModel in provider.models {
            let ids = collectIdentifiers(for: enabledModel, providerKind: provider.kind, metadata: metadata)
            let matchesAnyCatalog = ids.contains { catalogIndex.contains($0) }
            if !matchesAnyCatalog {
                let resolved = ResolvedModel(model: enabledModel, isEnabled: true, isManual: true)
                catalog.insert(resolved, at: 0)
                enabledModels.insert(resolved, at: 0)
                hasManualModels = true
            }
        }

        recommendedModels.sort { ($0.model.sortRank ?? 0) > ($1.model.sortRank ?? 0) }

        let resolvedDefault = resolveDefaultModel(
            enabledModels: enabledModels,
            provider: provider,
            metadataDefaultId: defaultModelId
        )

        let availableCount = catalog.filter(\.model.isAvailable).count

        return ResolvedProviderCatalog(
            catalog: catalog,
            enabledModels: enabledModels,
            recommendedModels: Array(recommendedModels.prefix(6)),
            defaultModel: resolvedDefault,
            availableModelCount: availableCount,
            hasManualModels: hasManualModels
        )
    }


    private static func resolveFromLocal(
        provider: Provider,
        metadata: MetadataClient = .shared,
        forceManual: Bool = false
    ) -> ResolvedProviderCatalog {
        let enrichedCatalogModels: [AIModel] = {
            guard !forceManual && provider.kind == .relay else {
                return provider.catalogModels
            }
            let runtimeConfig = metadata.syncRelayRuntimeConfig()
            return RelayOfficialCatalogResolver.enrichCatalog(
                provider: provider,
                runtimeConfig: runtimeConfig,
                metadata: metadata
            )
        }()

        let enabledIds = Set(provider.models.map(\.id))
        var catalog: [ResolvedModel] = []
        var enabledModels: [ResolvedModel] = []
        var hasManualModels = false

        for model in enrichedCatalogModels {
            let isEnabled = enabledIds.contains(model.id)
                || provider.models.contains(where: {
                    ModelResolver.modelsShareSameRemoteModel($0, model, providerKind: provider.kind)
                })
            let isManual = forceManual || ModelResolver.isManualModel(model, providerKind: provider.kind)
            let resolved = ResolvedModel(model: model, isEnabled: isEnabled, isManual: isManual)
            catalog.append(resolved)
            if isEnabled { enabledModels.append(resolved) }
            if isManual { hasManualModels = true }
        }

        for model in provider.models {
            if !catalog.contains(where: {
                ModelResolver.modelsShareSameRemoteModel($0.model, model, providerKind: provider.kind)
            }) {
                let isManual = forceManual || ModelResolver.isManualModel(model, providerKind: provider.kind)
                let resolved = ResolvedModel(model: model, isEnabled: true, isManual: isManual)
                catalog.insert(resolved, at: 0)
                enabledModels.insert(resolved, at: 0)
                if isManual { hasManualModels = true }
            }
        }

        let resolvedDefault = resolveDefaultModel(
            enabledModels: enabledModels,
            provider: provider,
            metadataDefaultId: nil
        )

        return ResolvedProviderCatalog(
            catalog: catalog,
            enabledModels: enabledModels,
            recommendedModels: [],
            defaultModel: resolvedDefault,
            availableModelCount: catalog.filter(\.model.isAvailable).count,
            hasManualModels: hasManualModels
        )
    }


    private static func degradedCatalog(provider: Provider) -> ResolvedProviderCatalog {
        return resolveFromLocal(provider: provider, forceManual: true)
    }


    private static func collectIdentifiers(
        for model: AIModel,
        providerKind: ProviderKind,
        metadata: MetadataClient
    ) -> [String] {
        var ids: [String] = [model.id.lowercased()]

        if let canonical = model.canonicalModelId {
            ids.append(canonical.lowercased())
        }

        if let resolved = metadata.syncResolveCatalogModel(modelID: model.id, providerKind: providerKind) {
            ids.append(resolved.canonicalModelId.lowercased())
        }

        let strippedPrefix = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
        if strippedPrefix != model.id {
            ids.append(strippedPrefix.lowercased())
            if let resolved = metadata.syncResolveCatalogModel(modelID: strippedPrefix, providerKind: providerKind) {
                ids.append(resolved.canonicalModelId.lowercased())
            }
        }

        let preferred = ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: providerKind)
        ids.append(preferred.lowercased())

        let strippedDate = stripSnapshotDateSuffix(model.id)
        if strippedDate != model.id { ids.append(strippedDate.lowercased()) }
        if let canonical = model.canonicalModelId {
            let strippedCanonical = stripSnapshotDateSuffix(canonical)
            if strippedCanonical != canonical { ids.append(strippedCanonical.lowercased()) }
        }

        if providerKind != .openRouter {
            ids.append(model.name.lowercased())
        }

        return ids
    }


    private static func resolveDefaultModel(
        enabledModels: [ResolvedModel],
        provider: Provider,
        metadataDefaultId: String?
    ) -> ResolvedModel? {
        if let userDefault = provider.models.first(where: \.isDefault) {
            if let match = enabledModels.first(where: {
                $0.model.id.caseInsensitiveCompare(userDefault.id) == .orderedSame
                || ModelResolver.modelsShareSameRemoteModel($0.model, userDefault, providerKind: provider.kind)
            }) {
                return match
            }
        }

        if let metadataDefaultId {
            if let match = enabledModels.first(where: {
                $0.model.id.caseInsensitiveCompare(metadataDefaultId) == .orderedSame
                || $0.model.canonicalModelId?.caseInsensitiveCompare(metadataDefaultId) == .orderedSame
            }) {
                return match
            }
        }

        return enabledModels.first
    }


    private static func buildAIModel(
        modelID: String,
        metadata: MetadataClient.ResolvedModelMetadata?,
        isDefault: Bool
    ) -> AIModel {
        guard let metadata else {
            return AIModel(
                id: modelID,
                name: modelID,
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: isDefault,
                priceTier: ""
            )
        }

        let pricing = CatalogModelBuilder.pricePresentation(from: metadata)

        return AIModel(
            id: modelID,
            name: metadata.displayName ?? modelID,
            capabilities: metadata.capabilities.isEmpty ? [.text] : metadata.capabilities,
            reasoningModeAvailable: metadata.profiles.reasoning != nil,
            isAvailable: true,
            isDefault: isDefault || metadata.isDefault,
            priceTier: pricing.priceTier,
            summary: CatalogModelBuilder.compactContextText(metadata.contextLength),
            contextLength: metadata.contextLength,
            maxOutputTokens: metadata.maxOutputTokens,
            groupKey: metadata.uiHints.groupKey,
            groupName: metadata.uiHints.groupName,
            promptPrice: pricing.promptPrice,
            completionPrice: pricing.completionPrice,
            cacheReadInputPerMToken: metadata.cacheReadInputPerMToken,
            cacheCreationInputPerMToken: metadata.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken: metadata.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken: metadata.cacheWrite1hPerMToken,
            canonicalModelId: metadata.canonicalModelId,
            isRecommended: metadata.uiHints.recommended,
            sortRank: metadata.uiHints.rank,
            badgeOrder: metadata.uiHints.badgeOrder,
            reasoningProfile: metadata.profiles.reasoning,
            webSearchProfile: metadata.profiles.webSearch,
            imageGenProfile: metadata.profiles.imageGen,
            toolCall: metadata.toolCall,
            libraryAgentic: metadata.libraryAgentic
        )
    }

    private static let snapshotDateSuffixPattern = #"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$"#

    private static func stripSnapshotDateSuffix(_ modelID: String) -> String {
        guard !modelID.isEmpty else { return modelID }
        return modelID.replacingOccurrences(
            of: snapshotDateSuffixPattern,
            with: "",
            options: .regularExpression
        )
    }
}
