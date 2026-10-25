import Foundation

enum ProviderKind: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini
    case openRouter
    case deepseek
    case grok
    case groq
    case together
    case fireworks
    case miniMax
    case zhipu
    case qwen
    case moonshot
    case mistral
    case siliconFlow
    case relay

    var id: Self { self }

    nonisolated var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .openRouter:
            return "OpenRouter"
        case .deepseek:
            return "DeepSeek"
        case .grok:
            return "Grok"
        case .groq:
            return "Groq"
        case .together:
            return "Together AI"
        case .fireworks:
            return "Fireworks AI"
        case .miniMax:
            return "MiniMax"
        case .zhipu:
            return "Z.ai"
        case .qwen:
            return "Qwen"
        case .moonshot:
            return "Kimi"
        case .mistral:
            return "Mistral"
        case .siliconFlow:
            return "SiliconFlow"
        case .relay:
            return "Relay"
        }
    }

    var menuSystemImage: String {
        switch self {
        case .openAI: return "brain"
        case .anthropic: return "sparkles"
        case .gemini: return "diamond"
        case .openRouter: return "arrow.triangle.swap"
        case .deepseek: return "brain"
        case .grok: return "sparkles"
        case .groq: return "bolt"
        case .together: return "link"
        case .fireworks: return "flame"
        case .miniMax: return "cpu"
        case .zhipu: return "cpu"
        case .qwen: return "cpu"
        case .moonshot: return "moon"
        case .mistral: return "wind"
        case .siliconFlow: return "sparkles.rectangle.stack"
        case .relay: return "arrow.left.arrow.right"
        }
    }

    nonisolated var shortName: String {
        switch self {
        case .anthropic:
            return "Claude"
        case .relay:
            return "Relay"
        default:
            return displayName
        }
    }

    static var directProviders: [ProviderKind] {
        [.openAI, .anthropic, .gemini, .deepseek, .grok, .miniMax, .zhipu, .qwen, .moonshot, .mistral]
    }

    static var aggregatorProviders: [ProviderKind] {
        [.openRouter, .groq, .together, .fireworks, .siliconFlow]
    }

    static func inferred(fromAPIKey apiKey: String) -> ProviderKind? {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("sk-ant-") { return .anthropic }
        if normalized.hasPrefix("sk-or-") { return .openRouter }
        if normalized.hasPrefix("xai-") { return .grok }
        if normalized.hasPrefix("gsk_") { return .groq }
        if normalized.hasPrefix("fw_") { return .fireworks }
        if normalized.hasPrefix("aiza") { return .gemini }
        if normalized.hasPrefix("sk-api-") { return .miniMax }
        if normalized.hasPrefix("eyjh") { return .miniMax }

        return nil
    }

    var isThirdPartyAggregator: Bool {
        switch self {
        case .groq, .together, .fireworks:
            return true
        case .relay:
            return false
        default:
            return false
        }
    }

    var isProviderSetupAggregator: Bool {
        Self.aggregatorProviders.contains(self)
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openAI:
            return "sk-..."
        case .anthropic:
            return "sk-ant-..."
        case .gemini:
            return "AIza..."
        case .openRouter:
            return "sk-or-..."
        case .deepseek:
            return "sk-..."
        case .grok:
            return "xai-..."
        case .groq:
            return "gsk_..."
        case .together:
            return ""
        case .fireworks:
            return "fw_..."
        case .miniMax:
            return "sk-api-..."
        case .zhipu:
            return "sk-xxxxxxxx..."
        case .qwen:
            return "sk-xxxxxxxxxxxxxxxx"
        case .moonshot:
            return "sk-..."
        case .mistral:
            return "..."
        case .siliconFlow:
            return "sk-..."
        case .relay:
            return "sk-..."
        }
    }

    var autoFillNote: String? {
        switch self {
        case .relay:
            return nil
        default:
            return L10n.tr("The service endpoint is auto-filled for you.", table: .providers)
        }
    }

    var defaultBaseURLText: String? {
        switch self {
        case .openAI:
            return "api.openai.com/v1"
        case .anthropic:
            return "api.anthropic.com"
        case .gemini:
            return "generativelanguage.googleapis.com"
        case .openRouter:
            return "openrouter.ai/api/v1"
        case .deepseek:
            return "api.deepseek.com/v1"
        case .grok:
            return "api.x.ai/v1"
        case .groq:
            return "api.groq.com/openai/v1"
        case .together:
            return "api.together.xyz/v1"
        case .fireworks:
            return "api.fireworks.ai/inference/v1"
        case .miniMax:
            return "api.minimax.io/v1"
        case .zhipu:
            return "open.bigmodel.cn/api/paas/v4"
        case .qwen:
            // DashScope origin (without /compatible-mode/v1): chat is composed by QwenService.composeCompatibleChatURL
            // as <origin>/compatible-mode/v1/chat/completions, image generation uses the native
            // <origin>/api/v1/services/aigc/multimodal-generation/generation, and key validation appends the
            // metadata validation probePath to the base URL that EndpointResolver.resolveBaseURL returns.
            return "dashscope-intl.aliyuncs.com"
        case .moonshot:
            return "api.moonshot.ai/v1"
        case .mistral:
            return "api.mistral.ai/v1"
        case .siliconFlow:
            return "api.siliconflow.cn/v1"
        case .relay:
            return nil
        }
    }

    /// Retired regions: stored records are migrated to the replacement region at launch backfill and at request time.
    var retiredEndpointRegions: [RetiredEndpointRegion] {
        switch self {
        case .qwen:
            return [RetiredEndpointRegion(
                regionID: "us",
                host: "dashscope-us.aliyuncs.com",
                replacementID: "sg",
                builtInReplacementBaseURLText: "dashscope-intl.aliyuncs.com"
            )]
        default:
            return []
        }
    }

    var setupEndpointOptions: [ProviderEndpointOption] {
        switch self {
        case .miniMax:
            return [
                ProviderEndpointOption(
                    id: "global",
                    label: L10n.tr("Global (api.minimax.io)", table: .providers),
                    baseURLText: "api.minimax.io/v1"
                ),
                ProviderEndpointOption(
                    id: "cn",
                    label: L10n.tr("China Mainland (api.minimaxi.com)", table: .providers),
                    baseURLText: "api.minimaxi.com/v1"
                ),
            ]
        case .qwen:
            // DashScope origin (no /compatible-mode/v1); each request entry composes its own path (see the qwen note in `defaultBaseURLText`).
            return [
                ProviderEndpointOption(
                    id: "sg",
                    label: L10n.tr("Singapore (International)", table: .providers),
                    baseURLText: "dashscope-intl.aliyuncs.com"
                ),
                ProviderEndpointOption(
                    id: "bj",
                    label: L10n.tr("Beijing (China Mainland)", table: .providers),
                    baseURLText: "dashscope.aliyuncs.com"
                ),
                ProviderEndpointOption(
                    id: "hk",
                    label: L10n.tr("Hong Kong", table: .providers),
                    baseURLText: "cn-hongkong.dashscope.aliyuncs.com"
                ),
                // us (Virginia) is retired: it is no longer selectable; the frozen identity table still keeps it, and stored records are migrated to sg lazily.
            ]
        case .moonshot:
            return [
                ProviderEndpointOption(
                    id: "intl",
                    label: L10n.tr("International (api.moonshot.ai)", table: .providers),
                    baseURLText: "api.moonshot.ai/v1"
                ),
                ProviderEndpointOption(
                    id: "cn",
                    label: L10n.tr("China Mainland (api.moonshot.cn)", table: .providers),
                    baseURLText: "api.moonshot.cn/v1"
                ),
            ]
        case .siliconFlow:
            return [
                ProviderEndpointOption(
                    id: "cn",
                    label: L10n.tr("China Mainland (api.siliconflow.cn)", table: .providers),
                    baseURLText: "api.siliconflow.cn/v1"
                ),
                ProviderEndpointOption(
                    id: "intl",
                    label: L10n.tr("International (api.siliconflow.com)", table: .providers),
                    baseURLText: "api.siliconflow.com/v1"
                ),
            ]
        default:
            return []
        }
    }

    func localizedSetupEndpointLabel(for option: ProviderEndpointOption) -> String {
        switch self {
        case .miniMax:
            switch option.id {
            case "global": return L10n.tr("Global (api.minimax.io)", table: .providers)
            case "cn": return L10n.tr("China Mainland (api.minimaxi.com)", table: .providers)
            default: return option.label
            }
        case .qwen:
            switch option.id {
            case "sg": return L10n.tr("Singapore (International)", table: .providers)
            case "bj": return L10n.tr("Beijing (China Mainland)", table: .providers)
            case "hk": return L10n.tr("Hong Kong", table: .providers)
            case "us": return L10n.tr("Virginia (US)", table: .providers)
            default: return option.label
            }
        case .moonshot:
            switch option.id {
            case "intl": return L10n.tr("International (api.moonshot.ai)", table: .providers)
            case "cn": return L10n.tr("China Mainland (api.moonshot.cn)", table: .providers)
            default: return option.label
            }
        case .siliconFlow:
            switch option.id {
            case "cn": return L10n.tr("China Mainland (api.siliconflow.cn)", table: .providers)
            case "intl": return L10n.tr("International (api.siliconflow.com)", table: .providers)
            default: return option.label
            }
        default:
            return option.label
        }
    }

    var defaultSetupEndpointID: String? {
        setupEndpointOptions.first?.id
    }

    var setupEndpointTitle: String {
        L10n.tr("Official Endpoint", table: .providers)
    }

    func resolvedSetupBaseURLText(for optionID: String?) -> String? {
        let normalizedOptionID = optionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedOptionID,
           let matched = setupEndpointOptions.first(where: { $0.id == normalizedOptionID }) {
            return matched.baseURLText
        }
        return setupEndpointOptions.first?.baseURLText ?? defaultBaseURLText
    }

    func resolvedSetupEndpointOption(for baseURLText: String?) -> ProviderEndpointOption? {
        guard !setupEndpointOptions.isEmpty else { return nil }
        guard let normalizedBaseURLText = Self.normalizedSetupBaseURLText(baseURLText) else {
            return setupEndpointOptions.first
        }
        return setupEndpointOptions.first(where: {
            Self.normalizedSetupBaseURLText($0.baseURLText) == normalizedBaseURLText
        }) ?? setupEndpointOptions.first
    }

    var setupEndpointFootnote: String? {
        switch self {
        case .miniMax:
            return L10n.tr("MiniMax offers multiple official endpoints. Choose the one that matches your account region.", table: .providers)
        case .qwen:
            return L10n.tr("Qwen API keys are region-locked. Select the region matching your API key.", table: .providers)
        case .moonshot:
            return L10n.tr("Kimi has separate international and China Mainland endpoints. Choose the endpoint that matches your API key.", table: .providers)
        case .siliconFlow:
            return L10n.tr("SiliconFlow API keys are region-specific. Choose the endpoint that matches your account.", table: .providers)
        default:
            return nil
        }
    }

    var isAggregatedProvider: Bool {
        switch self {
        case .relay:
            return false
        default:
            return true
        }
    }

    var usesServerOrderedModels: Bool {
        switch self {
        default:
            return false
        }
    }

    private static func normalizedSetupBaseURLText(_ baseURLText: String?) -> String? {
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

        if normalized.hasSuffix("/compatible-mode/v1") {
            normalized.removeLast("/compatible-mode/v1".count)
        }

        return normalized
    }

    var requiresVendorDisclosure: Bool {
        self == .relay || privacyPolicyURL != nil
    }

    var privacyPolicyURL: URL? {
        switch self {
        case .openAI:
            return URL(string: "https://openai.com/policies/row-privacy-policy/")
        case .anthropic:
            return URL(string: "https://www.anthropic.com/legal/privacy")
        case .gemini:
            return URL(string: "https://policies.google.com/privacy")
        case .openRouter:
            return URL(string: "https://openrouter.ai/privacy")
        case .deepseek:
            return URL(string: "https://www.deepseek.com/privacy")
        case .grok:
            return URL(string: "https://x.ai/legal/privacy-policy")
        case .groq:
            return URL(string: "https://groq.com/privacy-policy/")
        case .together:
            return URL(string: "https://www.together.ai/privacy")
        case .fireworks:
            return URL(string: "https://fireworks.ai/privacy-policy")
        case .miniMax:
            return URL(string: "https://www.minimax.io/privacy-policy")
        case .zhipu:
            return URL(string: "https://z.ai/legal/privacy")
        case .qwen:
            return URL(string: "https://www.alibabacloud.com/help/en/legal/latest/alibaba-cloud-international-website-privacy-policy")
        case .moonshot:
            return URL(string: "https://platform.kimi.ai/docs")
        case .mistral:
            return URL(string: "https://mistral.ai/terms#privacy-policy")
        case .siliconFlow:
            return URL(string: "https://siliconflow.com/privacy-policy")
        case .relay:
            return nil
        }
    }

    /// Whether the provider exposes a model list we can fetch automatically.
    var supportsModelCatalogSync: Bool {
        switch self {
        case .relay:
            return false
        default:
            return true
        }
    }

    /// Whether the endpoint may be chosen and later changed. This is derived from the region list
    /// the setup screen actually renders, so the picker and the write path cannot disagree: a
    /// hard-coded list of kinds here once let a provider offer a region choice that nothing saved.
    var usesConfigurableBaseURL: Bool {
        self == .relay || !setupEndpointOptions.isEmpty
    }

    var attachmentSupport: (image: Bool, video: Bool, nativeFile: Bool, textFileInline: Bool) {
        guard let support = MetadataClient.shared.syncProviderAttachmentSupport(providerKind: self) else {
            return (image: false, video: false, nativeFile: false, textFileInline: false)
        }
        return (
            image: support.image,
            video: support.video,
            nativeFile: support.nativeFile,
            textFileInline: support.textFileInline
        )
    }
}

