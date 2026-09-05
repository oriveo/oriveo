import Foundation



enum RelayTransport: String, Codable, Hashable, Sendable, CaseIterable {
    case auto
    case openaiResponses = "openai_responses"
    case openaiChatCompletions = "openai_chat_completions"
    case llamacppNative = "llamacpp_native"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerateContent = "gemini_generate_content"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RelayTransport(rawValue: raw) ?? .auto
    }
}

extension RelayRequestedConfig {
    var effectiveHeaders: [RelayKeyValue]? { authMode == .none ? nil : headers }
    var effectiveQueryParams: [RelayKeyValue]? { authMode == .none ? nil : queryParams }
    var effectiveCustomUserAgent: String? { authMode == .none ? nil : customUserAgent }
    var effectiveCodexCompatIdentity: Bool? { authMode == .none ? false : codexCompatIdentity }
}

enum RelayAuthMode: String, Codable, Hashable, Sendable {
    case auto
    case none
    case bearer
    case xApiKey = "x_api_key"
    case xGoogApiKey = "x_goog_api_key"
    case queryKey = "query_key"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RelayAuthMode(rawValue: raw) ?? .auto
    }
}

enum RelayConnectionSecurityMode: String, Codable, Hashable, Sendable {
    case remoteHTTPS = "remote_https"
    case localHTTP = "local_http"
    case privateVPN = "private_vpn"
    case tofuHTTPS = "tofu_https"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RelayConnectionSecurityMode(rawValue: raw) ?? .remoteHTTPS
    }
}

enum RelayReasoningEffort: String, Codable, Hashable, Sendable {
    case automatic
    case low
    case medium
    case high
    case xhigh
}

enum RelayKind: String, Codable, Hashable, Sendable, CaseIterable {
    case openaiCompatible = "openai_compatible"
    case codexStyle = "codex_style"
    case anthropicCompatible = "anthropic_compatible"
    case geminiCompatible = "gemini_compatible"
    case custom

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RelayKind(rawValue: raw) ?? .custom
    }

    init(transport: RelayTransport) {
        switch transport {
        case .llamacppNative, .openaiChatCompletions: self = .openaiCompatible
        case .openaiResponses: self = .codexStyle
        case .anthropicMessages: self = .anthropicCompatible
        case .geminiGenerateContent: self = .geminiCompatible
        case .auto: self = .custom
        }
    }
}


nonisolated struct RelayKeyValue: Codable, Hashable, Sendable {
    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}


nonisolated struct RelayRequestedConfig: Hashable, Sendable {
    /// Anthropic Messages / Gemini generateContent).
    var transport: RelayTransport
    var authMode: RelayAuthMode
    var securityMode: RelayConnectionSecurityMode
    var modelID: String?
    var reasoningEffort: RelayReasoningEffort?
    var serviceTier: String?
    var stream: Bool?
    var disableResponseStorage: Bool?
    var headers: [RelayKeyValue]?
    var queryParams: [RelayKeyValue]?
    var codexCompatIdentity: Bool?
    var customUserAgent: String?
    var imageSize: String?
    /// dall-e-3: `standard` / `hd`;gpt-image-1: `low` / `medium` / `high` / `auto`
    var imageQuality: String?
    var imageStyle: String?
    var imageCount: Int?
    var imageResponseFormat: String?
    var webSearchToolName: RelayWebSearchToolName?
    var hasWebSearch: Bool?
    /// `ant_web_tool` / `gem_web` / `grok_responses_web` / `qwen_web` /
    /// `zhipu_web` / `or_web` / `kimi_web_search`).
    var webSearchProfile: String?
    ///   anthropic_messages / gemini_generate_content)
    var transportKind: String?
    var resolvedAPIBaseURL: String?
    /// Explicit local engine profile. nil for every existing/cloud Relay.
    var engineProfile: String?
    /// SHA-256 leaf certificate pin for explicit TOFU HTTPS mode.
    var certificateFingerprint: String?

    init(
        transport: RelayTransport = .auto,
        authMode: RelayAuthMode = .auto,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS,
        modelID: String? = nil,
        reasoningEffort: RelayReasoningEffort? = nil,
        serviceTier: String? = nil,
        stream: Bool? = nil,
        disableResponseStorage: Bool? = nil,
        headers: [RelayKeyValue]? = nil,
        queryParams: [RelayKeyValue]? = nil,
        codexCompatIdentity: Bool? = nil,
        customUserAgent: String? = nil,
        imageSize: String? = nil,
        imageQuality: String? = nil,
        imageStyle: String? = nil,
        imageCount: Int? = nil,
        imageResponseFormat: String? = nil,
        webSearchToolName: RelayWebSearchToolName? = nil,
        hasWebSearch: Bool? = nil,
        webSearchProfile: String? = nil,
        transportKind: String? = nil,
        resolvedAPIBaseURL: String? = nil,
        engineProfile: String? = nil,
        certificateFingerprint: String? = nil
    ) {
        self.transport = transport
        self.authMode = authMode
        self.securityMode = securityMode
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.stream = stream
        self.disableResponseStorage = disableResponseStorage
        self.headers = headers
        self.queryParams = queryParams
        self.codexCompatIdentity = codexCompatIdentity
        self.customUserAgent = customUserAgent
        self.imageSize = imageSize
        self.imageQuality = imageQuality
        self.imageStyle = imageStyle
        self.imageCount = imageCount
        self.imageResponseFormat = imageResponseFormat
        self.webSearchToolName = webSearchToolName
        self.hasWebSearch = hasWebSearch
        self.webSearchProfile = webSearchProfile
        self.transportKind = transportKind
        self.resolvedAPIBaseURL = resolvedAPIBaseURL
        self.engineProfile = engineProfile
        self.certificateFingerprint = certificateFingerprint
    }
}

