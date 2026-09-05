import Foundation

enum EndpointResolver {

    struct ResolvedEndpoint: Equatable, Sendable {
        let baseURL: String
        let path: String
 /// URL = baseURL + path(baseURL / path / )
        let url: URL
    }

    struct EndpointResolutionError: Error, Sendable {
        let providerKind: ProviderKind
        let endpoint: EndpointKind
        let reason: String
    }

    /// - Parameters:
 /// - provider: Provider ( baseURLText override)
    /// - Returns: ResolvedEndpoint
 /// - Throws: EndpointResolutionError fallback URL
    static func resolve(
        provider: Provider,
        kind: EndpointKind,
        metadataTransport: MetadataClient.ProviderTransportDefinition?
    ) throws -> ResolvedEndpoint {
        try resolve(
            providerKind: provider.kind,
            userBaseURL: provider.baseURLText,
            kind: kind,
            metadataTransport: metadataTransport
        )
    }

 /// baseURL > metadata > fallback baseURL allowlist.
    static func resolve(
        providerKind: ProviderKind,
        userBaseURL: String? = nil,
        kind: EndpointKind,
        metadataTransport: MetadataClient.ProviderTransportDefinition?
    ) throws -> ResolvedEndpoint {
        let userBase = sanitize(userBaseURL)
        let rawMetaBase = sanitize(metadataTransport?.baseUrl)
        let metaBase = validatedOfficialMetadataBaseURL(rawMetaBase, providerKind: providerKind)
        let metaPath = sanitize(endpointPath(in: metadataTransport?.endpoints, kind: kind))

        let fallbackBase = fallbackBaseURL(for: providerKind)
        let fallbackPath = fallbackEndpointPath(providerKind, kind: kind)

        let chosenBase: String
        let chosenPath: String
 // metadata path " origin "(), fallback
 // "base ", base ( normalizeBaseForEndpoint).
        let pathFromMetadata: Bool
        if let userBase {
            chosenBase = userBase
            chosenPath = metaPath ?? fallbackPath
            pathFromMetadata = metaPath != nil
        } else if let metaBase, let metaPath {
            chosenBase = metaBase
            chosenPath = metaPath
            pathFromMetadata = true
        } else if let metaBase {
            chosenBase = metaBase
            chosenPath = fallbackPath
            pathFromMetadata = false
        } else {
            chosenBase = fallbackBase
            chosenPath = fallbackPath
            pathFromMetadata = false
        }

        let qwenImagesNeedsNativeOrigin = providerKind == .qwen && kind == .images
        let effectiveBase = pathFromMetadata || qwenImagesNeedsNativeOrigin
            ? normalizeBaseForEndpoint(base: chosenBase, providerKind: providerKind, endpointPath: chosenPath)
            : chosenBase

        guard let url = joinURL(base: effectiveBase, path: chosenPath) else {
            throw EndpointResolutionError(
                providerKind: providerKind,
                endpoint: kind,
                reason: "Failed to join baseURL=\(effectiveBase) path=\(chosenPath)"
            )
        }
        return ResolvedEndpoint(baseURL: effectiveBase, path: chosenPath, url: url)
    }

    static func resolveBaseURL(
        provider: Provider,
        metadataTransport: MetadataClient.ProviderTransportDefinition?
    ) -> String {
        if let userBase = sanitize(provider.baseURLText) { return userBase }
        if let metaBase = validatedOfficialMetadataBaseURL(
            sanitize(metadataTransport?.baseUrl),
            providerKind: provider.kind
        ) {
            return metaBase
        }
        return fallbackBaseURL(for: provider.kind)
    }

    static func officialMetadataBaseURL(
        providerKind: ProviderKind,
        metadataTransport: MetadataClient.ProviderTransportDefinition?
    ) -> String? {
        validatedOfficialMetadataBaseURL(sanitize(metadataTransport?.baseUrl), providerKind: providerKind)
    }

 // MARK: - URL

