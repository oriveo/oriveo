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

// MARK: - Relay 2.0 model-level fields

/// Who decided the model-level protocol. Meaningful only when `AIModel.relayTransport` is non-nil.
/// `reachable` = a 1-token probe passed; `observed` = a real send succeeded; `user` = the user picked it by hand.
/// Old values `gateway` / `facts` / `probed` are unknown on decode, so the protocol and source are dropped together (follow the connection).
nonisolated enum RelayTransportSource: String, Codable, Hashable, Sendable, CaseIterable {
    case user
    case observed
    case reachable
}

/// Override of a single model capability. The wire shape is `{key: {value, source}}`, and `source` accepts only `user` / `tested`.
///
/// Decoding is tolerant item by item: an unknown key, an unknown `source` or a `value` of the wrong shape is dropped on its own,
/// so one bad item never drags down the whole table, let alone fails the whole model decode.
nonisolated struct RelayCapabilityOverrides: Hashable, Sendable, Codable {
    /// `CaseIterable` is deliberate: the cross-platform fixture `modelFields.capabilityOverrideKeys` reconciles against it.
    enum Key: String, CodingKey, CaseIterable {
        case image, file, imageGeneration, toolCall, reasoningLevels, web
    }

    /// `CaseIterable` is deliberate: the cross-platform fixture `modelFields.capabilityOverrideSources` reconciles against it.
    enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        case user, tested
    }

    var image: Bool?
    var file: Bool?
    var imageGeneration: Bool?
    var toolCall: Bool?
    var reasoningLevels: [String]?
    /// Relay web search: written as `tested` only by the web probe, or set by the user.
    var web: Bool?
    /// The source of each item; encoded as `user` when absent.
    var sources: [Key: Source] = [:]

    init(
        image: Bool? = nil,
        file: Bool? = nil,
        imageGeneration: Bool? = nil,
        toolCall: Bool? = nil,
        reasoningLevels: [String]? = nil,
        web: Bool? = nil,
        source: Source = .user
    ) {
        self.image = image
        self.file = file
        self.imageGeneration = imageGeneration
        self.toolCall = toolCall
        self.reasoningLevels = reasoningLevels
        self.web = web
        for key in Key.allCases where hasValue(for: key) {
            sources[key] = source
        }
    }

    private func hasValue(for key: Key) -> Bool {
        switch key {
        case .image: image != nil
        case .file: file != nil
        case .imageGeneration: imageGeneration != nil
        case .toolCall: toolCall != nil
        case .reasoningLevels: reasoningLevels != nil
        case .web: web != nil
        }
    }

    var isEmpty: Bool {
        image == nil && file == nil && imageGeneration == nil && toolCall == nil && reasoningLevels == nil && web == nil
    }

    /// The value of the five boolean keys; `reasoningLevels` is not a boolean and is always nil.
    func value(for key: Key) -> Bool? {
        switch key {
        case .image: image
        case .file: file
        case .imageGeneration: imageGeneration
        case .toolCall: toolCall
        case .web: web
        case .reasoningLevels: nil
        }
    }

    /// Writes one boolean key; nil removes the source along with the value. `reasoningLevels` does not go through here.
    mutating func setValue(_ value: Bool?, for key: Key, source: Source) {
        switch key {
        case .image: image = value
        case .file: file = value
        case .imageGeneration: imageGeneration = value
        case .toolCall: toolCall = value
        case .web: web = value
        case .reasoningLevels: return
        }
        sources[key] = value == nil ? nil : source
    }

    private struct Entry<Value: Codable>: Codable {
        let value: Value
        let source: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        image = Self.decodeEntry(in: c, for: .image, sources: &sources)
        file = Self.decodeEntry(in: c, for: .file, sources: &sources)
        imageGeneration = Self.decodeEntry(in: c, for: .imageGeneration, sources: &sources)
        toolCall = Self.decodeEntry(in: c, for: .toolCall, sources: &sources)
        reasoningLevels = Self.decodeEntry(in: c, for: .reasoningLevels, sources: &sources)
        web = Self.decodeEntry(in: c, for: .web, sources: &sources)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try encodeEntry(image, into: &c, for: .image)
        try encodeEntry(file, into: &c, for: .file)
        try encodeEntry(imageGeneration, into: &c, for: .imageGeneration)
        try encodeEntry(toolCall, into: &c, for: .toolCall)
        try encodeEntry(reasoningLevels, into: &c, for: .reasoningLevels)
        try encodeEntry(web, into: &c, for: .web)
    }

    private static func decodeEntry<Value: Codable>(
        in container: KeyedDecodingContainer<Key>,
        for key: Key,
        sources: inout [Key: Source]
    ) -> Value? {
        guard let entry = try? container.decodeIfPresent(Entry<Value>.self, forKey: key),
              let source = Source(rawValue: entry.source) else { return nil }
        sources[key] = source
        return entry.value
    }

    private func encodeEntry<Value: Codable>(
        _ value: Value?,
        into container: inout KeyedEncodingContainer<Key>,
        for key: Key
    ) throws {
        guard let value else { return }
        let source = sources[key] ?? .user
        try container.encode(Entry(value: value, source: source.rawValue), forKey: key)
    }
}

