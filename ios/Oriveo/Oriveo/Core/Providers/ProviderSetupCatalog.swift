import Foundation
import os

struct ProviderSetupDefaults: Sendable, Equatable {
    let displayName: String
    let shortName: String
    let apiKeyPlaceholder: String
    let defaultBaseURLText: String?
    let autoFillNote: String?
}

struct ProviderSetupCatalog: Sendable, Equatable {
    let directProviders: [ProviderKind]
    let aggregatorProviders: [ProviderKind]
    private let defaultsByKind: [ProviderKind: ProviderSetupDefaults]
    private let regionsByKind: [ProviderKind: [ProviderEndpointOption]]

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
        regionsByKind[kind] ?? kind.setupEndpointOptions
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
        let options = setupEndpointOptions(for: kind)
        guard !options.isEmpty else { return nil }
        guard let normalized = Self.normalizedBaseURLText(baseURLText) else {
            return options.first
        }
        return options.first(where: {
            Self.normalizedBaseURLText($0.baseURLText) == normalized
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
            if !config.regionOptions.isEmpty {
                regions[config.kind] = config.regionOptions
            }
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
            regionsByKind: regions
        )
    }

    static let fallback = ProviderSetupCatalog(
        directProviders: ProviderKind.directProviders,
        aggregatorProviders: ProviderKind.aggregatorProviders,
        defaultsByKind: fallbackDefaults,
        regionsByKind: fallbackRegions
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
    let sortOrder: Int?

    nonisolated init?(_ config: MetadataClient.PublicProviderConfig) {
        guard let kind = Self.kind(from: config.kind) else { return nil }
        self.kind = kind
        displayName = config.displayName.trimmedNonEmpty ?? kind.displayName
        shortName = config.shortName?.trimmedNonEmpty
        selectionLabel = config.selectionLabel?.trimmedNonEmpty
        autoFillNote = config.autoFillNote?.trimmedNonEmpty
        defaultBaseURLText = Self.normalizedBaseURLText(config.defaultBaseURL)
        apiKeyPlaceholder = config.apiKeyPlaceholder?.trimmedNonEmpty
        category = (config.category == "direct" || config.category == "aggregator") ? config.category : nil
        regionOptions = (config.regionOptions ?? []).compactMap { option in
            guard let id = option.id.trimmedNonEmpty,
                  let label = option.label.trimmedNonEmpty,
                  let baseURLText = Self.normalizedBaseURLText(option.baseURL) else {
                return nil
            }
            return ProviderEndpointOption(id: id, label: label, baseURLText: baseURLText)
        }
        sortOrder = config.sortOrder
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