struct ProviderEndpointOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let baseURLText: String
}

enum ProviderConnectionState: Hashable, Codable {
    case connected
    case syncing
    case issue(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case message
    }

    private enum Kind: String, Codable {
        case connected
        case syncing
        case issue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .connected:
            self = .connected
        case .syncing:
            self = .syncing
        case .issue:
            self = .issue(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected:
            try container.encode(Kind.connected, forKey: .kind)
        case .syncing:
            try container.encode(Kind.syncing, forKey: .kind)
        case let .issue(message):
            try container.encode(Kind.issue, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }

    var title: String {
        switch self {
        case .connected:
            return L10n.tr("Connected", table: .providers)
        case .syncing:
            return L10n.tr("Syncing", table: .providers)
        case .issue:
            return L10n.tr("Issue", table: .providers)
        }
    }
}

enum ModelCapability: String, CaseIterable, Hashable, Identifiable, Codable {
    case reasoning
    case text
    case image
    case video
    case file
    case web
    case imageGen = "imageGeneration"
    case nativePdf = "native_pdf"
    case toolCall

    var id: Self { self }

    var title: String {
        switch self {
        case .reasoning:
            return L10n.tr("Reasoning", table: .providers)
        case .text:
            return L10n.tr("Text", table: .providers)
        case .image:
            return L10n.tr("Image")
        case .video:
            return L10n.tr("Video")
        case .file:
            // The capability badge uses its own plural key; the attachment menu's "File" is unaffected.
            return L10n.tr("Files", table: .providers)
        case .web:
            return L10n.tr("Web", table: .providers)
        case .imageGen:
            return L10n.tr("Image Gen", table: .providers)
        case .nativePdf:
            return "Native PDF"
        case .toolCall:
            return L10n.tr("Tools", table: .providers)
        }
    }

