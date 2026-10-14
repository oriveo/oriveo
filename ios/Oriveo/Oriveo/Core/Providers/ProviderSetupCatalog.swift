import Foundation
import os

struct ProviderSetupDefaults: Sendable, Equatable {
    let displayName: String
    let shortName: String
    let apiKeyPlaceholder: String
    let defaultBaseURLText: String?
    let autoFillNote: String?
}

struct ProviderSetupSubmission: Sendable, Equatable {
    let baseURLText: String?
    let endpointSource: ProviderEndpointSource
    let setupValues: [String: String]?
}

struct ProviderSetupCatalog: Sendable, Equatable {
    let directProviders: [ProviderKind]
    let aggregatorProviders: [ProviderKind]
    private let defaultsByKind: [ProviderKind: ProviderSetupDefaults]
    private let regionsByKind: [ProviderKind: [ProviderEndpointOption]]
    /// The table the detail page uses to echo the current region literally: delivered regions do not pass through the trusted-host table (the built-in table is used when none is delivered). The trusted table only constrains what can be chosen
    /// and never rewrites a value the user has stored. Deterministic IDs do not use it; they use the frozen `identityRegions`.
    private let literalEchoRegionsByKind: [ProviderKind: [ProviderEndpointOption]]
    /// Holds only addresses that metadata actually delivered and that passed the trusted table (used by the on-demand calculation); a local fallback table does not count as delivered.
    private var endpointMetadataByKind: [ProviderKind: OfficialEndpointMetadata] = [:]

    func displayName(for kind: ProviderKind) -> String {
        defaultsByKind[kind]?.displayName ?? kind.displayName
    }

    func shortName(for kind: ProviderKind) -> String {
        defaultsByKind[kind]?.shortName ?? kind.shortName
    }

    func apiKeyPlaceholder(for kind: ProviderKind) -> String {
        defaultsByKind[kind]?.apiKeyPlaceholder ?? kind.apiKeyPlaceholder
    }

    func defaultBaseURLText(for kind: ProviderKind) -> String? {
        defaultsByKind[kind]?.defaultBaseURLText ?? kind.defaultBaseURLText
    }

    func autoFillNote(for kind: ProviderKind) -> String? {
        defaultsByKind[kind]?.autoFillNote ?? kind.autoFillNote
    }

