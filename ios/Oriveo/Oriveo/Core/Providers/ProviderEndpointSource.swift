import Foundation

/// Endpoint source recorded for an official provider (fixture `shared/test-fixtures/provider-catalog/endpoint-source.v1.json`).
///
/// Stored on this device only: not in the sync payload and not in backup exports. `baseURLText` still holds the literal address (older clients and sync read it);
/// at request time `default` / `region:<id>` are computed from the current metadata, so when the server changes an address it reaches existing records without a release.
nonisolated enum ProviderEndpointSource: Hashable, Sendable, Codable {
    case `default`
    case region(String)
    case custom

    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "custom": self = .custom
        default:
            guard rawValue.hasPrefix("region:") else { return nil }
            let id = String(rawValue.dropFirst("region:".count))
            guard !id.isEmpty else { return nil }
            self = .region(id)
        }
    }

    var rawValue: String {
        switch self {
        case .default: return "default"
        case .custom: return "custom"
        case .region(let id): return "region:\(id)"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown endpointSource"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One item of `providerConfigs[].setupFields`. The ids the client knows form a closed set; a new id requires a release.
nonisolated struct ProviderSetupFieldDefinition: Codable, Sendable, Equatable {
    static let knownIDs: Set<String> = ["workspaceId"]

    let id: String
    let required: Bool
}

/// Lenient decoding of `setupFields`: a wrong shape counts as a missing field, and unknown ids are dropped one by one so the whole providerConfigs never fails to decode.
nonisolated struct ProviderSetupFieldList: Codable, Sendable, Equatable {
    let fields: [ProviderSetupFieldDefinition]

    init(fields: [ProviderSetupFieldDefinition]) {
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([LossyField].self)) ?? []
        var seen = Set<String>()
        fields = raw.compactMap { item in
            guard let id = item.id, ProviderSetupFieldDefinition.knownIDs.contains(id),
                  seen.insert(id).inserted else { return nil }
            return ProviderSetupFieldDefinition(id: id, required: item.required ?? true)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    private struct LossyField: Decodable {
        let id: String?
        let required: Bool?

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? c?.decodeIfPresent(String.self, forKey: .id)
            required = try? c?.decodeIfPresent(Bool.self, forKey: .required)
        }

        private enum CodingKeys: String, CodingKey { case id, required }
    }
}

/// The part of the addresses that is delivered by metadata and has passed the trusted table. When nothing is delivered this is nil, and requests fall back to the literal address.
nonisolated struct OfficialEndpointMetadata: Sendable, Equatable {
    struct Region: Sendable, Equatable {
        let id: String
        /// Same shape as the catalog (scheme removed); may contain a `{workspaceId}` placeholder.
        let baseURLText: String
    }

    let defaultBaseURLText: String?
    let regions: [Region]
}

/// Address template placeholders: only `{id}` from the closed set is recognized, and the value must be a single DNS label.
nonisolated enum ProviderEndpointTemplate {
    static func placeholders(in template: String) -> [String] {
        var result: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let name = String(rest[afterOpen..<close])
            if !result.contains(name) { result.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// Used by the trusted-table check at decode time: replaces each placeholder with `a`.
    static func trustProbe(_ template: String) -> String {
        placeholders(in: template).reduce(template) { $0.replacingOccurrences(of: "{\($1)}", with: "a") }
    }

    /// Trims whitespace and lowercases; returns nil if it is not a single DNS label.
    static func normalizedValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (1...63).contains(value.count),
              !value.hasPrefix("-"), !value.hasSuffix("-") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard value.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    /// Fills the template with stored values; if any placeholder lacks a valid value, returns nil (the caller falls back to the literal address).
    static func filled(_ template: String, values: [String: String]?) -> String? {
        var output = template
        for name in placeholders(in: template) {
            guard let value = normalizedValue(values?[name]) else { return nil }
            output = output.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return output
    }
}

/// Retired official regions: existing records are lazily migrated to the replacement region. The table is `ProviderKind.retiredEndpointRegions`.
nonisolated struct RetiredEndpointRegion: Sendable, Equatable {
    let regionID: String
    /// Normalized host (lowercase).
    let host: String
    let replacementID: String
    /// The replacement address written as the literal when there is no trusted metadata (same shape as the catalog, without scheme).
    let builtInReplacementBaseURLText: String
}

/// Classification and on-demand computation rules, as pure functions; the entry points on Provider are `Provider.requestBaseURLText`.
nonisolated enum ProviderEndpointSourceRules {

    /// Normalization before matching: trim, treat a missing scheme as https, lowercase scheme and host, drop the trailing `/`, drop a trailing `/compatible-mode/v1`.
    static func matchKey(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let schemeEnd = value.range(of: "://") else { return nil }
        let scheme = value[..<schemeEnd.lowerBound].lowercased()
        let rest = value[schemeEnd.upperBound...]
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let host = rest[..<hostEnd].lowercased()
        var path = String(rest[hostEnd...])
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/compatible-mode/v1") {
            path.removeLast("/compatible-mode/v1".count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        return "\(scheme)://\(host)\(path)"
    }

    /// Region match -> current trusted metadata default -> this client's built-in default -> custom; an empty address counts as default.
    /// A templated region takes part in matching only if the stored values can fill it. The built-in default step keeps
    /// existing records that are classified for the first time only after the server changed the default under `default`, so they follow the new default.
    static func classify(
        baseURLText: String?,
        setupValues: [String: String]?,
        metadata: OfficialEndpointMetadata,
        builtInDefaultBaseURLText: String? = nil
    ) -> ProviderEndpointSource {
        guard let key = matchKey(baseURLText) else { return .default }
        if let region = matchingRegion(key: key, setupValues: setupValues, metadata: metadata) {
            return .region(region.id)
        }
        if let defaultBase = metadata.defaultBaseURLText,
           let candidate = ProviderEndpointTemplate.filled(defaultBase, values: setupValues),
           matchKey(candidate) == key {
            return .default
        }
        if let builtIn = matchKey(builtInDefaultBaseURLText), builtIn == key {
            return .default
        }
        return .custom
    }

    private static func matchingRegion(
        key: String,
        setupValues: [String: String]?,
        metadata: OfficialEndpointMetadata
    ) -> OfficialEndpointMetadata.Region? {
        metadata.regions.first { region in
            guard let candidate = ProviderEndpointTemplate.filled(region.baseURLText, values: setupValues) else { return false }
            return matchKey(candidate) == key
        }
    }

    /// The host segment of `matchKey`; nil for an empty address.
    static func host(_ raw: String?) -> String? {
        guard let key = matchKey(raw), let schemeEnd = key.range(of: "://") else { return nil }
        let rest = key[schemeEnd.upperBound...]
        let host = rest.prefix { $0 != "/" }
        return host.isEmpty ? nil : String(host)
    }

    /// Lazy migration, shared by the startup backfill and request time, as a pure function.
    /// - R1: the source is a retired region, or the literal host is a retired host (any source) -> switch to the replacement region and rewrite the literal to the replacement address
    ///   from current trusted metadata (the built-in one if missing); does not depend on metadata.
    /// - R2: the source is `default` and the literal is non-empty and equals one of the current trusted regions -> `region:<id>`, the literal unchanged.
    /// Unclassified records are not classified here (classification needs metadata, see `classify`).
    static func reconciled(
        baseURLText: String?,
        source: ProviderEndpointSource?,
        setupValues: [String: String]?,
        metadata: OfficialEndpointMetadata?,
        retiredRegions: [RetiredEndpointRegion]
    ) -> (baseURLText: String?, source: ProviderEndpointSource?) {
        let literalHost = host(baseURLText)
        if let retired = retiredRegions.first(where: {
            source == .region($0.regionID) || (literalHost != nil && literalHost == $0.host)
        }) {
            let delivered = metadata?.regions.first { $0.id == retired.replacementID }
                .flatMap { ProviderEndpointTemplate.filled($0.baseURLText, values: setupValues) }
            return (delivered ?? retired.builtInReplacementBaseURLText, .region(retired.replacementID))
        }
        if source == .default, let metadata, let key = matchKey(baseURLText),
           let region = matchingRegion(key: key, setupValues: setupValues, metadata: metadata) {
            return (baseURLText, .region(region.id))
        }
        return (baseURLText, source)
    }

    /// The address computed at request time. Metadata missing / the item deleted / placeholders cannot be filled -> the literal address.
    static func resolvedBaseURLText(
        baseURLText: String?,
        source: ProviderEndpointSource?,
        setupValues: [String: String]?,
        metadata: OfficialEndpointMetadata?,
        builtInDefaultBaseURLText: String? = nil
    ) -> String? {
        guard let metadata else { return baseURLText }
        // An empty literal address also follows the current trusted default:
        // a service with a hardcoded base URL cannot get a metadata transport, and handing it nil would fall back to the service's own default.
        let effective = matchKey(baseURLText) == nil
            ? (source ?? .default)
            : (source ?? classify(
                baseURLText: baseURLText, setupValues: setupValues, metadata: metadata,
                builtInDefaultBaseURLText: builtInDefaultBaseURLText
            ))
        let template: String?
        switch effective {
        case .custom:
            return baseURLText
        case .default:
            template = metadata.defaultBaseURLText
        case .region(let id):
            template = metadata.regions.first(where: { $0.id == id })?.baseURLText
        }
        guard let template, let filled = ProviderEndpointTemplate.filled(template, values: setupValues) else {
            return baseURLText
        }
        return filled
    }

    /// Recompute the source after writing `baseURLText`: if the normalized address did not change, keep the original source (after metadata changes an address,
    /// an old literal address that is saved unchanged or synced back must not downgrade `region` to `custom`); when metadata is missing, stay unclassified.
    static func reclassified(
        previousBaseURLText: String?,
        previousSource: ProviderEndpointSource?,
        newBaseURLText: String?,
        setupValues: [String: String]?,
        metadata: OfficialEndpointMetadata?,
        builtInDefaultBaseURLText: String? = nil
    ) -> ProviderEndpointSource? {
        if let previousSource, matchKey(previousBaseURLText) == matchKey(newBaseURLText) {
            return previousSource
        }
        guard let metadata else { return nil }
        return classify(
            baseURLText: newBaseURLText, setupValues: setupValues, metadata: metadata,
            builtInDefaultBaseURLText: builtInDefaultBaseURLText
        )
    }
}

extension Provider {
    /// Only the 15 official providers go through `endpointSource`; Relay and local connections use the literal address as is.
    var usesEndpointSource: Bool {
        switch kind {
        case .relay: return false
        default: return true
        }
    }

    /// The single entry point for the address on the real send path: an official provider first runs the lazy migration in memory (the same rules as the startup backfill),
    /// then computes by source; everything else returns `baseURLText` as is.
    func requestBaseURLText(catalog: ProviderSetupCatalog = .current()) -> String? {
        guard usesEndpointSource else { return baseURLText }
        let metadata = catalog.officialEndpointMetadata(for: kind)
        let migrated = ProviderEndpointSourceRules.reconciled(
            baseURLText: baseURLText,
            source: endpointSource,
            setupValues: setupValues,
            metadata: metadata,
            retiredRegions: kind.retiredEndpointRegions
        )
        return ProviderEndpointSourceRules.resolvedBaseURLText(
            baseURLText: migrated.baseURLText,
            source: migrated.source,
            setupValues: setupValues,
            metadata: metadata,
            builtInDefaultBaseURLText: kind.defaultBaseURLText
        )
    }

    /// Startup backfill: unclassified records are first classified by current metadata, then R1 / R2 run. Returns whether anything changed.
    @discardableResult
    mutating func reconcileEndpointSource(catalog: ProviderSetupCatalog = .current()) -> Bool {
        guard usesEndpointSource else { return false }
        var changed = classifyEndpointSourceIfNeeded(catalog: catalog)
        let migrated = ProviderEndpointSourceRules.reconciled(
            baseURLText: baseURLText,
            source: endpointSource,
            setupValues: setupValues,
            metadata: catalog.officialEndpointMetadata(for: kind),
            retiredRegions: kind.retiredEndpointRegions
        )
        if migrated.source != endpointSource || migrated.baseURLText != baseURLText {
            baseURLText = migrated.baseURLText
            endpointSource = migrated.source
            changed = true
        }
        return changed
    }

    /// Call after writing `baseURLText` (address edit, region switch, sync landing).
    mutating func reclassifyEndpointSource(
        previousBaseURLText: String?,
        catalog: ProviderSetupCatalog = .current()
    ) {
        guard usesEndpointSource else { return }
        endpointSource = ProviderEndpointSourceRules.reclassified(
            previousBaseURLText: previousBaseURLText,
            previousSource: endpointSource,
            newBaseURLText: baseURLText,
            setupValues: setupValues,
            metadata: catalog.officialEndpointMetadata(for: kind),
            builtInDefaultBaseURLText: kind.defaultBaseURLText
        )
    }

    /// Unclassified official providers are classified by current metadata; when metadata is missing they stay unclassified. Returns whether anything changed.
    @discardableResult
    mutating func classifyEndpointSourceIfNeeded(catalog: ProviderSetupCatalog = .current()) -> Bool {
        guard usesEndpointSource, endpointSource == nil,
              let metadata = catalog.officialEndpointMetadata(for: kind) else { return false }
        endpointSource = ProviderEndpointSourceRules.classify(
            baseURLText: baseURLText,
            setupValues: setupValues,
            metadata: metadata,
            builtInDefaultBaseURLText: kind.defaultBaseURLText
        )
        return true
    }
}