    var systemImage: String {
        switch self {
        case .reasoning:
            return "brain"
        case .text:
            return "text.alignleft"
        case .image:
            return "photo"
        case .video:
            return "video"
        case .file:
            return "doc"
        case .web:
            return "globe"
        case .imageGen:
            return "paintbrush"
        case .nativePdf:
            return "doc.text"
        case .toolCall:
            return "wrench.and.screwdriver"
        }
    }
}

enum ReasoningMode: String, CaseIterable, Hashable, Identifiable, Codable {
    case automatic
    case fast
    case balanced
    case deep
    case max

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic:
            return L10n.tr("Auto")
        case .fast:
            return L10n.tr("Fast", table: .providers)
        case .balanced:
            return L10n.tr("Balanced")
        case .deep:
            return L10n.tr("Deep", table: .providers)
        case .max:
            return L10n.tr("Max", table: .providers)
        }
    }

    var intentToken: String? {
        switch self {
        case .automatic: return nil
        case .fast: return "low"
        case .balanced: return "balanced"
        case .deep: return "deep"
        case .max: return "max"
        }
    }

    static func fromIntent(_ intent: String?) -> ReasoningMode? {
        guard let token = intent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        if token == "low" { return .fast }
        guard let mode = ReasoningMode(rawValue: token), mode != .automatic else { return nil }
        return mode
    }
}

struct ChatCapabilityOutboundDecision: Equatable, Sendable {
    let webSearchEnabled: Bool
    let reasoningMode: ReasoningMode
    let reasoningIntent: String?

    static func resolve(
        webRequested: Bool,
        webPermitted: Bool,
        reasoningModeRequested: ReasoningMode,
        reasoningModePermitted: Bool,
        reasoningIntentRequested: String?,
        reasoningIntentPermitted: Bool
    ) -> ChatCapabilityOutboundDecision {
        let intent = reasoningIntentPermitted ? reasoningIntentRequested : nil
        return .init(
            webSearchEnabled: webRequested && webPermitted,
            reasoningMode: reasoningModePermitted ? reasoningModeRequested : .automatic,
            reasoningIntent: intent
        )
    }

    var activeCapabilityGlyphs: [String] {
        var glyphs: [String] = []
        if webSearchEnabled { glyphs.append("globe") }
        if reasoningIntent != nil || reasoningMode != .automatic { glyphs.append("brain") }
        return glyphs
    }

    var hasActiveCapabilitySelection: Bool { !activeCapabilityGlyphs.isEmpty }
}

struct ChatCapabilitySelection: Hashable, Codable, Sendable {
    var reasoningMode: ReasoningMode
    var webSearchEnabled: Bool
    var libraryResearchEnabled: Bool
    /// Process-local typed intent. Compatibility fields above serve legacy providers only.
    var typedPreferences: CapabilityPreferenceValues?

    nonisolated init() {
        reasoningMode = .automatic
        // Fresh conversations must omit web intent by default. Existing enabled
        // values migrate through GenerationParameterSettingsStore as `.automatic`.
        webSearchEnabled = false
        libraryResearchEnabled = false
        typedPreferences = nil
    }

    nonisolated init(
        reasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        libraryResearchEnabled: Bool = false
    ) {
        self.reasoningMode = reasoningMode
        self.webSearchEnabled = webSearchEnabled
        self.libraryResearchEnabled = libraryResearchEnabled
        typedPreferences = nil
    }