enum RelayWebSearchToolName: String, Hashable, Sendable, Codable {
    case webSearch = "web_search"
    case webSearchPreview = "web_search_preview"
    case disabled = "disabled"
}


extension RelayRequestedConfig: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case transport, authMode, securityMode, modelID, reasoningEffort, serviceTier, stream
        case disableResponseStorage, headers, queryParams
        case codexCompatIdentity, customUserAgent
        case imageSize, imageQuality, imageStyle, imageCount, imageResponseFormat
        case webSearchToolName
        case hasWebSearch, webSearchProfile, transportKind, resolvedAPIBaseURL, engineProfile, certificateFingerprint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.transport = try c.decodeIfPresent(RelayTransport.self, forKey: .transport) ?? .auto
        self.authMode = try c.decodeIfPresent(RelayAuthMode.self, forKey: .authMode) ?? .auto
        self.securityMode = try c.decodeIfPresent(RelayConnectionSecurityMode.self, forKey: .securityMode) ?? .remoteHTTPS
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.reasoningEffort = try c.decodeIfPresent(RelayReasoningEffort.self, forKey: .reasoningEffort)
        self.serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
        self.stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
        self.disableResponseStorage = try c.decodeIfPresent(Bool.self, forKey: .disableResponseStorage)
        self.headers = try c.decodeIfPresent([RelayKeyValue].self, forKey: .headers)
        self.queryParams = try c.decodeIfPresent([RelayKeyValue].self, forKey: .queryParams)
        self.codexCompatIdentity = try c.decodeIfPresent(Bool.self, forKey: .codexCompatIdentity)
        self.customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent)
        self.imageSize = try c.decodeIfPresent(String.self, forKey: .imageSize)
        self.imageQuality = try c.decodeIfPresent(String.self, forKey: .imageQuality)
        self.imageStyle = try c.decodeIfPresent(String.self, forKey: .imageStyle)
        self.imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount)
        self.imageResponseFormat = try c.decodeIfPresent(String.self, forKey: .imageResponseFormat)
        self.webSearchToolName = (try? c.decodeIfPresent(RelayWebSearchToolName.self, forKey: .webSearchToolName)) ?? nil
        self.hasWebSearch = try c.decodeIfPresent(Bool.self, forKey: .hasWebSearch)
        self.webSearchProfile = try c.decodeIfPresent(String.self, forKey: .webSearchProfile)
        self.transportKind = try c.decodeIfPresent(String.self, forKey: .transportKind)
        self.resolvedAPIBaseURL = try c.decodeIfPresent(String.self, forKey: .resolvedAPIBaseURL)
        self.engineProfile = try c.decodeIfPresent(String.self, forKey: .engineProfile)
        self.certificateFingerprint = try c.decodeIfPresent(String.self, forKey: .certificateFingerprint)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transport, forKey: .transport)
        try c.encode(authMode, forKey: .authMode)
        try c.encode(securityMode, forKey: .securityMode)
        try c.encodeIfPresent(modelID, forKey: .modelID)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(disableResponseStorage, forKey: .disableResponseStorage)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(queryParams, forKey: .queryParams)
        try c.encodeIfPresent(codexCompatIdentity, forKey: .codexCompatIdentity)
        try c.encodeIfPresent(customUserAgent, forKey: .customUserAgent)
        try c.encodeIfPresent(imageSize, forKey: .imageSize)
        try c.encodeIfPresent(imageQuality, forKey: .imageQuality)
        try c.encodeIfPresent(imageStyle, forKey: .imageStyle)
        try c.encodeIfPresent(imageCount, forKey: .imageCount)
        try c.encodeIfPresent(imageResponseFormat, forKey: .imageResponseFormat)
        try c.encodeIfPresent(webSearchToolName, forKey: .webSearchToolName)
        try c.encodeIfPresent(hasWebSearch, forKey: .hasWebSearch)
        try c.encodeIfPresent(webSearchProfile, forKey: .webSearchProfile)
        try c.encodeIfPresent(transportKind, forKey: .transportKind)
        try c.encodeIfPresent(resolvedAPIBaseURL, forKey: .resolvedAPIBaseURL)
        try c.encodeIfPresent(engineProfile, forKey: .engineProfile)
        try c.encodeIfPresent(certificateFingerprint, forKey: .certificateFingerprint)
    }
}

