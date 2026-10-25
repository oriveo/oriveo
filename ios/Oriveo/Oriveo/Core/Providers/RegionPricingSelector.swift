import Foundation

/// Picks the price for a connection's effective region.
///
/// Effective region = the stored region option (`region:<id>`) > the option matching the connection URL > the first option.
/// When it equals an entry's regionScope, that entry replaces the five model-level price keys as a whole;
/// otherwise the model level is used. Relay and custom endpoints do not pick a region. The estimate currency is
/// the currency of the chosen price, with no conversion.
enum RegionPricingSelector {
    struct Selection: Sendable {
        let pricing: MetadataClient.ResolvedModelMetadata
        /// A region entry was chosen (rather than the model-level price).
        let regionEntryChosen: Bool
    }

    static func select(
        _ model: MetadataClient.ResolvedModelMetadata,
        regionOptions: [ProviderEndpointOption],
        endpointSource: ProviderEndpointSource?,
        baseURLText: String?,
        setupValues: [String: String]? = nil,
        kind: ProviderKind
    ) -> Selection {
        let modelLevel = Selection(pricing: model, regionEntryChosen: false)
        if kind == .relay || endpointSource == .custom || model.regionPricing.isEmpty { return modelLevel }
        guard let region = effectiveRegion(
            regionOptions: regionOptions,
            endpointSource: endpointSource,
            baseURLText: baseURLText,
            setupValues: setupValues
        ), let entry = model.regionPricing.first(where: { $0.regionScope == region }) else {
            return modelLevel
        }
        return Selection(pricing: MetadataClient.applyingRegionPrice(entry, to: model), regionEntryChosen: true)
    }

    /// Connection entry point: options come from `regionOptions(for:)`; source, URL and setup values come from the connection itself.
    static func select(
        _ model: MetadataClient.ResolvedModelMetadata,
        provider: Provider,
        setupCatalog: ProviderSetupCatalog = .current()
    ) -> Selection {
        select(
            model,
            regionOptions: regionOptions(for: provider.kind, setupCatalog: setupCatalog),
            endpointSource: provider.endpointSource,
            baseURLText: provider.baseURLText,
            setupValues: provider.setupValues,
            kind: provider.kind
        )
    }

    /// Region options used for selection: the setup catalog's options come first (delivered by metadata and checked
    /// against the trusted table, or the local table when nothing is delivered), followed by identity-table entries
    /// whose id is not listed. The identity table does not depend on whether metadata has loaded, so a cn
    /// connection is still recognized as the cn region before metadata arrives.
    static func regionOptions(
        for kind: ProviderKind,
        setupCatalog: ProviderSetupCatalog = .current()
    ) -> [ProviderEndpointOption] {
        let listed = setupCatalog.setupEndpointOptions(for: kind)
        let known = Set(listed.map(\.id))
        let identity = (ProviderSetupCatalog.identityRegions[kind] ?? []).filter { !known.contains($0.id) }
        return listed + identity
    }

    /// URL matching: after filling the template with the local setup values, an option URL is compared with the connection URL, both normalized by `ProviderEndpointSourceRules.matchKey`.
    static func effectiveRegion(
        regionOptions: [ProviderEndpointOption],
        endpointSource: ProviderEndpointSource?,
        baseURLText: String?,
        setupValues: [String: String]? = nil
    ) -> String? {
        if case .region(let id)? = endpointSource { return id }
        if let normalized = ProviderEndpointSourceRules.matchKey(baseURLText),
           let matched = regionOptions.first(where: { option in
               ProviderEndpointTemplate.filled(option.baseURLText, values: setupValues)
                   .flatMap(ProviderEndpointSourceRules.matchKey) == normalized
           }) {
            return matched.id
        }
        return regionOptions.first?.id
    }
}