    private enum CodingKeys: String, CodingKey { case reasoningMode, webSearchEnabled, libraryResearchEnabled }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reasoningMode = try values.decodeIfPresent(ReasoningMode.self, forKey: .reasoningMode) ?? .automatic
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
        libraryResearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .libraryResearchEnabled) ?? false
        typedPreferences = nil
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reasoningMode, forKey: .reasoningMode)
        try values.encode(webSearchEnabled, forKey: .webSearchEnabled)
        try values.encode(libraryResearchEnabled, forKey: .libraryResearchEnabled)
    }

    var hasCustomReasoning: Bool {
        reasoningMode != .automatic
    }
}

struct AttachmentExtractionLimits: Codable, Equatable, Hashable, Sendable {
    var maxLines: Int?
    var maxBytes: Int?
    /// Total cap on text injected into the body after file extraction (UTF-8 bytes).
    var totalCap: Int?
    var maxInputFileBytes: Int?
    var maxAttachments: Int?
    var maxRequestAttachmentBytes: Int? = nil
}

struct GenerationProfileRef: Codable, Equatable, Hashable, Sendable {
    var template: String?
    var parameters: [GenerationParameterRef]?
    var parametersRef: String? = nil
    var wire: [String: String]?
    var transport: String?
    var revision: String? = nil
}

struct GenerationParameterRef: Codable, Equatable, Hashable, Sendable {
    var id: String?
    var support: String?
    var source: String?
    var group: String?
    var valueSchema: String?
    var range: GenerationParameterRange?
    var enumValues: [GenerationParameterValue]?
    var fixedValue: GenerationParameterValue?
    var defaultDescription: GenerationParameterValue?
    var interactionGroup: String?
    var conflictsWith: [String]?
    var requires: [[String: GenerationParameterValue]]?
    var constraints: [[String: GenerationParameterValue]]?
    var portability: String?
    var risk: String?
    /// Model-level write path (shared contract #modelLevelFacts.fields.wire). Present only on the
    /// delivered model reference; resolving replaces the template path with it, and a resolved
    /// profile keeps every path in `GenerationProfileRef.wire`.
    var wire: String? = nil
    /// Appears on `json_schema` only: `true` writes `strict: true` into the structured-output
    /// object, and a missing value leaves the key out.
    var strict: Bool? = nil
}

struct GenerationParameterRange: Codable, Equatable, Hashable, Sendable {
    var min: Double?
    var max: Double?
    var minExclusive: Double?
    var maxExclusive: Double?
    var step: Double?
}

/// Per-model capability declaration issued by the catalog. Each item is tri-state: true / false = the catalog says so, nil = the catalog has no such key.
struct CatalogCapabilityTruth: Hashable, Sendable {
    var visionInput: Bool?
    var webSearch: Bool?
    /// Whether the model shows its thinking process (`capabilityFlags.reasoning` in the catalog). Nil = the catalog has no explicit object, fall back to the legacy array.
    var reasoning: Bool? = nil
}

