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
                ProviderEndpointOption(
                    id: "us",
                    label: L10n.tr("Virginia (US)", table: .providers),
                    baseURLText: "dashscope-us.aliyuncs.com"
                ),
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

    var usesConfigurableBaseURL: Bool {
        switch self {
        case .miniMax, .qwen, .moonshot, .relay:
            return true
        default:
            return false
        }
    }

    var attachmentSupport: (image: Bool, video: Bool, nativeFile: Bool, textFileInline: Bool) {
        if let support = MetadataClient.shared.syncProviderAttachmentSupport(providerKind: self) {
            return (
                image: support.image,
                video: support.video,
                nativeFile: support.nativeFile,
                textFileInline: support.textFileInline
            )
        }

        return fallbackAttachmentSupport
    }

    private var fallbackAttachmentSupport: (image: Bool, video: Bool, nativeFile: Bool, textFileInline: Bool) {
        switch self {
        case .openRouter:
            return (image: true, video: false, nativeFile: true, textFileInline: true)
        case .openAI:
            return (image: true, video: false, nativeFile: true, textFileInline: true)
        case .gemini:
            return (image: true, video: true, nativeFile: true, textFileInline: true)
        case .anthropic:
            return (image: true, video: false, nativeFile: true, textFileInline: true)
        case .deepseek:
            return (image: false, video: false, nativeFile: false, textFileInline: true)
        case .grok:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .groq:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .together:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .fireworks:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .miniMax:
            return (image: false, video: false, nativeFile: false, textFileInline: true)
        case .zhipu:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .qwen:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .moonshot:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .mistral:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .siliconFlow:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        case .relay:
            return (image: true, video: false, nativeFile: false, textFileInline: true)
        }
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
            return L10n.tr("File")
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

    func normalized(for model: AIModel?) -> ChatCapabilitySelection {
        guard let model else { return ChatCapabilitySelection() }

        var normalized = self
        if !model.reasoningModeAvailable {
            normalized.reasoningMode = .automatic
        } else {
            normalized.reasoningMode = MetadataClient.shared.syncClampReasoningMode(
                mode: normalized.reasoningMode,
                profileName: model.reasoningProfile
            )
        }
        if !model.capabilities.contains(.web) {
            normalized.webSearchEnabled = false
        }
        if !model.supportsWebSearchControl {
            normalized.webSearchEnabled = false
        }
        if model.toolCall == false {
            normalized.libraryResearchEnabled = false
        }
        return normalized
    }
}

struct AttachmentExtractionLimits: Codable, Equatable, Hashable, Sendable {
    var maxLines: Int?
    var maxBytes: Int?
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
}

struct GenerationParameterRange: Codable, Equatable, Hashable, Sendable {
    var min: Double?
    var max: Double?
    var minExclusive: Double?
    var maxExclusive: Double?
    var step: Double?
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
    /// Outbound protocol the upstream declares for this model. Nil means the upstream declared nothing,
    /// so the seed `apiBackend` applies, then chat completions
    /// (`CapabilityControlResolution.subscriptionFinalTransport`). Refilled on every catalog fetch.
    var upstreamAPIBackend: String? = nil
    var upstreamDefaultReasoningLevel: String? = nil

    var supportsWebSearchControl: Bool {
        capabilities.contains(.web)
            && webSearchProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var supportsImageGenerationRoute: Bool {
        capabilities.contains(.imageGen)
            && imageGenProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    var isManual: Bool = false
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
    var defaultModel: AIModel? { models.first(where: \.isDefault) ?? models.first }

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
        case recommendedModels, relayImage, relayImport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        status = try c.decode(ProviderConnectionState.self, forKey: .status)
        models = try c.decode([AIModel].self, forKey: .models)
        catalogModels = CatalogModelBuilder.deduplicateByCanonical(
            try c.decodeIfPresent([AIModel].self, forKey: .catalogModels) ?? []
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
    }
}

// MARK: - Telemetry

extension ProviderKind {
    var telemetryName: String {
        switch self {
        default: return rawValue.lowercased()
        }
    }

    func telemetryModelID(_ modelID: String?) -> String {
        self == .relay ? "custom" : (modelID ?? "unknown")
    }
}
