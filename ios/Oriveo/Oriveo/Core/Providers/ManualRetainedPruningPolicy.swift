//  ManualRetainedPruningPolicy.swift

import Foundation

enum ManualRetainedPruningPolicy {

    static let manualRetainedPruningEnabled: Bool = false

    #if DEBUG
    nonisolated(unsafe) static var flagOverrideForTesting: Bool?
    #endif

    private static var isEnabled: Bool {
        #if DEBUG
        return flagOverrideForTesting ?? manualRetainedPruningEnabled
        #else
        return manualRetainedPruningEnabled
        #endif
    }

    /// - Parameters:
    static func apply(
        provider: Provider,
        resolvedCatalog: ResolvedProviderCatalog,
        metadata: MetadataClient = .shared
    ) -> [AIModel] {
        guard isEnabled else {
            return provider.models
        }

        if provider.kind == .relay {
            return provider.models
        }

        let prunedIdentifiers = Set(
            resolvedCatalog.enabledModels
                .filter(\.isManual)
                .map { $0.model.id.lowercased() }
        )

        guard !prunedIdentifiers.isEmpty else {
            return provider.models
        }

        if !prunedIdentifiers.isEmpty {
            print("[ManualRetainedPruningPolicy] pruned \(prunedIdentifiers.count) ids from \(provider.kind): \(prunedIdentifiers)")
        }

        var remaining = provider.models.filter { model in
            !prunedIdentifiers.contains(model.id.lowercased())
        }

        let defaultWasPruned = provider.models.contains { model in
            model.isDefault && prunedIdentifiers.contains(model.id.lowercased())
        }

        if defaultWasPruned {
            if let metadataDefaultId = metadata.providerDefaultModelID(providerKind: provider.kind),
               let fallbackIndex = remaining.firstIndex(where: {
                   $0.id.caseInsensitiveCompare(metadataDefaultId) == .orderedSame
                   || $0.canonicalModelId?.caseInsensitiveCompare(metadataDefaultId) == .orderedSame
               }) {
                for index in remaining.indices { remaining[index].isDefault = false }
                remaining[fallbackIndex].isDefault = true
            } else if let firstIndex = remaining.indices.first {
                for index in remaining.indices { remaining[index].isDefault = false }
                remaining[firstIndex].isDefault = true
            }
        }

        return remaining
    }

    static func recordActivation(provider: Provider, count: Int) {
        guard isEnabled, count > 0 else { return }
        print("[ManualRetainedPruningPolicy] activated \(provider.kind) with \(count) manual models")
    }
}
