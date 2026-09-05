import Foundation

nonisolated enum ModelResolver {
    private static let snapshotDateSuffixPattern = #"(?:-\d{8}|-\d{4}-\d{2}-\d{2})$"#


    static func matchingModel(for storedModelID: String, in provider: Provider) -> AIModel? {
        matchingModel(modelID: storedModelID, in: provider.allModels, providerKind: provider.kind)
            ?? matchingModel(modelID: storedModelID, in: provider.models, providerKind: provider.kind)
    }

    static func matchingModel(modelID: String, in models: [AIModel], providerKind: ProviderKind) -> AIModel? {
        let lookupCandidates = normalizedLookupCandidates(for: modelID, providerKind: providerKind)

        for candidate in lookupCandidates {
            if let exactMatch = models.first(where: { $0.id.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return exactMatch
            }
        }

        return models.first { model in
            lookupCandidates.contains { candidate in
                modelMatchesStoredIdentifier(model, storedModelID: candidate, providerKind: providerKind)
            }
        }
    }

    static func modelsShareSameRemoteModel(_ lhs: AIModel, _ rhs: AIModel, providerKind: ProviderKind) -> Bool {
        let lhsIdentifier = preferredStoredModelIdentifier(for: lhs, providerKind: providerKind)
        let rhsIdentifier = preferredStoredModelIdentifier(for: rhs, providerKind: providerKind)

        if lhsIdentifier.caseInsensitiveCompare(rhsIdentifier) == .orderedSame {
            return true
        }

        guard providerKind != .openRouter else {
            return false
        }

        return lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame
    }

    static func preferredStoredModelIdentifier(for model: AIModel, providerKind: ProviderKind) -> String {
        let canonical = model.canonicalModelId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !canonical.isEmpty {
            return canonical
        }
        return resolvedProviderModelIdentifier(model.id, providerKind: providerKind)
    }

    static func resolvedProviderModelIdentifier(_ modelID: String, providerKind: ProviderKind) -> String {
        let manualPrefix = "\(providerKind.rawValue)-manual-"
        guard modelID.hasPrefix(manualPrefix) else { return modelID }
        return String(modelID.dropFirst(manualPrefix.count))
    }

    static func isManualModel(_ model: AIModel, providerKind: ProviderKind) -> Bool {
        if model.isManual { return true }
        return model.id.hasPrefix("\(providerKind.rawValue)-manual-")
    }

    private static func modelMatchesStoredIdentifier(
        _ model: AIModel,
        storedModelID: String,
        providerKind: ProviderKind
    ) -> Bool {
        let candidates = [
            preferredStoredModelIdentifier(for: model, providerKind: providerKind),
            resolvedProviderModelIdentifier(model.id, providerKind: providerKind),
            stripSnapshotDateSuffix(model.id),
            model.canonicalModelId.map(stripSnapshotDateSuffix) ?? "",
        ]

        return candidates.contains {
            $0.caseInsensitiveCompare(storedModelID) == .orderedSame
        }
    }

    static func normalizedLookupCandidates(for modelID: String, providerKind: ProviderKind) -> [String] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let resolved = resolvedProviderModelIdentifier(trimmed, providerKind: providerKind)
        let candidates = [
            trimmed,
            resolved,
            stripSnapshotDateSuffix(trimmed),
            stripSnapshotDateSuffix(resolved),
        ]

        return candidates.reduce(into: [String]()) { result, candidate in
            guard !candidate.isEmpty else { return }
            guard !result.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { return }
            result.append(candidate)
        }
    }

    static func stripSnapshotDateSuffix(_ modelID: String) -> String {
        modelID.replacingOccurrences(
            of: snapshotDateSuffixPattern,
            with: "",
            options: .regularExpression
        )
    }


    static func synchronizeDefaultSelection(in provider: Provider, preferredModelID: String?) -> Provider {
        var updatedProvider = provider
        let resolvedDefaultID = preferredModelID
            ?? updatedProvider.models.first(where: \.isDefault)?.id
            ?? updatedProvider.catalogModels.first(where: \.isDefault)?.id

        updatedProvider.models = markDefaultModel(
            in: updatedProvider.models,
            preferredModelID: resolvedDefaultID,
            providerKind: updatedProvider.kind
        )
        updatedProvider.catalogModels = markDefaultFlag(
            in: updatedProvider.catalogModels,
            preferredModelID: resolvedDefaultID,
            providerKind: updatedProvider.kind
        )

        return updatedProvider
    }

    static func markDefaultModel(in models: [AIModel], preferredModelID: String?, providerKind: ProviderKind) -> [AIModel] {
        guard !models.isEmpty else { return [] }

        let resolvedDefaultID = preferredModelID.flatMap { preferredModelID in
            matchingModel(modelID: preferredModelID, in: models, providerKind: providerKind)?.id
        } ?? models.first(where: \.isDefault)?.id ?? models.first?.id

        return models.enumerated().map { index, model in
            var updatedModel = model
            updatedModel.isDefault = model.id == resolvedDefaultID || (resolvedDefaultID == nil && index == 0)
            return updatedModel
        }
    }

    static func markDefaultFlag(in models: [AIModel], preferredModelID: String?, providerKind: ProviderKind) -> [AIModel] {
        let resolvedDefaultID = preferredModelID.map { resolvedProviderModelIdentifier($0, providerKind: providerKind) }

        return models.map { model in
            var updatedModel = model
            updatedModel.isDefault = resolvedDefaultID.map {
                resolvedProviderModelIdentifier(model.id, providerKind: providerKind) == $0
            } ?? false
            return updatedModel
        }
    }


    static func mergeManualModels(from existingModels: [AIModel], into syncedModels: [AIModel], providerKind: ProviderKind) -> [AIModel] {
        let manualModels = existingModels.filter { isManualModel($0, providerKind: providerKind) }
        let preferredDefaultID = existingModels.first(where: \.isDefault)?.id

        var mergedModels = syncedModels
        for manualModel in manualModels {
            let duplicateExists = mergedModels.contains { modelsShareSameRemoteModel($0, manualModel, providerKind: providerKind) }
            if !duplicateExists {
                mergedModels.insert(manualModel, at: 0)
            }
        }

        let resolvedDefaultID = preferredDefaultID.flatMap { defaultID in
            matchingModel(for: defaultID, in: Provider(
                id: UUID(),
                kind: providerKind,
                status: .connected,
                models: mergedModels,
                catalogModels: mergedModels,
                lastCheckedAt: nil,
                apiKey: "",
                apiKeyPreview: "",
                lastError: nil,
                baseURLText: nil
            ))?.id
        } ?? mergedModels.first(where: \.isDefault)?.id ?? mergedModels.first?.id

        return mergedModels.enumerated().map { index, model in
            var updatedModel = model
            updatedModel.isDefault = model.id == resolvedDefaultID || (resolvedDefaultID == nil && index == 0)
            return updatedModel
        }
    }

    static func makeEnabledModels(
        from existingEnabledModels: [AIModel],
        catalogModels: [AIModel],
        providerKind: ProviderKind,
        legacyCatalogModels: [AIModel] = [],
        repairLegacyAutoEnabledAll: Bool = false
    ) -> [AIModel] {
        guard !catalogModels.isEmpty else { return existingEnabledModels }

        let resolvedExistingModels = existingEnabledModels.compactMap { existingModel in
            matchingModel(modelID: existingModel.id, in: catalogModels, providerKind: providerKind)
        }

        let selectedModels: [AIModel]
        if repairLegacyAutoEnabledAll && looksLikeLegacyAutoEnabledAll(
            existingEnabledModels: existingEnabledModels,
            legacyCatalogModels: legacyCatalogModels,
            catalogModels: catalogModels,
            providerKind: providerKind
        ) {
            selectedModels = initialEnabledModels(from: catalogModels, providerKind: providerKind)
        } else if resolvedExistingModels.isEmpty {
            selectedModels = initialEnabledModels(from: catalogModels, providerKind: providerKind)
        } else {
            selectedModels = resolvedExistingModels
        }

        let preferredDefaultID = existingEnabledModels.first(where: \.isDefault)?.id
            ?? selectedModels.first(where: \.isDefault)?.id
            ?? catalogModels.first(where: \.isDefault)?.id

        return markDefaultModel(
            in: selectedModels,
            preferredModelID: preferredDefaultID,
            providerKind: providerKind
        )
    }

    private static func looksLikeLegacyAutoEnabledAll(
        existingEnabledModels: [AIModel],
        legacyCatalogModels: [AIModel],
        catalogModels: [AIModel],
        providerKind: ProviderKind
    ) -> Bool {
        let resolvedEnabledIDs = resolvedCanonicalIDs(
            from: existingEnabledModels,
            in: catalogModels,
            providerKind: providerKind
        )
        guard
            !resolvedEnabledIDs.isEmpty,
            resolvedEnabledIDs.count == existingEnabledModels.count
        else {
            return false
        }

        if !legacyCatalogModels.isEmpty {
            let resolvedLegacyCatalogIDs = resolvedCanonicalIDs(
                from: legacyCatalogModels,
                in: catalogModels,
                providerKind: providerKind
            )
            if
                !resolvedLegacyCatalogIDs.isEmpty,
                resolvedLegacyCatalogIDs.count == legacyCatalogModels.count,
                resolvedLegacyCatalogIDs == resolvedEnabledIDs
            {
                return true
            }
        }

        return false
    }

    private static func resolvedCanonicalIDs(
        from sourceModels: [AIModel],
        in catalogModels: [AIModel],
        providerKind: ProviderKind
    ) -> [String] {
        var ids: [String] = []

        for sourceModel in sourceModels {
            guard
                let matched = matchingModel(
                    modelID: sourceModel.id,
                    in: catalogModels,
                    providerKind: providerKind
                ),
                !ids.contains(matched.id)
            else {
                continue
            }
            ids.append(matched.id)
        }

        return ids
    }

    static func allEnabledModels(from catalogModels: [AIModel], preferredModelID: String?, providerKind: ProviderKind) -> [AIModel] {
        guard !catalogModels.isEmpty else { return [] }

        return markDefaultModel(
            in: catalogModels,
            preferredModelID: preferredModelID ?? catalogModels.first(where: \.isDefault)?.id,
            providerKind: providerKind
        )
    }

    static func initialEnabledModels(from catalogModels: [AIModel], providerKind: ProviderKind) -> [AIModel] {
        guard !catalogModels.isEmpty else { return [] }

        let availableModels = catalogModels.filter(\.isAvailable)
        let candidatePool = availableModels.isEmpty ? catalogModels : availableModels
        let initialModel = candidatePool.first(where: \.isDefault)
            ?? catalogModels.first(where: \.isDefault)
            ?? candidatePool.first
            ?? catalogModels.first

        return markDefaultModel(
            in: initialModel.map { [$0] } ?? [],
            preferredModelID: initialModel?.id ?? catalogModels.first(where: \.isDefault)?.id,
            providerKind: providerKind
        )
    }


    static func displayName(forManualModelID modelID: String, providerKind: ProviderKind) -> String {
        guard (providerKind == .openRouter || providerKind == .siliconFlow),
              let rawName = modelID.split(separator: "/", maxSplits: 1).last,
              modelID.contains("/") else {
            return modelID
        }

        return String(rawName)
    }

    static func groupKey(forManualModelID modelID: String, providerKind: ProviderKind) -> String? {
        guard (providerKind == .openRouter || providerKind == .siliconFlow),
              let rawGroup = modelID.split(separator: "/", maxSplits: 1).first,
              modelID.contains("/") else {
            return nil
        }

        return String(rawGroup).lowercased()
    }

    static func groupName(forManualModelID modelID: String, providerKind: ProviderKind) -> String? {
        guard let groupKey = groupKey(forManualModelID: modelID, providerKind: providerKind) else {
            return nil
        }

        if providerKind == .siliconFlow {
            return SiliconFlowVendorName.displayName(for: groupKey)
        }
        return OpenRouterVendorName.displayName(for: groupKey)
    }
}