    static func joinURL(base: String, path: String) -> URL? {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: trimmedBase + trimmedPath)
    }

 /// metadata `transport.baseUrl` + `endpoints.*` origin
 /// ( `https://api.deepseek.com` + `/v1/chat/completions`); /
 /// endpointPath metadata : fallback path base
 /// (qwen fallback base `/compatible-mode/v1`,path `/chat/completions`),
    private static func normalizeBaseForEndpoint(
        base: String,
        providerKind: ProviderKind,
        endpointPath: String
    ) -> String {
        let lowered = endpointPath.lowercased()
        guard !lowered.isEmpty, !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") else {
            return base
        }
        guard var components = URLComponents(string: base),
              components.scheme != nil,
              components.host != nil else {
            return base
        }

        let path = normalizedPathname(endpointPath)
        guard !path.isEmpty else { return base }

        let basePath = trimTrailingSlashes(components.path)
        guard !basePath.isEmpty else { return base }

        let stripToPrefix: String?
        let qwenCompatibleSuffix = "/compatible-mode/v1"
        if providerKind == .qwen, basePath.hasSuffix(qwenCompatibleSuffix) {
 // qwen :metadata DashScope path(`/api/v1/services/...`),
            stripToPrefix = String(basePath.dropLast(qwenCompatibleSuffix.count))
        } else if path == basePath || path.hasPrefix(basePath + "/") {
            stripToPrefix = ""
        } else {
            stripToPrefix = nil
        }
        guard let stripToPrefix else { return base }

        components.path = stripToPrefix
        components.query = nil
        components.fragment = nil
        return trimTrailingSlashes(components.string ?? base)
    }

    private static func normalizedPathname(_ path: String) -> String {
        var value = path
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[value.startIndex..<cut])
        }
        if !value.hasPrefix("/") { value = "/" + value }
        return trimTrailingSlashes(value)
    }

    private static func trimTrailingSlashes(_ value: String) -> String {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    private static func endpointPath(
        in endpoints: MetadataClient.TransportEndpoints?,
        kind: EndpointKind
    ) -> String? {
        guard let endpoints else { return nil }
        switch kind {
        case .chat: return endpoints.chat
        case .responses: return endpoints.responses
        case .images: return endpoints.images
        case .embeddings: return endpoints.embeddings
        case .files: return endpoints.files
        }
    }

    private static func validatedOfficialMetadataBaseURL(
        _ baseURL: String?,
        providerKind: ProviderKind
    ) -> String? {
        guard let baseURL else { return nil }
        guard providerKind != .relay, true else { return baseURL }
        guard let components = URLComponents(string: baseURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedMetadataBaseURLDomains(for: providerKind).contains(where: { allowed in
                  host == allowed || host.hasSuffix(".\(allowed)")
              }) else {
            return nil
        }
        return baseURL
    }

    private static func allowedMetadataBaseURLDomains(for kind: ProviderKind) -> Set<String> {
        switch kind {
        case .openAI: return ["openai.com"]
        case .anthropic: return ["anthropic.com"]
        case .gemini: return ["googleapis.com"]
        case .openRouter: return ["openrouter.ai"]
        case .deepseek: return ["deepseek.com"]
        case .grok: return ["x.ai"]
        case .groq: return ["groq.com"]
        case .together: return ["together.xyz"]
        case .fireworks: return ["fireworks.ai"]
        case .miniMax: return ["minimax.io"]
        case .zhipu: return ["bigmodel.cn"]
        case .qwen: return ["aliyuncs.com"]
        case .moonshot: return ["moonshot.ai", "moonshot.cn"]
        case .mistral: return ["mistral.ai"]
        case .siliconFlow: return ["siliconflow.cn", "siliconflow.com"]
        case .relay: return []
        }
    }

 // MARK: - fallback

    static func fallbackBaseURL(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .together: return "https://api.together.xyz/v1"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .miniMax: return "https://api.minimax.io/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen:
 // https://dashscope.aliyuncs.com https://dashscope-intl.aliyuncs.com
            return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .siliconFlow: return "https://api.siliconflow.cn/v1"
        case .relay:
            return ""
        }
    }

    static func fallbackEndpointPath(_ providerKind: ProviderKind, kind: EndpointKind) -> String {
        switch (providerKind, kind) {
        case (.anthropic, .chat): return "/messages"
        case (.anthropic, .files): return "/files"
        case (.gemini, .chat), (.gemini, .responses):
 // Gemini generateContent / streamGenerateContent,URL modelID
            return "/models"
        case (.gemini, .files): return "/files"
        case (.openAI, .chat): return "/chat/completions"
        case (.openAI, .responses): return "/responses"
        case (.openAI, .images): return "/images/generations"
        case (.openAI, .files): return "/files"
        case (.openRouter, .chat): return "/chat/completions"
        case (.qwen, .chat):
            return "/chat/completions"
        case (.qwen, .images):
            return "/api/v1/services/aigc/multimodal-generation/generation"
        case (.miniMax, .images):
            return "/image_generation"
        case (_, .chat): return "/chat/completions"
        case (_, .responses): return "/responses"
        case (_, .images): return "/images/generations"
        case (_, .embeddings): return "/embeddings"
        case (_, .files): return "/files"
        }
    }
}