    func tagline(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI: return "Flagship GPT models"
        case .anthropic: return "Claude models"
        case .gemini: return "Text, image & video"
        case .deepseek: return "Reasoning & chat"
        case .grok: return "xAI models"
        case .miniMax: return "Multimodal models"
        case .zhipu: return "GLM models"
        case .qwen: return "Alibaba models"
        case .moonshot: return "Long context"
        case .mistral: return "Mistral AI models"
        case .siliconFlow: return "Multi-provider gateway"
        case .openRouter: return "200+ models"
        case .groq: return "Ultra-fast inference"
        case .together: return "Open-source models"
        case .fireworks: return "Fast & affordable"
        default: return nil
        }
    }

    func setupEndpointOptions(for kind: ProviderKind) -> [ProviderEndpointOption] {
        regionsByKind[kind] ?? Self.trustedLocalOptions(for: kind, delivered: nil)
    }

    /// The locally hard-coded region table goes through the same trusted-match function: a fallback must never contain a host outside the trusted table.
    /// With no delivered table, only the last two labels of the fallback host are trusted (for example the MiniMax China site `api.minimaxi.com` is not shown then).
    static func trustedLocalOptions(for kind: ProviderKind, delivered: [String]?) -> [ProviderEndpointOption] {
        kind.setupEndpointOptions.filter {
            OfficialTrustedHosts.isTrustedURL("https://\($0.baseURLText)", providerKind: kind, delivered: delivered)
        }
    }

    func defaultSetupEndpointID(for kind: ProviderKind) -> String? {
        setupEndpointOptions(for: kind).first?.id
    }

    func usesConfigurableBaseURL(_ kind: ProviderKind) -> Bool {
        !setupEndpointOptions(for: kind).isEmpty || kind == .relay
    }

    func resolvedSetupBaseURLText(for kind: ProviderKind, optionID: String?) -> String? {
        let normalizedOptionID = optionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedOptionID,
           let matched = setupEndpointOptions(for: kind).first(where: { $0.id == normalizedOptionID }) {
            return matched.baseURLText
        }
        return setupEndpointOptions(for: kind).first?.baseURLText ?? defaultBaseURLText(for: kind)
    }

    func resolvedSetupEndpointOption(for kind: ProviderKind, baseURLText: String?) -> ProviderEndpointOption? {
        Self.resolvedOption(in: setupEndpointOptions(for: kind), baseURLText: baseURLText)
    }

    func officialEndpointMetadata(for kind: ProviderKind) -> OfficialEndpointMetadata? {
        endpointMetadataByKind[kind]
    }

    /// The fields the user must fill in for the selected address template; computed from the placeholders in the template, ignoring `required`.
    func setupFieldIDs(for kind: ProviderKind, optionID: String?) -> [String] {
        guard let template = setupTemplate(for: kind, optionID: optionID)?.template else { return [] }
        return ProviderEndpointTemplate.placeholders(in: template)
            .filter(ProviderSetupFieldDefinition.knownIDs.contains)
    }

    /// What setup submits: the address, the source and the template values. If any placeholder in the template lacks a valid value this is nil (the primary button is unavailable).
    func setupSubmission(
        for kind: ProviderKind,
        optionID: String?,
        values: [String: String]
    ) -> ProviderSetupSubmission? {
        guard let selected = setupTemplate(for: kind, optionID: optionID) else {
            return ProviderSetupSubmission(baseURLText: nil, endpointSource: .default, setupValues: nil)
        }
        let template = selected.template
        let source = selected.source
        let placeholders = ProviderEndpointTemplate.placeholders(in: template)
        guard !placeholders.isEmpty else {
            return ProviderSetupSubmission(baseURLText: template, endpointSource: source, setupValues: nil)
        }
        var stored: [String: String] = [:]
        for name in placeholders {
            guard let value = ProviderEndpointTemplate.normalizedValue(values[name]) else { return nil }
            stored[name] = value
        }
        guard let filled = ProviderEndpointTemplate.filled(template, values: stored) else { return nil }
        return ProviderSetupSubmission(baseURLText: filled, endpointSource: source, setupValues: stored)
    }

    private func setupTemplate(
        for kind: ProviderKind,
        optionID: String?
    ) -> (template: String, source: ProviderEndpointSource)? {
        let options = setupEndpointOptions(for: kind)
        if !options.isEmpty {
            let normalizedOptionID = optionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let option = options.first(where: { $0.id == normalizedOptionID }) ?? options[0]
            return (option.baseURLText, .region(option.id))
        }
        guard let defaultBase = defaultBaseURLText(for: kind) else { return nil }
        return (defaultBase, .default)
    }

    /// For deterministic IDs only: look up by literal match against the frozen identity table alone (the first entry when nothing matches); a provider outside the table returns nil.
    func resolvedIdentityEndpointOption(for kind: ProviderKind, baseURLText: String?) -> ProviderEndpointOption? {
        Self.resolvedOption(in: Self.identityRegions[kind] ?? [], baseURLText: baseURLText)
    }

    /// Region part of a deterministic ID (before SiliconFlow cn is folded): a `region:<id>` source whose id is in the frozen table takes priority,
    /// otherwise a literal lookup; a provider outside the table is always the empty string. It never looks at metadata, so a change in delivered regions cannot derive a new id.
    func identityRegionID(
        for kind: ProviderKind,
        baseURLText: String?,
        endpointSource: ProviderEndpointSource?
    ) -> String {
        if case .region(let id)? = endpointSource,
           Self.identityRegions[kind]?.contains(where: { $0.id == id }) == true {
            return id
        }
        return resolvedIdentityEndpointOption(for: kind, baseURLText: baseURLText)?.id ?? ""
    }

    /// The source is `region:<id>` and that entry is in the displayed (trusted) list -> that entry; otherwise nil and the caller echoes the value literally.
    func sourcedEndpointOption(for kind: ProviderKind, endpointSource: ProviderEndpointSource?) -> ProviderEndpointOption? {
        guard case .region(let id)? = endpointSource else { return nil }
        return setupEndpointOptions(for: kind).first { $0.id == id }
    }

    /// Literal echo: delivered regions do not pass through the trusted table, and the built-in table is used when none is delivered.
    func resolvedLiteralEchoEndpointOption(for kind: ProviderKind, baseURLText: String?) -> ProviderEndpointOption? {
        Self.resolvedOption(in: literalEchoRegionsByKind[kind] ?? kind.setupEndpointOptions, baseURLText: baseURLText)
    }

    /// The frozen identity region table (identical character for character to the fixture's `identityRegions`, pinned by tests). Used only for deterministic IDs; labels are never shown.
    /// Changing it would make stored connections derive a different provider id; adding a provider requires a release.
    static let identityRegions: [ProviderKind: [ProviderEndpointOption]] = [
        .miniMax: [
            ProviderEndpointOption(id: "global", label: "global", baseURLText: "api.minimax.io/v1"),
            ProviderEndpointOption(id: "cn", label: "cn", baseURLText: "api.minimaxi.com/v1"),
        ],
        .qwen: [
            ProviderEndpointOption(id: "sg", label: "sg", baseURLText: "dashscope-intl.aliyuncs.com"),
            ProviderEndpointOption(id: "bj", label: "bj", baseURLText: "dashscope.aliyuncs.com"),
            ProviderEndpointOption(id: "hk", label: "hk", baseURLText: "cn-hongkong.dashscope.aliyuncs.com"),
            ProviderEndpointOption(id: "us", label: "us", baseURLText: "dashscope-us.aliyuncs.com"),
        ],
        .moonshot: [
            ProviderEndpointOption(id: "intl", label: "intl", baseURLText: "api.moonshot.ai/v1"),
            ProviderEndpointOption(id: "cn", label: "cn", baseURLText: "api.moonshot.cn/v1"),
        ],
        .siliconFlow: [
            ProviderEndpointOption(id: "cn", label: "cn", baseURLText: "api.siliconflow.cn/v1"),
            ProviderEndpointOption(id: "intl", label: "intl", baseURLText: "api.siliconflow.com/v1"),
        ],
    ]

    private static func resolvedOption(
        in options: [ProviderEndpointOption],
        baseURLText: String?
    ) -> ProviderEndpointOption? {
        guard !options.isEmpty else { return nil }
        guard let normalized = Self.normalizedBaseURLText(baseURLText) else {
            return options.first
        }
        return options.first(where: {
            normalizedBaseURLText($0.baseURLText) == normalized
        }) ?? options.first
    }

    private static let cachedCurrent =
        OSAllocatedUnfairLock<(generation: UInt64, catalog: ProviderSetupCatalog)?>(initialState: nil)

    static func current(metadata: MetadataClient = .shared) -> ProviderSetupCatalog {
        guard metadata === MetadataClient.shared else {
            return build(from: metadata)
        }
        let generation = MetadataClient.sharedSnapshotGeneration()
        if let cached = cachedCurrent.withLock({ $0 }), cached.generation == generation {
            return cached.catalog
        }
        let catalog = build(from: metadata)
        cachedCurrent.withLock { $0 = (generation, catalog) }
        return catalog
    }

    private static func build(from metadata: MetadataClient) -> ProviderSetupCatalog {
        fromProviderConfigs(
            metadata.syncHasPublicProviderConfigSource()
                ? metadata.syncListPublicProviderConfigs()
                : nil
        )
    }

    static func fromProviderConfigs(_ providerConfigs: [MetadataClient.PublicProviderConfig]?) -> ProviderSetupCatalog {
        guard let providerConfigs else { return fallback }

        let knownConfigs = providerConfigs
            .compactMap(KnownProviderConfig.init)
            .sorted { left, right in
                let leftOrder = left.sortOrder ?? Int.max
                let rightOrder = right.sortOrder ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                let leftIndex = fallbackProviderOrder.firstIndex(of: left.kind) ?? Int.max
                let rightIndex = fallbackProviderOrder.firstIndex(of: right.kind) ?? Int.max
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return left.kind.rawValue < right.kind.rawValue
            }

        var defaults = fallbackDefaults
        var regions = fallbackRegions
        var literalEchoRegions = literalEchoFallbackRegions
        var endpointMetadata: [ProviderKind: OfficialEndpointMetadata] = [:]
        var direct: [ProviderKind] = []
        var aggregators: [ProviderKind] = []

        for config in knownConfigs {
            defaults[config.kind] = ProviderSetupDefaults(
                displayName: config.selectionLabel ?? config.displayName,
                shortName: config.shortName ?? config.displayName,
                apiKeyPlaceholder: config.apiKeyPlaceholder ?? config.kind.apiKeyPlaceholder,
                defaultBaseURLText: config.defaultBaseURLText,
                autoFillNote: config.autoFillNote
            )
            // When the server returns an empty array (or every entry is filtered out by the trusted-host
            // table), fall back to the local regions, filtered by the trusted hosts delivered for this provider.
            if !config.untrustedRegionOptions.isEmpty {
                literalEchoRegions[config.kind] = config.untrustedRegionOptions
            }
            if !config.regionOptions.isEmpty {
                regions[config.kind] = config.regionOptions
            } else {
                regions[config.kind] = trustedLocalOptions(for: config.kind, delivered: config.trustedHosts)
            }
            endpointMetadata[config.kind] = config.endpointMetadata
            if config.category == "aggregator" {
                aggregators.append(config.kind)
            } else {
                direct.append(config.kind)
            }
        }

        return ProviderSetupCatalog(
            directProviders: direct,
            aggregatorProviders: aggregators,
            defaultsByKind: defaults,
            regionsByKind: regions,
            literalEchoRegionsByKind: literalEchoRegions,
            endpointMetadataByKind: endpointMetadata
        )
    }

    static let fallback = ProviderSetupCatalog(
        directProviders: ProviderKind.directProviders,
        aggregatorProviders: ProviderKind.aggregatorProviders,
        defaultsByKind: fallbackDefaults,
        regionsByKind: fallbackRegions,
        literalEchoRegionsByKind: literalEchoFallbackRegions
    )

    private static let fallbackProviderOrder: [ProviderKind] = [
        .openAI,
        .anthropic,
        .gemini,
        .openRouter,
        .deepseek,
        .grok,
        .moonshot,
        .mistral,
        .siliconFlow,
        .groq,
        .together,
        .fireworks,
        .miniMax,
        .zhipu,
        .qwen,
    ]

    private static let fallbackDefaults: [ProviderKind: ProviderSetupDefaults] =
        Dictionary(uniqueKeysWithValues: fallbackProviderOrder.map { kind in
            (
                kind,
                ProviderSetupDefaults(
                    displayName: kind.displayName,
                    shortName: kind.shortName,
                    apiKeyPlaceholder: kind.apiKeyPlaceholder,
                    defaultBaseURLText: kind.defaultBaseURLText,
                    autoFillNote: kind.autoFillNote
                )
            )
        })

    private static let fallbackRegions: [ProviderKind: [ProviderEndpointOption]] =
        Dictionary(uniqueKeysWithValues: fallbackProviderOrder.map { ($0, trustedLocalOptions(for: $0, delivered: nil)) })

    private static let literalEchoFallbackRegions: [ProviderKind: [ProviderEndpointOption]] =
        Dictionary(uniqueKeysWithValues: fallbackProviderOrder.map { ($0, $0.setupEndpointOptions) })

    private static func normalizedBaseURLText(_ baseURLText: String?) -> String? {
        guard var normalized = baseURLText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

private struct KnownProviderConfig {
    let kind: ProviderKind
    let displayName: String
    let shortName: String?
    let selectionLabel: String?
    let autoFillNote: String?
    let defaultBaseURLText: String?
    let apiKeyPlaceholder: String?
    let category: String?
    let regionOptions: [ProviderEndpointOption]
    /// Delivered regions that did not pass the trusted table; used only for the detail page's literal echo.
    let untrustedRegionOptions: [ProviderEndpointOption]
    let trustedHosts: [String]?
    let sortOrder: Int?
    /// For the on-demand calculation: the delivered, trusted default address and regions (including well-formed templates).
    let endpointMetadata: OfficialEndpointMetadata

    nonisolated init?(_ config: MetadataClient.PublicProviderConfig) {
        guard let kind = Self.kind(from: config.kind) else { return nil }
        self.kind = kind
        displayName = config.displayName.trimmedNonEmpty ?? kind.displayName
        shortName = config.shortName?.trimmedNonEmpty
        selectionLabel = config.selectionLabel?.trimmedNonEmpty
        autoFillNote = config.autoFillNote?.trimmedNonEmpty
        apiKeyPlaceholder = config.apiKeyPlaceholder?.trimmedNonEmpty
        category = (config.category == "direct" || config.category == "aggregator") ? config.category : nil
        // Region options go through the same trusted table as the official base URL: options outside the table are not shown.
        let trustedHosts = config.trustedHosts?.hosts
        self.trustedHosts = trustedHosts
        // Template placeholders: only ids from the closed set that are also declared in setupFields are accepted, otherwise the whole entry is dropped;
        // the trusted-table check uses the address with every placeholder replaced by `a`.
        let declaredFields = Set(config.setupFields?.fields.map(\.id) ?? [])
        let decoded: [(raw: String, option: ProviderEndpointOption)] = (config.regionOptions ?? []).compactMap { option in
            guard let id = option.id.trimmedNonEmpty,
                  let label = option.label.trimmedNonEmpty,
                  let baseURLText = Self.normalizedBaseURLText(option.baseURL),
                  Self.placeholdersAllowed(option.baseURL, declared: declaredFields) else {
                return nil
            }
            return (
                ProviderEndpointTemplate.trustProbe(option.baseURL),
                ProviderEndpointOption(id: id, label: label, baseURLText: baseURLText)
            )
        }
        untrustedRegionOptions = decoded.map(\.option)
        regionOptions = decoded.filter {
            OfficialTrustedHosts.isTrustedURL($0.raw, providerKind: kind, delivered: trustedHosts)
        }.map(\.option)
        sortOrder = config.sortOrder
        let trustedDefault: String?
        if Self.placeholdersAllowed(config.defaultBaseURL, declared: declaredFields),
           OfficialTrustedHosts.isTrustedURL(
               ProviderEndpointTemplate.trustProbe(config.defaultBaseURL),
               providerKind: kind,
               delivered: trustedHosts
           ) {
            trustedDefault = Self.normalizedBaseURLText(config.defaultBaseURL)
        } else {
            trustedDefault = nil
        }
        // An address with placeholders is treated like a region entry: if it is malformed or not in the trusted table it counts as missing and the built-in fallback is used;
        // an address without placeholders stays as is (EndpointResolver has its own trusted-table gate at request time).
        defaultBaseURLText = ProviderEndpointTemplate.placeholders(in: config.defaultBaseURL).isEmpty
            ? Self.normalizedBaseURLText(config.defaultBaseURL)
            : trustedDefault
        endpointMetadata = OfficialEndpointMetadata(
            defaultBaseURLText: trustedDefault,
            regions: regionOptions.map { .init(id: $0.id, baseURLText: $0.baseURLText) }
        )
    }

    nonisolated private static func placeholdersAllowed(_ raw: String, declared: Set<String>) -> Bool {
        ProviderEndpointTemplate.placeholders(in: raw).allSatisfy {
            ProviderSetupFieldDefinition.knownIDs.contains($0) && declared.contains($0)
        }
    }

    private static func kind(from raw: String) -> ProviderKind? {
        switch raw {
        case "openAI": return .openAI
        case "anthropic": return .anthropic
        case "gemini": return .gemini
        case "deepseek": return .deepseek
        case "grok": return .grok
        case "openRouter": return .openRouter
        case "groq": return .groq
        case "togetherAI": return .together
        case "fireworksAI": return .fireworks
        case "miniMax": return .miniMax
        case "zhipu": return .zhipu
        case "qwen": return .qwen
        case "moonshot": return .moonshot
        case "mistral": return .mistral
        case "siliconFlow": return .siliconFlow
        default: return nil
        }
    }

    private static func normalizedBaseURLText(_ raw: String) -> String? {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How official providers edit regions: the trusted table constrains only the options that can be selected, not the value the user already stored.
/// - Current region: a `region:<id>` source whose entry is in the displayed list takes priority, otherwise a literal lookup in the unfiltered delivered table;
/// - A current entry that is not among the filtered options is still listed but cannot be newly selected;
/// - Opening the editor and saving without changes leaves the address unchanged character for character.
enum ProviderEndpointEditPolicy {
    static func currentOption(
        catalog: ProviderSetupCatalog,
        kind: ProviderKind,
        baseURLText: String?,
        endpointSource: ProviderEndpointSource? = nil
    ) -> ProviderEndpointOption? {
        catalog.sourcedEndpointOption(for: kind, endpointSource: endpointSource)
            ?? catalog.resolvedLiteralEchoEndpointOption(for: kind, baseURLText: baseURLText)
    }

    /// The entries the picker shows, and those among them that are read-only (cannot be newly selected).
    static func pickerOptions(
        catalog: ProviderSetupCatalog,
        kind: ProviderKind,
        current: ProviderEndpointOption?,
        includesTemplates: Bool = false
    ) -> (options: [ProviderEndpointOption], lockedIDs: Set<String>) {
        // Template entries with placeholders: both setup and the detail page pass true (the detail page goes through `detailPickerOptions`).
        let selectable = catalog.setupEndpointOptions(for: kind).filter {
            includesTemplates || ProviderEndpointTemplate.placeholders(in: $0.baseURLText).isEmpty
        }
        guard let current, !selectable.contains(where: { $0.id == current.id }) else {
            return (selectable, [])
        }
        return (selectable + [current], [current.id])
    }

    /// Detail page picker: a provider with setupFields also lists template entries with placeholders.
    static func detailPickerOptions(
        catalog: ProviderSetupCatalog,
        kind: ProviderKind,
        current: ProviderEndpointOption?
    ) -> (options: [ProviderEndpointOption], lockedIDs: Set<String>) {
        // A template entry is kept at decode time only when its placeholders are declared in setupFields, so "list template entries" = the provider has setupFields.
        pickerOptions(catalog: catalog, kind: kind, current: current, includesTemplates: true)
    }

    /// What the detail page writes on save. nil = a template entry with placeholders is selected but its values are invalid (save is unavailable).
    enum DetailSave: Equatable {
        /// Only the address changes; the source is reclassified by `updateBaseURL` (same as today).
        case baseURL(String?)
        /// Template entry: the address, the `region:<id>` source and the template values are written together.
        case setup(ProviderSetupSubmission)
    }

    static func detailSave(
        catalog: ProviderSetupCatalog,
        kind: ProviderKind,
        selectedOptionID: String,
        current: ProviderEndpointOption?,
        storedBaseURLText: String?,
        values: [String: String]
    ) -> DetailSave? {
        let isCurrent = current?.id == selectedOptionID
        guard !isCurrent, !catalog.setupFieldIDs(for: kind, optionID: selectedOptionID).isEmpty else {
            return .baseURL(baseURLTextToSave(
                catalog: catalog, kind: kind, selectedOptionID: selectedOptionID,
                current: current, storedBaseURLText: storedBaseURLText
            ))
        }
        // The same submit function as the setup page: invalid values return nil.
        return catalog.setupSubmission(for: kind, optionID: selectedOptionID, values: values).map(DetailSave.setup)
    }

    /// The address written back on save: if the selection is still the current entry the stored value is written back unchanged, and only choosing another entry takes that entry's address.
    static func baseURLTextToSave(
        catalog: ProviderSetupCatalog,
        kind: ProviderKind,
        selectedOptionID: String,
        current: ProviderEndpointOption?,
        storedBaseURLText: String?
    ) -> String? {
        if let current, current.id == selectedOptionID { return storedBaseURLText }
        return catalog.resolvedSetupBaseURLText(for: kind, optionID: selectedOptionID)
    }
}