/// A local engine's capability declaration for a single model. Written only by the local engine connector and stored only on this device.
///
/// Every key is an optional boolean: a missing key = unknown (left to the relay's unknown-capability rule), not "unsupported".
/// Decoding is tolerant key by key: an unknown key or a non-boolean value is dropped on its own and never fails the whole model decode.
nonisolated struct EngineDeclaration: Hashable, Sendable, Codable {
    /// `CaseIterable` is deliberate: the cross-platform fixture `modelFields.engineDeclarationKeys` reconciles against it.
    enum Key: String, CodingKey, CaseIterable {
        case image, toolCall, thinking
    }

    var image: Bool?
    var toolCall: Bool?
    var thinking: Bool?

    init(image: Bool? = nil, toolCall: Bool? = nil, thinking: Bool? = nil) {
        self.image = image
        self.toolCall = toolCall
        self.thinking = thinking
    }

    var isEmpty: Bool {
        image == nil && toolCall == nil && thinking == nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        image = (try? c.decodeIfPresent(Bool.self, forKey: .image)) ?? nil
        toolCall = (try? c.decodeIfPresent(Bool.self, forKey: .toolCall)) ?? nil
        thinking = (try? c.decodeIfPresent(Bool.self, forKey: .thinking)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(toolCall, forKey: .toolCall)
        try c.encodeIfPresent(thinking, forKey: .thinking)
    }
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

    /// Infers the relay kind from the connection config (no config is treated as `auto`).
    init(requested: RelayRequestedConfig?) {
        self.init(transport: requested?.transport ?? .auto)
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
    /// Names the web search shape this relay's upstream speaks, for example `ant_web_tool`,
    /// `gem_web`, `grok_responses_web`, `qwen_web`, `zhipu_web`, `or_web` or `kimi_web_search`.
    var webSearchProfile: String?
    /// Wire protocol the relay speaks, for example `openai_chat_completions`, `openai_responses`,
    /// `anthropic_messages` or `gemini_generate_content`.
    var transportKind: String?
    var resolvedAPIBaseURL: String?
    /// Exact API roots stored per protocol (Relay 2.0): the keys are the wire values of `RelayTransport`.
    /// This device keeps the keys it read as they are (including protocols this version does not know); the outbound copy keeps only known protocols.
    /// Reads go only through `RelayEndpointResolver.effectiveAPIRoot(provider:model:)`.
    var resolvedAPIBaseURLs: [String: String]?
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
        resolvedAPIBaseURLs: [String: String]? = nil,
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
        self.resolvedAPIBaseURLs = resolvedAPIBaseURLs
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
        // Relay 2.0
        case resolvedAPIBaseURLs
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
        // Tolerant via try?: a malformed table drops only itself and never fails the whole config decode; the keys are strings, so unknown protocols are kept.
        self.resolvedAPIBaseURLs = (try? c.decodeIfPresent([String: String].self, forKey: .resolvedAPIBaseURLs)) ?? nil
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
        try c.encodeIfPresent(resolvedAPIBaseURLs, forKey: .resolvedAPIBaseURLs)
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
        "resolvedAPIBaseURL", "resolvedAPIBaseURLs", "engineProfile",
    ]

    /// Drops the model used for probing: a relay has no default model, so neither persistence nor sync writes modelID.
    nonisolated var withoutModelID: RelayRequestedConfig {
        var copy = self
        copy.modelID = nil
        return copy
    }

    /// For landing a remote copy: a remote copy never carries the four device-only items, so they are filled back from the local values (Android / Web merge remote copies the same way).
    nonisolated func keepingLocalOnlyFields(from local: RelayRequestedConfig?) -> RelayRequestedConfig {
        var copy = self
        copy.headers = local?.headers
        copy.queryParams = local?.queryParams
        copy.customUserAgent = local?.customUserAgent
        copy.certificateFingerprint = local?.certificateFingerprint
        return copy
    }

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
        copy.resolvedAPIBaseURL = Self.credentialFreeAPIRoot(resolvedAPIBaseURL)
        copy.resolvedAPIBaseURLs = Self.credentialFreeEndpoints(resolvedAPIBaseURLs)
        copy.engineProfile = engineProfile
        return copy
    }

    /// Outbound cleaning for the per-protocol root table: keeps only entries whose key is a known protocol
    /// (`auto` is not a landable protocol) and whose value parses; values go through the same cleaner as the single root,
    /// and the whole key is omitted when nothing is left.
    nonisolated static func credentialFreeEndpoints(_ raw: [String: String]?) -> [String: String]? {
        guard let raw else { return nil }
        var cleaned: [String: String] = [:]
        for (key, value) in raw {
            guard let transport = RelayTransport(rawValue: key), transport != .auto,
                  let endpoint = credentialFreeAPIRoot(value) else { continue }
            cleaned[key] = endpoint
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Outbound cleaning for an exact API root: on top of `credentialFreeEndpoint` it requires both a scheme and a host.
    /// On newer systems `URLComponents(string:)` percent-escapes `not a URL` into a relative path instead of failing,
    /// so it alone cannot tell "unparseable"; a root written by a probe always has a scheme and a host.
    nonisolated static func credentialFreeAPIRoot(_ raw: String?) -> String? {
        guard let raw, let components = URLComponents(string: raw),
              components.scheme?.isEmpty == false, components.host?.isEmpty == false else { return nil }
        return credentialFreeEndpoint(raw)
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

// MARK: - Decoding point for the legacy web search declaration
//
// `hasWebSearch` / `webSearchProfile` are read and written only in this file: the fields, coding, the outbound
// allowlist, the read-time mapping, carrying them over on edit, and clearing them when the web settings page saves.
// Every other file goes through the functions here.

extension RelayRequestedConfig {
    /// The protocol each legacy profile belongs to (fixture `profileTransport`).
    nonisolated static let legacyWebProfileTransport: [String: RelayTransport] = [
        "oai_responses_web": .openaiResponses,
        "grok_responses_web": .openaiResponses,
        "ant_web_tool": .anthropicMessages,
        "gem_web": .geminiGenerateContent,
        "gem_web_retrieval": .geminiGenerateContent,
        "or_web": .openaiChatCompletions,
        "qwen_web": .openaiChatCompletions,
        "zhipu_web": .openaiChatCompletions,
        "oai_web_tool": .openaiChatCompletions,
        "kimi_web_search": .openaiChatCompletions,
    ]

    /// Read-time mapping of a stored `hasWebSearch == true` (fixture `legacyCases`); the result is not written back.
    /// `profiles` = metadata `profiles.webSearch[<name>].mergeParams`; fetched only when an old marker really exists (the badge calls this per model).
    nonisolated func legacyWebFragments(profiles: () -> [String: [String: Any]]) -> [String: [String: Any]] {
        guard hasWebSearch == true else { return [:] }
        let profile = webSearchProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profile.isEmpty, let mergeParams = profiles()[profile] {
            // Metadata has this profile but we do not know which protocol it belongs to: do not map it.
            guard let transport = Self.legacyWebProfileTransport[profile] else { return [:] }
            // Kimi needs a tool loop to search, so a single fragment is useless.
            guard profile != "kimi_web_search" else { return [:] }
            var fragment = mergeParams
            for key in RelayWebFragments.forbiddenTopLevelKeys { fragment[key] = nil }
            return fragment.isEmpty ? [:] : [transport.rawValue: fragment]
        }
        // No profile (or metadata does not have it): the only builders that can send web search today are Responses and Gemini.
        var out: [String: [String: Any]] = [
            RelayTransport.geminiGenerateContent.rawValue: ["tools": [["googleSearch": [String: Any]()]]],
        ]
        if webSearchToolName != .disabled {
            let toolType = (webSearchToolName ?? .webSearch).rawValue
            out[RelayTransport.openaiResponses.rawValue] = ["tools": [["type": toolType]]]
        }
        return out
    }

    /// When editing a connection, carries the two legacy fields over to the new config unchanged (the UI no longer has an entry for them, and a single save must not clear them).
    nonisolated func carryingLegacyWebSearch(from previous: RelayRequestedConfig?) -> RelayRequestedConfig {
        var copy = self
        copy.hasWebSearch = previous?.hasWebSearch
        copy.webSearchProfile = previous?.webSearchProfile
        return copy
    }

    /// Saving from the web settings page: from then on only the stored fragments are trusted.
    nonisolated func clearingLegacyWebSearch() -> RelayRequestedConfig {
        var copy = self
        copy.hasWebSearch = nil
        copy.webSearchProfile = nil
        return copy
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
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
                resolvedAPIBaseURLs: preserve?.resolvedAPIBaseURLs
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
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
                resolvedAPIBaseURLs: preserve?.resolvedAPIBaseURLs
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
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
                resolvedAPIBaseURLs: preserve?.resolvedAPIBaseURLs
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
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
                resolvedAPIBaseURLs: preserve?.resolvedAPIBaseURLs
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
                resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
                resolvedAPIBaseURLs: preserve?.resolvedAPIBaseURLs
            )
        }
    }
}