extension RelayRequestedConfig {
    nonisolated static let portableFieldNames: Set<String> = [
        "transport", "authMode", "securityMode", "modelID", "reasoningEffort", "serviceTier",
        "stream", "disableResponseStorage", "codexCompatIdentity",
        "imageSize", "imageQuality", "imageStyle", "imageCount", "imageResponseFormat",
        "webSearchToolName", "hasWebSearch", "webSearchProfile", "transportKind",
        "resolvedAPIBaseURL", "engineProfile",
    ]

    nonisolated func credentialFreePortableCopy() -> RelayRequestedConfig {
        var copy = RelayRequestedConfig(
            transport: transport,
            authMode: authMode,
            securityMode: securityMode,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            stream: stream,
            disableResponseStorage: disableResponseStorage,
            codexCompatIdentity: codexCompatIdentity,
            imageSize: imageSize,
            imageQuality: imageQuality,
            imageStyle: imageStyle,
            imageCount: imageCount,
            imageResponseFormat: imageResponseFormat,
            webSearchToolName: webSearchToolName,
            hasWebSearch: hasWebSearch,
            webSearchProfile: webSearchProfile,
            transportKind: transportKind
        )
        copy.resolvedAPIBaseURL = Self.credentialFreeEndpoint(resolvedAPIBaseURL)
        copy.engineProfile = engineProfile
        return copy
    }

    nonisolated static func credentialFreeEndpoint(_ raw: String?) -> String? {
        guard let raw, var components = URLComponents(string: raw) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }
}


enum RelayKindDefaults {