struct AIModel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var capabilities: [ModelCapability]
    var reasoningModeAvailable: Bool
    var isAvailable: Bool
    var isDefault: Bool
    var priceTier: String
    var summary: String?
    var contextLength: Int? = nil
    var maxOutputTokens: Int? = nil
    var groupKey: String?
    var groupName: String?
    var createdAt: TimeInterval? = nil
    var promptPrice: Double? = nil
    var completionPrice: Double? = nil
    /// Currency of the unit prices (nil = USD): only filled at display time by `CatalogModelBuilder.connectionPriced`
    /// from the price the connection selected. Not in `CodingKeys` and not filled on the persistence path: it follows
    /// the connection's effective region and the catalog, so the price is selected again on every display.
    var priceCurrencyCode: String? = nil
    var billingSku: String? = nil
    var pricingUnit: String = "per_token"
    var sourceSummary: ModelSourceSummary? = nil
    var costPerUnit: Double? = nil
    var costInputBatches: Double? = nil
    var costOutputBatches: Double? = nil
    var costInputPriority: Double? = nil
    var costOutputPriority: Double? = nil
    var cacheReadInputPerMToken: Double? = nil
    var cacheCreationInputPerMToken: Double? = nil
    var cacheWrite5mPerMToken: Double? = nil
    var cacheWrite1hPerMToken: Double? = nil
    var supportsPdfInput: Bool = false
    var supportsServiceTier: Bool = false
    var canonicalModelId: String? = nil
    var isRecommended: Bool? = nil
    var sortRank: Int? = nil
    var badgeOrder: [ModelCapability]? = nil
    var reasoningProfile: String? = nil
    var webSearchProfile: String? = nil
    var imageGenProfile: String? = nil
    var generationProfile: GenerationProfileRef? = nil
    var capabilityEvidenceCandidates: [CapabilityEvidenceFacade.Candidate] = []
    var capabilityEvidenceOwnedKeys: Set<String> = []
    var capabilityEvidenceViewPresent: Bool = false
    var capabilityEvidenceViewMalformed: Bool = false
    var toolCall: Bool? = nil
    var libraryAgentic: Bool? = nil
    var upstreamReasoningLevels: [String] = []
    /// The input media the upstream declares per model (the `input_modalities` of a Codex subscription `/models`, verbatim).
    /// **nil = the upstream declared nothing** (a Grok subscription `/models` does not send it, or a cold start has not fetched it yet);
    /// the subscription input verdict then falls to the `model-facts` dictionary; non-nil is first-hand, and a medium missing from the list is not accepted.
    /// Same discipline as `upstreamReasoningLevels`: **not in `CodingKeys`**, refilled on every catalog fetch.
    var upstreamInputModalities: [String]? = nil
    /// Outbound protocol the upstream declares for this model. Nil means the upstream declared nothing,
    /// so the seed `apiBackend` applies, then chat completions
    /// (`CapabilityControlResolution.subscriptionFinalTransport`). Refilled on every catalog fetch.
    var upstreamAPIBackend: String? = nil
    var upstreamDefaultReasoningLevel: String? = nil
    /// The per-item capability verdict a catalog declares for this model (for the truth adapter only).
    /// Nil = this object was not produced by decoding the current catalog; an item inside being nil = the catalog did not declare it.
    /// Same discipline as `upstreamReasoningLevels`: **not in `CodingKeys`**, refilled on every catalog fetch.
    var catalogCapabilityTruth: CatalogCapabilityTruth? = nil

    var supportsImageGenerationRoute: Bool {
        capabilities.contains(.imageGen)
            && imageGenProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    var isManual: Bool = false
    /// Relay 2.0: model-level protocol. Nil = follow the connection's default protocol; `.auto` is not a valid model-level value.
    /// Reads go only through `RelayEndpointResolver.effectiveTransport(provider:model:)`.
    /// Model-level fields (including engineDeclaration below) are stored only on this device and in the user's own backup file, never in Firestore.
    var relayTransport: RelayTransport? = nil
    /// Where the model-level protocol came from; meaningless when `relayTransport` is nil, and omitted when encoding.
    var relayTransportSource: RelayTransportSource? = nil
    /// The user's manual override of this model's capabilities.
    var relayCapabilityOverrides: RelayCapabilityOverrides? = nil
    /// The capability declaration the local engine makes for this model. Written only by the local engine connector; nil = no declaration.
    var engineDeclaration: EngineDeclaration? = nil
    /// Multiple keys: the id of the key this model is bound to; nil or pointing at a deleted key = the primary key. Not written when the connection has a single key.
    var relayKeyID: String? = nil
    /// Catalog entry: ids of the keys that listed this model when the catalog was fetched (in key order); nil = listed by the primary key.
    var relayListedByKeyIDs: [String]? = nil
    /// The id of the key most recently judged "this key cannot use this model"; meaningful only when it equals the key currently in effect.
    var relayDeniedKeyID: String? = nil

    /// The Relay 2.0 model-level field surface. `CaseIterable` is deliberate: the cross-platform fixture `modelFields.all` reconciles against it.
    enum RelayFieldKey: String, CaseIterable {
        case relayTransport, relayTransportSource, relayCapabilityOverrides, engineDeclaration
        case relayKeyID, relayListedByKeyIDs, relayDeniedKeyID
    }

    /// The subset of model-level fields allowed to leave this device for Firestore: currently none.
    nonisolated static let relayPortableFieldNames: Set<String> = []

    /// Protocol and source must come as a pair: a protocol of `auto` or missing means neither; a protocol without a source drops both.
    nonisolated static func normalizedRelayTransport(
        transport: RelayTransport?,
        source: RelayTransportSource?
    ) -> (transport: RelayTransport?, source: RelayTransportSource?) {
        guard let transport, transport != .auto, let source else { return (nil, nil) }
        return (transport, source)
    }
    var attachmentExtraction: AttachmentExtractionLimits? = nil
    var nativeFileMimes: [String] = []
    var pdfNativeDefault: Bool = false
    var freeQuotaEligible: Bool = true
    var localLoadState: LocalModelLoadState? = nil
    var executionLocality: ModelExecutionLocality? = nil

    init(
        id: String,
        name: String,
        capabilities: [ModelCapability],
        reasoningModeAvailable: Bool,
        isAvailable: Bool,
        isDefault: Bool,
        priceTier: String,
        summary: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        groupKey: String? = nil,
        groupName: String? = nil,
        createdAt: TimeInterval? = nil,
        promptPrice: Double? = nil,
        completionPrice: Double? = nil,
        billingSku: String? = nil,
        pricingUnit: String = "per_token",
        sourceSummary: ModelSourceSummary? = nil,
        costPerUnit: Double? = nil,
        costInputBatches: Double? = nil,
        costOutputBatches: Double? = nil,
        costInputPriority: Double? = nil,
        costOutputPriority: Double? = nil,
        cacheReadInputPerMToken: Double? = nil,
        cacheCreationInputPerMToken: Double? = nil,
        cacheWrite5mPerMToken: Double? = nil,
        cacheWrite1hPerMToken: Double? = nil,
        supportsPdfInput: Bool = false,
        supportsServiceTier: Bool = false,
        canonicalModelId: String? = nil,
        isRecommended: Bool? = nil,
        sortRank: Int? = nil,
        badgeOrder: [ModelCapability]? = nil,
        reasoningProfile: String? = nil,
        webSearchProfile: String? = nil,
        imageGenProfile: String? = nil,
        generationProfile: GenerationProfileRef? = nil,
        capabilityEvidenceCandidates: [CapabilityEvidenceFacade.Candidate] = [],
        capabilityEvidenceOwnedKeys: Set<String> = [],
        capabilityEvidenceViewPresent: Bool = false,
        capabilityEvidenceViewMalformed: Bool = false,
        toolCall: Bool? = nil,
        libraryAgentic: Bool? = nil,
        isManual: Bool = false,
        attachmentExtraction: AttachmentExtractionLimits? = nil,
        nativeFileMimes: [String] = [],
        pdfNativeDefault: Bool = false,
        freeQuotaEligible: Bool = true,
        localLoadState: LocalModelLoadState? = nil,
        executionLocality: ModelExecutionLocality? = nil
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.reasoningModeAvailable = reasoningModeAvailable
        self.isAvailable = isAvailable
        self.isDefault = isDefault
        self.priceTier = priceTier
        self.summary = summary
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.groupKey = groupKey
        self.groupName = groupName
        self.createdAt = createdAt
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
        self.billingSku = billingSku
        self.pricingUnit = pricingUnit
        self.sourceSummary = sourceSummary
        self.costPerUnit = costPerUnit
        self.costInputBatches = costInputBatches
        self.costOutputBatches = costOutputBatches
        self.costInputPriority = costInputPriority
        self.costOutputPriority = costOutputPriority
        self.cacheReadInputPerMToken = cacheReadInputPerMToken
        self.cacheCreationInputPerMToken = cacheCreationInputPerMToken
        self.cacheWrite5mPerMToken = cacheWrite5mPerMToken
        self.cacheWrite1hPerMToken = cacheWrite1hPerMToken
        self.supportsPdfInput = supportsPdfInput
        self.supportsServiceTier = supportsServiceTier
        self.canonicalModelId = canonicalModelId
        self.isRecommended = isRecommended
        self.sortRank = sortRank
        self.badgeOrder = badgeOrder
        self.reasoningProfile = reasoningProfile
        self.webSearchProfile = webSearchProfile
        self.imageGenProfile = imageGenProfile
        self.generationProfile = generationProfile
        self.capabilityEvidenceCandidates = capabilityEvidenceCandidates
        self.capabilityEvidenceOwnedKeys = capabilityEvidenceOwnedKeys
        self.capabilityEvidenceViewPresent = capabilityEvidenceViewPresent
        self.capabilityEvidenceViewMalformed = capabilityEvidenceViewMalformed
        self.toolCall = toolCall
        self.libraryAgentic = libraryAgentic
        self.isManual = isManual
        self.attachmentExtraction = attachmentExtraction
        self.nativeFileMimes = nativeFileMimes
        self.pdfNativeDefault = pdfNativeDefault
        self.freeQuotaEligible = freeQuotaEligible
        self.localLoadState = localLoadState
        self.executionLocality = executionLocality
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, capabilities, reasoningModeAvailable, isAvailable, isDefault, priceTier, summary
        case contextLength, maxOutputTokens, groupKey, groupName, createdAt, promptPrice, completionPrice
        case billingSku, pricingUnit, sourceSummary
        case costPerUnit, costInputBatches, costOutputBatches, costInputPriority, costOutputPriority
        case cacheReadInputPerMToken, cacheCreationInputPerMToken, cacheWrite5mPerMToken, cacheWrite1hPerMToken
        case supportsPdfInput, supportsServiceTier
        case canonicalModelId, isRecommended, sortRank, badgeOrder
        case reasoningProfile, webSearchProfile, imageGenProfile, generationProfile
        case toolCall
        case libraryAgentic
        case isManual
        case attachmentExtraction
        case nativeFileMimes
        case pdfNativeDefault
        case freeQuotaEligible, localLoadState, executionLocality
        case relayTransport, relayTransportSource, relayCapabilityOverrides, engineDeclaration
        case relayKeyID, relayListedByKeyIDs, relayDeniedKeyID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let rawCapabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilities = rawCapabilities.compactMap { ModelCapability(rawValue: $0) }
        reasoningModeAvailable = try c.decode(Bool.self, forKey: .reasoningModeAvailable)
        isAvailable = try c.decode(Bool.self, forKey: .isAvailable)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        priceTier = try c.decode(String.self, forKey: .priceTier)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        groupKey = try c.decodeIfPresent(String.self, forKey: .groupKey)
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        createdAt = try c.decodeIfPresent(TimeInterval.self, forKey: .createdAt)
        promptPrice = try c.decodeIfPresent(Double.self, forKey: .promptPrice)
        completionPrice = try c.decodeIfPresent(Double.self, forKey: .completionPrice)
        billingSku = try c.decodeIfPresent(String.self, forKey: .billingSku)
        pricingUnit = try c.decodeIfPresent(String.self, forKey: .pricingUnit) ?? "per_token"
        sourceSummary = try c.decodeIfPresent(ModelSourceSummary.self, forKey: .sourceSummary)
        costPerUnit = try c.decodeIfPresent(Double.self, forKey: .costPerUnit)
        costInputBatches = try c.decodeIfPresent(Double.self, forKey: .costInputBatches)
        costOutputBatches = try c.decodeIfPresent(Double.self, forKey: .costOutputBatches)
        costInputPriority = try c.decodeIfPresent(Double.self, forKey: .costInputPriority)
        costOutputPriority = try c.decodeIfPresent(Double.self, forKey: .costOutputPriority)
        cacheReadInputPerMToken = try c.decodeIfPresent(Double.self, forKey: .cacheReadInputPerMToken)
        cacheCreationInputPerMToken = try c.decodeIfPresent(Double.self, forKey: .cacheCreationInputPerMToken)
        cacheWrite5mPerMToken = try c.decodeIfPresent(Double.self, forKey: .cacheWrite5mPerMToken)
        cacheWrite1hPerMToken = try c.decodeIfPresent(Double.self, forKey: .cacheWrite1hPerMToken)
        supportsPdfInput = try c.decodeIfPresent(Bool.self, forKey: .supportsPdfInput) ?? false
        supportsServiceTier = try c.decodeIfPresent(Bool.self, forKey: .supportsServiceTier) ?? false
        canonicalModelId = try c.decodeIfPresent(String.self, forKey: .canonicalModelId)
        isRecommended = try c.decodeIfPresent(Bool.self, forKey: .isRecommended)
        sortRank = try c.decodeIfPresent(Int.self, forKey: .sortRank)
        if let rawBadgeOrder = try c.decodeIfPresent([String].self, forKey: .badgeOrder) {
            badgeOrder = rawBadgeOrder.compactMap { ModelCapability(rawValue: $0) }
        } else {
            badgeOrder = nil
        }
        reasoningProfile = try c.decodeIfPresent(String.self, forKey: .reasoningProfile)
        webSearchProfile = try c.decodeIfPresent(String.self, forKey: .webSearchProfile)
        imageGenProfile = try c.decodeIfPresent(String.self, forKey: .imageGenProfile)
        generationProfile = try c.decodeIfPresent(GenerationProfileRef.self, forKey: .generationProfile)
        capabilityEvidenceCandidates = []
        capabilityEvidenceOwnedKeys = []
        capabilityEvidenceViewPresent = false
        capabilityEvidenceViewMalformed = false
        toolCall = try c.decodeIfPresent(Bool.self, forKey: .toolCall)
        libraryAgentic = try c.decodeIfPresent(Bool.self, forKey: .libraryAgentic)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        attachmentExtraction = try c.decodeIfPresent(AttachmentExtractionLimits.self, forKey: .attachmentExtraction)
        nativeFileMimes = try c.decodeIfPresent([String].self, forKey: .nativeFileMimes) ?? []
        pdfNativeDefault = try c.decodeIfPresent(Bool.self, forKey: .pdfNativeDefault) ?? false
        freeQuotaEligible = try c.decodeIfPresent(Bool.self, forKey: .freeQuotaEligible) ?? true
        localLoadState = try c.decodeIfPresent(LocalModelLoadState.self, forKey: .localLoadState)
        executionLocality = try c.decodeIfPresent(ModelExecutionLocality.self, forKey: .executionLocality)
        // Relay 2.0 model-level fields are tolerated one by one: an unknown protocol / source or a malformed
        // override drops only itself and never fails the whole model decode. They are read as raw strings
        // because `RelayTransport`'s own decoding folds unknown values into `.auto`, while here
        // "unknown = absent" is wanted.
        let rawRelayTransport = try? c.decodeIfPresent(String.self, forKey: .relayTransport)
        let rawRelaySource = try? c.decodeIfPresent(String.self, forKey: .relayTransportSource)
        let relay = Self.normalizedRelayTransport(
            transport: rawRelayTransport.flatMap(RelayTransport.init(rawValue:)),
            source: rawRelaySource.flatMap(RelayTransportSource.init(rawValue:))
        )
        relayTransport = relay.transport
        relayTransportSource = relay.source
        let overrides = try? c.decodeIfPresent(RelayCapabilityOverrides.self, forKey: .relayCapabilityOverrides)
        relayCapabilityOverrides = overrides?.isEmpty == false ? overrides : nil
        let declaration = try? c.decodeIfPresent(EngineDeclaration.self, forKey: .engineDeclaration)
        engineDeclaration = declaration?.isEmpty == false ? declaration : nil
        // The three key-binding fields are tolerated one by one as well: a malformed one drops only itself, and an empty string / empty list counts as absent.
        relayKeyID = (try? c.decodeIfPresent(String.self, forKey: .relayKeyID)).flatMap { $0.isEmpty ? nil : $0 }
        let listedBy = (try? c.decodeIfPresent([String].self, forKey: .relayListedByKeyIDs))?.filter { !$0.isEmpty }
        relayListedByKeyIDs = listedBy?.isEmpty == false ? listedBy : nil
        relayDeniedKeyID = (try? c.decodeIfPresent(String.self, forKey: .relayDeniedKeyID)).flatMap { $0.isEmpty ? nil : $0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(reasoningModeAvailable, forKey: .reasoningModeAvailable)
        try c.encode(isAvailable, forKey: .isAvailable)
        try c.encode(isDefault, forKey: .isDefault)
        try c.encode(priceTier, forKey: .priceTier)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(contextLength, forKey: .contextLength)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encodeIfPresent(groupKey, forKey: .groupKey)
        try c.encodeIfPresent(groupName, forKey: .groupName)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(promptPrice, forKey: .promptPrice)
        try c.encodeIfPresent(completionPrice, forKey: .completionPrice)
        try c.encodeIfPresent(billingSku, forKey: .billingSku)
        try c.encode(pricingUnit, forKey: .pricingUnit)
        try c.encodeIfPresent(sourceSummary, forKey: .sourceSummary)
        try c.encodeIfPresent(costPerUnit, forKey: .costPerUnit)
        try c.encodeIfPresent(costInputBatches, forKey: .costInputBatches)
        try c.encodeIfPresent(costOutputBatches, forKey: .costOutputBatches)
        try c.encodeIfPresent(costInputPriority, forKey: .costInputPriority)
        try c.encodeIfPresent(costOutputPriority, forKey: .costOutputPriority)
        try c.encodeIfPresent(cacheReadInputPerMToken, forKey: .cacheReadInputPerMToken)
        try c.encodeIfPresent(cacheCreationInputPerMToken, forKey: .cacheCreationInputPerMToken)
        try c.encodeIfPresent(cacheWrite5mPerMToken, forKey: .cacheWrite5mPerMToken)
        try c.encodeIfPresent(cacheWrite1hPerMToken, forKey: .cacheWrite1hPerMToken)
        try c.encode(supportsPdfInput, forKey: .supportsPdfInput)
        try c.encode(supportsServiceTier, forKey: .supportsServiceTier)
        try c.encodeIfPresent(canonicalModelId, forKey: .canonicalModelId)
        try c.encodeIfPresent(isRecommended, forKey: .isRecommended)
        try c.encodeIfPresent(sortRank, forKey: .sortRank)
        try c.encodeIfPresent(badgeOrder, forKey: .badgeOrder)
        try c.encodeIfPresent(reasoningProfile, forKey: .reasoningProfile)
        try c.encodeIfPresent(webSearchProfile, forKey: .webSearchProfile)
        try c.encodeIfPresent(imageGenProfile, forKey: .imageGenProfile)
        try c.encodeIfPresent(generationProfile, forKey: .generationProfile)
        try c.encodeIfPresent(toolCall, forKey: .toolCall)
        try c.encodeIfPresent(libraryAgentic, forKey: .libraryAgentic)
        try c.encode(isManual, forKey: .isManual)
        try c.encodeIfPresent(attachmentExtraction, forKey: .attachmentExtraction)
        if !nativeFileMimes.isEmpty {
            try c.encode(nativeFileMimes, forKey: .nativeFileMimes)
        }
        if pdfNativeDefault {
            try c.encode(pdfNativeDefault, forKey: .pdfNativeDefault)
        }
        if !freeQuotaEligible {
            try c.encode(freeQuotaEligible, forKey: .freeQuotaEligible)
        }
        try c.encodeIfPresent(localLoadState, forKey: .localLoadState)
        try c.encodeIfPresent(executionLocality, forKey: .executionLocality)
        let relay = Self.normalizedRelayTransport(transport: relayTransport, source: relayTransportSource)
        try c.encodeIfPresent(relay.transport, forKey: .relayTransport)
        try c.encodeIfPresent(relay.source, forKey: .relayTransportSource)
        if let relayCapabilityOverrides, !relayCapabilityOverrides.isEmpty {
            try c.encode(relayCapabilityOverrides, forKey: .relayCapabilityOverrides)
        }
        if let engineDeclaration, !engineDeclaration.isEmpty {
            try c.encode(engineDeclaration, forKey: .engineDeclaration)
        }
        try c.encodeIfPresent(relayKeyID, forKey: .relayKeyID)
        try c.encodeIfPresent(relayListedByKeyIDs, forKey: .relayListedByKeyIDs)
        try c.encodeIfPresent(relayDeniedKeyID, forKey: .relayDeniedKeyID)
    }
}

enum LocalModelLoadState: String, Codable, Hashable, Sendable {
    case loaded, loading, unloaded, unknown
}

enum ModelExecutionLocality: String, Codable, Hashable, Sendable {
    case local
    case proxiedCloud = "proxied_cloud"
    case unknown
}

struct LocalModelRuntimeMetadata: Sendable {
    let loadState: LocalModelLoadState
    let executionLocality: ModelExecutionLocality
    /// The capability declaration the connector parsed from the engine's existing responses; an empty declaration is recorded as nil.
    var engineDeclaration: EngineDeclaration? = nil
}

struct ModelSourceSummary: Hashable, Codable, Sendable {
    var sourceKind: String
    var sourceName: String
    var fetchedAt: String
}

struct LastUsedModelRef: Hashable, Codable {
    var providerID: UUID
    var modelID: String
}

enum ProviderAuthMode: String, Codable, Sendable, Hashable, CaseIterable {
    case apiKey
    case subscription
}

struct Provider: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: ProviderKind
    var status: ProviderConnectionState
    var models: [AIModel]
    var catalogModels: [AIModel]
    var lastCheckedAt: Date?
    var apiKey: String
    var apiKeyPreview: String
    var lastError: String?
    var baseURLText: String?
    var customName: String?
    var updatedAt: Date = .distantPast
    var relayRequested: RelayRequestedConfig? = nil
    var relayKind: RelayKind? = nil

    var authMode: ProviderAuthMode = .apiKey
    /// Where an official provider's address came from. Stored only on this device: not in the sync payload or the backup export; nil = unclassified.
    var endpointSource: ProviderEndpointSource? = nil
    /// Template values entered at setup (currently only `workspaceId`). Stored only on this device.
    var setupValues: [String: String]? = nil
    /// The relay's key list, produced only by the user's key operations; nil = one implicit key `initial`.
    /// The first is the primary key and its value always lives in `apiKey` (the entry's own `apiKey` stays empty); the other entries' values go to the Keychain.
    /// Stored only on this device like `setupValues`: not in Firestore or backups, and a remote merge keeps the local value.
    var relayKeys: [RelayKey]? = nil

    var displayName: String {
        if let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        if kind == .relay {
            if let host = relayBaseURLHost {
                return "Relay (\(host))"
            }
            return "Relay"
        }
        return kind.displayName
    }

    private var relayBaseURLHost: String? {
        guard let raw = baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: withScheme)?.host, !host.isEmpty else {
            return nil
        }
        return host
    }
    var enabledModelCount: Int { models.count }
    var cachedAvailableModelCount: Int?
    var allModels: [AIModel] {
        if kind == .relay || !catalogModels.isEmpty {
            return catalogModels.isEmpty ? models : catalogModels
        }

        let resolvedCatalog = ProviderCatalogResolver.resolve(provider: self).catalog.map(\.model)
        return resolvedCatalog.isEmpty ? models : resolvedCatalog
    }
    var availableModelCount: Int {
        cachedAvailableModelCount ?? models.count
    }
    /// A relay (including a local engine) has no default model: `isDefault` in old data is ignored and the first enabled model is used.
    var defaultModel: AIModel? {
        guard kind != .relay else { return models.first }
        return models.first(where: \.isDefault) ?? models.first
    }

    func recoveredFromPersistence() -> Provider {
        guard case .syncing = status else { return self }
        var recovered = self
        recovered.status = .connected
        return recovered
    }
}