    static func makeRequested(
        for kind: RelayKind,
        preserving preserve: RelayRequestedConfig? = nil
    ) -> RelayRequestedConfig {
        switch kind {
        case .openaiCompatible:
            return RelayRequestedConfig(
                transport: .openaiChatCompletions,
                authMode: .bearer,
                modelID: preserve?.modelID,
                reasoningEffort: preserve?.reasoningEffort ?? .automatic,
                serviceTier: preserve?.serviceTier,
                stream: true,
                disableResponseStorage: nil,
                headers: preserve?.headers,
                queryParams: preserve?.queryParams,
                codexCompatIdentity: nil,
                customUserAgent: preserve?.customUserAgent,
                imageSize: preserve?.imageSize,
                imageQuality: preserve?.imageQuality,
                imageStyle: preserve?.imageStyle,
                imageCount: preserve?.imageCount,
                imageResponseFormat: preserve?.imageResponseFormat,
                webSearchToolName: preserve?.webSearchToolName,
                hasWebSearch: preserve?.hasWebSearch,
                webSearchProfile: preserve?.webSearchProfile,
                transportKind: preserve?.transportKind,
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL
            )
        case .codexStyle:
            return RelayRequestedConfig(
                transport: .openaiResponses,
                authMode: .bearer,
                modelID: preserve?.modelID,
                reasoningEffort: preserve?.reasoningEffort ?? .automatic,
                serviceTier: preserve?.serviceTier,
                stream: true,
                disableResponseStorage: true,
                headers: preserve?.headers,
                queryParams: preserve?.queryParams,
                codexCompatIdentity: true,
                customUserAgent: preserve?.customUserAgent,
                imageSize: preserve?.imageSize,
                imageQuality: preserve?.imageQuality,
                imageStyle: preserve?.imageStyle,
                imageCount: preserve?.imageCount,
                imageResponseFormat: preserve?.imageResponseFormat,
                webSearchToolName: preserve?.webSearchToolName,
                hasWebSearch: preserve?.hasWebSearch,
                webSearchProfile: preserve?.webSearchProfile,
                transportKind: preserve?.transportKind,
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL
            )
        case .anthropicCompatible:
            return RelayRequestedConfig(
                transport: .anthropicMessages,
                authMode: .xApiKey,
                modelID: preserve?.modelID,
                reasoningEffort: nil,
                serviceTier: nil,
                stream: true,
                disableResponseStorage: nil,
                headers: preserve?.headers,
                queryParams: preserve?.queryParams,
                codexCompatIdentity: nil,
                customUserAgent: preserve?.customUserAgent,
                imageSize: preserve?.imageSize,
                imageQuality: preserve?.imageQuality,
                imageStyle: preserve?.imageStyle,
                imageCount: preserve?.imageCount,
                imageResponseFormat: preserve?.imageResponseFormat,
                webSearchToolName: preserve?.webSearchToolName,
                hasWebSearch: preserve?.hasWebSearch,
                webSearchProfile: preserve?.webSearchProfile,
                transportKind: preserve?.transportKind,
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL
            )
        case .geminiCompatible:
            return RelayRequestedConfig(
                transport: .geminiGenerateContent,
                authMode: .xGoogApiKey,
                modelID: preserve?.modelID,
                reasoningEffort: nil,
                serviceTier: nil,
                stream: true,
                disableResponseStorage: nil,
                headers: preserve?.headers,
                queryParams: preserve?.queryParams,
                codexCompatIdentity: nil,
                customUserAgent: preserve?.customUserAgent,
                imageSize: preserve?.imageSize,
                imageQuality: preserve?.imageQuality,
                imageStyle: preserve?.imageStyle,
                imageCount: preserve?.imageCount,
                imageResponseFormat: preserve?.imageResponseFormat,
                webSearchToolName: preserve?.webSearchToolName,
                hasWebSearch: preserve?.hasWebSearch,
                webSearchProfile: preserve?.webSearchProfile,
                transportKind: preserve?.transportKind,
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL
            )
        case .custom:
            return RelayRequestedConfig(
                transport: preserve?.transport ?? .openaiChatCompletions,
                authMode: preserve?.authMode ?? .bearer,
                modelID: preserve?.modelID,
                reasoningEffort: preserve?.reasoningEffort ?? .automatic,
                serviceTier: preserve?.serviceTier,
                stream: preserve?.stream ?? true,
                disableResponseStorage: preserve?.disableResponseStorage,
                headers: preserve?.headers,
                queryParams: preserve?.queryParams,
                codexCompatIdentity: preserve?.codexCompatIdentity,
                customUserAgent: preserve?.customUserAgent,
                imageSize: preserve?.imageSize,
                imageQuality: preserve?.imageQuality,
                imageStyle: preserve?.imageStyle,
                imageCount: preserve?.imageCount,
                imageResponseFormat: preserve?.imageResponseFormat,
                webSearchToolName: preserve?.webSearchToolName,
                hasWebSearch: preserve?.hasWebSearch,
                webSearchProfile: preserve?.webSearchProfile,
                transportKind: preserve?.transportKind,
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL
            )
        }
    }

    static func inferKind(
        from requested: RelayRequestedConfig?,
        baseURL: String?
    ) -> RelayKind {
        guard let requested else { return .custom }
        switch requested.transport {
        case .openaiChatCompletions, .auto, .llamacppNative:
            return .openaiCompatible
        case .openaiResponses:
            if requested.codexCompatIdentity == true { return .codexStyle }
            if let host = baseURL?.lowercased(),
               codexHostHeuristics.contains(where: host.contains) {
                return .codexStyle
            }
            return .codexStyle
        case .anthropicMessages:
            return .anthropicCompatible
        case .geminiGenerateContent:
            return .geminiCompatible
        }
    }

    private static let codexHostHeuristics: [String] = [
        "packy", "ylsagi", "code-for", "ccswitch", "cc-switch", "codex"
    ]
}