extension Provider {
    private enum CodingKeys: String, CodingKey {
        case id, kind, status, models, catalogModels
        case lastCheckedAt, lastSyncedAt, apiKey, apiKeyPreview, lastError, baseURLText
        case lastSyncedText, customName, updatedAt
        case cachedAvailableModelCount
        case relayRequested, relayKind, authMode
        case endpointSource, setupValues
        case relayKeys
        case recommendedModels, relayImage, relayImport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        status = try c.decode(ProviderConnectionState.self, forKey: .status)
        let decodedModels = try c.decode([AIModel].self, forKey: .models)
        // A relay's enabled list is also deduplicated by literal key; an official enabled list is kept as is
        models = kind == .relay ? ModelResolver.relayDeduplicated(decodedModels) : decodedModels
        catalogModels = CatalogModelBuilder.deduplicate(
            try c.decodeIfPresent([AIModel].self, forKey: .catalogModels) ?? [],
            providerKind: kind
        )
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
            ?? c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        apiKeyPreview = try c.decodeIfPresent(String.self, forKey: .apiKeyPreview) ?? ""
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        baseURLText = try c.decodeIfPresent(String.self, forKey: .baseURLText)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        cachedAvailableModelCount = try c.decodeIfPresent(Int.self, forKey: .cachedAvailableModelCount)
        relayRequested = try c.decodeIfPresent(RelayRequestedConfig.self, forKey: .relayRequested)
        relayKind = try c.decodeIfPresent(RelayKind.self, forKey: .relayKind)
        authMode = try c.decodeIfPresent(ProviderAuthMode.self, forKey: .authMode) ?? .apiKey
        // An unknown source value counts as unclassified and is reclassified from metadata on the next launch, so the whole record never fails to decode.
        endpointSource = (try? c.decodeIfPresent(String.self, forKey: .endpointSource))
            .flatMap(ProviderEndpointSource.init(rawValue:))
        setupValues = try? c.decodeIfPresent([String: String].self, forKey: .setupValues)
        // A malformed column is dropped as a whole (falls back to the implicit single key) so the Provider still decodes.
        relayKeys = (try? c.decodeIfPresent([RelayKey].self, forKey: .relayKeys)).flatMap { $0.isEmpty ? nil : $0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encode(models, forKey: .models)
        try c.encode(catalogModels, forKey: .catalogModels)
        try c.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        try c.encode(apiKeyPreview, forKey: .apiKeyPreview)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(baseURLText, forKey: .baseURLText)
        try c.encodeIfPresent(customName, forKey: .customName)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(cachedAvailableModelCount, forKey: .cachedAvailableModelCount)
        try c.encodeIfPresent(relayRequested, forKey: .relayRequested)
        try c.encodeIfPresent(relayKind, forKey: .relayKind)
        try c.encode(authMode, forKey: .authMode)
        try c.encodeIfPresent(endpointSource?.rawValue, forKey: .endpointSource)
        try c.encodeIfPresent(setupValues, forKey: .setupValues)
        // Same discipline as apiKey: the Provider JSON never stores any key value, and non-primary key values live only in the Keychain.
        try c.encodeIfPresent(relayKeys?.map(\.withoutSecret), forKey: .relayKeys)
    }
}

/// One key of a relay connection. `status` comes only from catalog fetches and real requests; nil = not checked.
nonisolated struct RelayKey: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var apiKey: String
    var status: Status?

    init(id: String, name: String? = nil, apiKey: String = "", status: Status? = nil) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.status = status
    }

    struct Status: Codable, Hashable, Sendable {
        enum State: String, Codable, CaseIterable, Sendable {
            case ok, invalid, denied, limited, failed
        }

        var state: State
        var httpStatus: Int?
        var checkedAt: Date?
    }

    private enum CodingKeys: String, CodingKey { case id, name, apiKey, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty relay key id")
        }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        // A value outside the status vocabulary or a malformed one drops only the status (= not checked), not the whole key.
        status = try? c.decodeIfPresent(Status.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(status, forKey: .status)
    }

    var withoutSecret: RelayKey {
        var copy = self
        copy.apiKey = ""
        return copy
    }
}
