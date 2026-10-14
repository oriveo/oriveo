import Foundation

/// origin=`https://relay.example.com`,pathPrefix=`/proxy`,explicitVersion=`v1`.
struct RelayEndpointDescriptor: Equatable, Sendable {
    let normalizedInput: String
    let origin: String
    let pathPrefix: String
    let explicitVersion: String?
    let explicitTransport: RelayTransport?
    let containsEmbeddedQuery: Bool
    let containsFragment: Bool

    var hasExplicitTerminalRoute: Bool { explicitTransport != nil }
}

enum RelayEndpointCandidateEvidence: String, Codable, Sendable {
    case explicitRoute
    case explicitVersion
    case defaultVersion
    case alternateVersion
    case versionlessFallback
}

struct RelayEndpointCandidate: Equatable, Hashable, Sendable {
    let apiBaseURL: String
    let transport: RelayTransport
    let evidence: RelayEndpointCandidateEvidence
}

enum RelayEndpointResolver {
    nonisolated private static let knownVersions: Set<String> = ["v1", "v1beta"]

    nonisolated static func describe(_ raw: String) throws -> RelayEndpointDescriptor {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
            options: .regularExpression
        ) != nil
        let candidate = hasScheme ? trimmed : "https://\(trimmed)"
        guard var inputComponents = URLComponents(string: candidate),
              inputComponents.host?.isEmpty == false else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint.")
        }
        let containsEmbeddedQuery = inputComponents.query != nil
        let containsFragment = inputComponents.fragment?.isEmpty == false
        if !containsEmbeddedQuery,
           inputComponents.user != nil || inputComponents.password != nil {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint.")
        }
        inputComponents.user = nil
        inputComponents.password = nil
        inputComponents.query = nil
        inputComponents.fragment = nil
        guard let requestSafeInput = inputComponents.string else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint.")
        }
        let normalized = try RelayEndpointPolicy.requireSecure(requestSafeInput)
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme,
              let host = components.host else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint.")
        }

        components.query = nil
        components.fragment = nil

        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let explicitTransport = terminalTransportAndTrimmedSegments(&segments)
        let explicitVersion: String?
        if let last = segments.last?.lowercased(), knownVersions.contains(last) {
            explicitVersion = last
            segments.removeLast()
        } else {
            explicitVersion = nil
        }

        var originComponents = URLComponents()
        originComponents.scheme = scheme.lowercased()
        originComponents.host = host
        originComponents.port = components.port
        guard let origin = originComponents.url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint origin.")
        }

        let prefix = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        return RelayEndpointDescriptor(
            normalizedInput: normalized,
            origin: origin,
            pathPrefix: prefix,
            explicitVersion: explicitVersion,
            explicitTransport: explicitTransport,
            containsEmbeddedQuery: containsEmbeddedQuery,
            containsFragment: containsFragment
        )
    }

    nonisolated static func candidates(
        for descriptor: RelayEndpointDescriptor,
        transport: RelayTransport
    ) -> [RelayEndpointCandidate] {
        let versions = preferredVersions(for: transport)
        var result: [RelayEndpointCandidate] = []

        func append(version: String?, evidence: RelayEndpointCandidateEvidence) {
            let base = apiBaseURL(
                origin: descriptor.origin,
                prefix: descriptor.pathPrefix,
                version: version
            )
            guard !result.contains(where: { $0.apiBaseURL == base && $0.transport == transport }) else {
                return
            }
            result.append(.init(apiBaseURL: base, transport: transport, evidence: evidence))
        }

        if descriptor.hasExplicitTerminalRoute, descriptor.explicitVersion == nil {
            append(version: nil, evidence: .explicitRoute)
        }

        if let explicitVersion = descriptor.explicitVersion {
            append(
                version: explicitVersion,
                evidence: descriptor.hasExplicitTerminalRoute ? .explicitRoute : .explicitVersion
            )
        }

        for version in versions {
            append(
                version: version,
                evidence: descriptor.explicitVersion == nil ? .defaultVersion : .alternateVersion
            )
        }

        append(version: nil, evidence: .versionlessFallback)
        return result
    }

    static func endpointURL(
        apiBaseURL: String,
        endpointPath: String,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    ) throws -> URL {
        let secureBase = try RelayEndpointPolicy.requireConfigured(
            apiBaseURL,
            securityMode: securityMode
        )
        guard var components = URLComponents(string: secureBase) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay API root.")
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint path.")
        }
        return url
    }

    static func runtimeAPIBaseURL(
        rawBaseURL: String,
        relayRequested: RelayRequestedConfig?,
        defaultVersion: String,
        acceptedVersions: Set<String>
    ) throws -> String {
        let securityMode = relayRequested?.securityMode ?? .remoteHTTPS
        if let resolved = relayRequested?.resolvedAPIBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !resolved.isEmpty {
            return try RelayEndpointPolicy.requireConfigured(resolved, securityMode: securityMode)
        }

        let secureBase = try RelayEndpointPolicy.requireConfigured(rawBaseURL, securityMode: securityMode)
        guard let url = URL(string: secureBase) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(rawBaseURL)")
        }
        let segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments.contains(where: acceptedVersions.contains) {
            return secureBase
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [path, defaultVersion].filter { !$0.isEmpty }.joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        guard let resolved = components?.url?.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid base URL: \(rawBaseURL)")
        }
        return resolved
    }

    // MARK: - The single point that resolves a relay's protocol
    //
    // Sending, evidence, attachments, tools and the UI all take the protocol and root address of a (provider, model) from here.

    /// The protocol this model actually uses: the model's own protocol wins, otherwise it follows the connection default;
    /// when the connection default is `auto`, or the connection has no relay configuration, it falls back to `openai_chat_completions`.
    /// Pure function: no I/O and no write-back.
    nonisolated static func effectiveTransport(provider: Provider, model: AIModel) -> RelayTransport {
        if let own = model.relayTransport, own != .auto { return own }
        return defaultTransport(of: provider)
    }

    /// The API root this model actually uses. In order: the per-protocol table (a blank value counts as missing) -> the legacy single value
    /// `resolvedAPIBaseURL` (only when this protocol equals the connection default protocol) -> the connection address completed with the protocol's standard version
    /// (Gemini `v1beta`, nothing added for `llamacpp_native`, `v1` for the rest; an address that already has a version segment is used as is).
    /// Pure function: no I/O and no write-back; the security-mode check still happens where the request is built (`RelayEndpointPolicy`).
    nonisolated static func effectiveAPIRoot(provider: Provider, model: AIModel) -> String {
        let transport = effectiveTransport(provider: provider, model: model)
        let requested = provider.relayRequested
        if let exact = nonBlank(requested?.resolvedAPIBaseURLs?[transport.rawValue]) {
            return exact
        }
        if transport == defaultTransport(of: provider),
           let legacy = nonBlank(requested?.resolvedAPIBaseURL) {
            return legacy
        }
        return versionCompletedRoot(provider.baseURLText ?? "", transport: transport)
    }

    /// Returns the protocol once it is settled; returns nil when it is not (the model has no protocol of its own and the connection default is `auto` or there is no relay configuration).
    /// For callers that treat `auto` as an intent rather than a chosen protocol (evidence identity, tool decisions, the parameter panel);
    /// when settled it has the same value as `effectiveTransport`.
    nonisolated static func explicitTransport(provider: Provider, model: AIModel) -> RelayTransport? {
        if let own = model.relayTransport, own != .auto { return own }
        guard let requested = provider.relayRequested?.transport, requested != .auto else { return nil }
        return effectiveTransport(provider: provider, model: model)
    }

    /// The connection default protocol (`auto` or no configuration lands on Chat). Only for callers that are connection-level by nature:
    /// catalog sync, connection probes, connection-level analytics and screens with no model context.
    nonisolated static func connectionTransport(of provider: Provider) -> RelayTransport {
        defaultTransport(of: provider)
    }

    /// The raw protocol stored on the connection (`auto` is returned as is, no configuration counts as `auto`). Only for connection-level screens that must show "Auto" faithfully
    /// (the default-protocol row on the detail page); sending and evidence still go through `effectiveTransport`.
    nonisolated static func requestedConnectionTransport(of provider: Provider) -> RelayTransport {
        provider.relayRequested?.transport ?? .auto
    }

    /// The verified per-protocol root addresses: the per-protocol table plus the legacy single value (assigned to the connection default protocol, by the same rule as `effectiveAPIRoot`).
    /// Only protocols this version knows are accepted, and a blank value counts as missing.
    nonisolated static func verifiedAPIRoots(of provider: Provider) -> [RelayTransport: String] {
        verifiedAPIRoots(provider.relayRequested)
    }

    nonisolated private static func verifiedAPIRoots(_ requested: RelayRequestedConfig?) -> [RelayTransport: String] {
        var roots: [RelayTransport: String] = [:]
        for (raw, value) in requested?.resolvedAPIBaseURLs ?? [:] {
            guard let transport = RelayTransport(rawValue: raw), let root = nonBlank(value) else { continue }
            roots[transport] = root
        }
        let legacyTransport = defaultTransport(requested)
        if roots[legacyTransport] == nil, let legacy = nonBlank(requested?.resolvedAPIBaseURL) {
            roots[legacyTransport] = legacy
        }
        return roots
    }

    // MARK: - Address normalization in one place (fixture address-normalize.v1.json)

    /// The "Will request ..." preview on the add page: describe(input) strips the terminal route, then completes the version the same way as effectiveAPIRoot
    /// (an address whose path already has a v<N>[alpha|beta] segment is kept; otherwise the protocol's standard version is added). The protocol is the pasted terminal path's, otherwise Chat.
    /// Returns nil when no request-safe https address can be made (empty, userinfo, embedded query, http), and the UI hides the row.
    nonisolated static func previewAPIRoot(_ input: String) -> String? {
        guard let descriptor = try? describe(input), !descriptor.containsEmbeddedQuery else { return nil }
        let transport = descriptor.explicitTransport ?? .openaiChatCompletions
        return versionCompletedRoot(strippedRoot(descriptor), transport: transport)
    }

    /// The root address of every catalog GET (the URL is this plus `/models`): the connection protocol's verified root wins (taken the same way as the model-less
    /// `effectiveAPIRoot`); otherwise the connection address with the terminal route stripped, completed with the connection protocol's version (same rule as `previewAPIRoot`).
    nonisolated static func catalogAPIRoot(provider: Provider) -> String? {
        catalogAPIRoot(baseURL: provider.baseURLText, relayRequested: provider.relayRequested)
    }

    /// The same rule for the service layer, which only receives an address and the request configuration (`OpenAIService.syncProvider`).
    nonisolated static func catalogAPIRoot(baseURL: String?, relayRequested: RelayRequestedConfig?) -> String? {
        let transport = defaultTransport(relayRequested)
        if let verified = verifiedAPIRoots(relayRequested)[transport] {
            return verified
        }
        guard let baseURL, let descriptor = try? describe(baseURL) else { return nil }
        return versionCompletedRoot(strippedRoot(descriptor), transport: transport)
    }

    /// The address after describe strips the terminal route (the proxy prefix and any version segment already written are kept); the version has not been completed yet.
    nonisolated private static func strippedRoot(_ descriptor: RelayEndpointDescriptor) -> String {
        apiBaseURL(origin: descriptor.origin, prefix: descriptor.pathPrefix, version: descriptor.explicitVersion)
    }

    /// The injection point for sending (ChatManager): hands the service a copy of the connection configuration overridden with this model's protocol and root address.
    /// A stored connection (the model has no protocol of its own and the per-protocol root table does not have this protocol either) gets the connection configuration back unchanged:
    /// the outbound address, evidence identity and parameter partition key are byte for byte what they were before per-model routing.
    /// Otherwise the protocol is overridden only when it differs from the connection default, and the root address is written as `effectiveAPIRoot`, which the service
    /// uses as is through `runtimeAPIBaseURL` without completing the version again. The copy only flows through this request and is never written back to the provider.
    nonisolated static func routedRequested(provider: Provider, model: AIModel) -> RelayRequestedConfig? {
        guard var copy = provider.relayRequested else { return nil }
        guard hasModelLevelRoute(provider: provider, model: model) else { return copy }
        let transport = effectiveTransport(provider: provider, model: model)
        if transport != defaultTransport(of: provider) {
            copy.transport = transport
        }
        let root = effectiveAPIRoot(provider: provider, model: model)
        if nonBlank(root) != nil {
            copy.resolvedAPIBaseURL = root
        }
        return copy
    }

    /// The model has a protocol of its own, or the connection's per-protocol root table has the protocol this model should use.
    nonisolated static func hasModelLevelRoute(provider: Provider, model: AIModel) -> Bool {
        if let own = model.relayTransport, own != .auto { return true }
        let transport = effectiveTransport(provider: provider, model: model)
        return nonBlank(provider.relayRequested?.resolvedAPIBaseURLs?[transport.rawValue]) != nil
    }

    /// The single entry point for the service layer to read the protocol. The send path passes a copy from `routedRequested` (already this model's protocol);
    /// connection-level calls (catalog sync, connection probes) pass the connection configuration itself, so what is read is the connection default.
    nonisolated static func injectedTransport(_ requested: RelayRequestedConfig?) -> RelayTransport? {
        requested?.transport
    }

    /// The entry point for the service layer to read the injected root address (the same copy as `injectedTransport`); the raw value passes through, read exactly as before per-model routing.
    nonisolated static func injectedAPIRoot(_ requested: RelayRequestedConfig?) -> String? {
        requested?.resolvedAPIBaseURL
    }

    /// Writes the root address found by catalog / generation-route discovery into the connection: when the discovered protocol equals the connection's actual default protocol
    /// (`auto` means Chat) the legacy single-value field is written, otherwise only `resolvedAPIBaseURLs[discovered protocol]` is written and the legacy field is left alone.
    /// The connection protocol itself does not change.
    nonisolated static func recordDiscoveredRoot(
        _ root: String,
        discovered: RelayTransport,
        into config: inout RelayRequestedConfig
    ) {
        let actualDefault = config.transport == .auto ? RelayTransport.openaiChatCompletions : config.transport
        if discovered == actualDefault {
            config.resolvedAPIBaseURL = root
        } else {
            var roots = config.resolvedAPIBaseURLs ?? [:]
            roots[discovered.rawValue] = root
            config.resolvedAPIBaseURLs = roots
        }
    }

    /// The connection-level root address for display / fingerprints: the single root the probe wrote back, otherwise the connection address as typed (raw value, whitespace not trimmed).
    nonisolated static func connectionAPIRootText(of provider: Provider) -> String? {
        provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText
    }

    /// The root address used by the generation-parameter fingerprint: a stored connection (`hasModelLevelRoute` is false) keeps the same input as before the change,
    /// `resolvedAPIBaseURL ?? baseURLText`, so the fingerprint is unchanged character for character; with a model-level route it uses `effectiveAPIRoot`.
    nonisolated static func fingerprintAPIRoot(provider: Provider, model: AIModel) -> String {
        guard hasModelLevelRoute(provider: provider, model: model) else {
            return connectionAPIRootText(of: provider) ?? ""
        }
        return effectiveAPIRoot(provider: provider, model: model)
    }

    /// Completes a connection address with the protocol's standard version (official providers dispatched by protocol use it too).
    nonisolated static func versionCompletedAPIRoot(_ rawBaseURL: String, transport: RelayTransport) -> String {
        versionCompletedRoot(rawBaseURL, transport: transport)
    }

    nonisolated private static func defaultTransport(of provider: Provider) -> RelayTransport {
        defaultTransport(provider.relayRequested)
    }

    nonisolated private static func defaultTransport(_ requested: RelayRequestedConfig?) -> RelayTransport {
        guard let transport = requested?.transport, transport != .auto else {
            return .openaiChatCompletions
        }
        return transport
    }

    nonisolated private static func nonBlank(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// String operations only (no parsing, no scheme check), so a connection address written without a scheme does not throw here.
    nonisolated private static func versionCompletedRoot(_ rawBaseURL: String, transport: RelayTransport) -> String {
        var root = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = root.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            root = String(root[..<cut])
        }
        while root.hasSuffix("/") { root.removeLast() }

        let afterScheme = root.range(of: "://").map { String(root[$0.upperBound...]) } ?? root
        let pathSegments = afterScheme.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        // If any path segment is already a version segment (v1 / v1beta / v4 / v2alpha ...), use it as is and do not stack another one (fixture address-normalize.v1.json).
        if pathSegments.contains(where: { isVersionSegment(String($0)) }) {
            return root
        }
        guard let version = preferredVersions(for: transport).first else { return root }
        return root + "/" + version
    }

    nonisolated private static func isVersionSegment(_ segment: String) -> Bool {
        segment.lowercased().wholeMatch(of: /v\d+(alpha|beta)?/) != nil
    }

    nonisolated private static func preferredVersions(for transport: RelayTransport) -> [String] {
        switch transport {
        case .llamacppNative:
            return []
        case .geminiGenerateContent:
            return ["v1beta", "v1"]
        case .openaiChatCompletions, .openaiResponses, .anthropicMessages, .auto:
            return ["v1"]
        }
    }

    nonisolated private static func apiBaseURL(origin: String, prefix: String, version: String?) -> String {
        let parts = [
            prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            version ?? ""
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? origin : origin + "/" + parts.joined(separator: "/")
    }

    nonisolated private static func terminalTransportAndTrimmedSegments(
        _ segments: inout [String]
    ) -> RelayTransport? {
        guard !segments.isEmpty else { return nil }
        let lower = segments.map { $0.lowercased() }

        if lower.count >= 2,
           lower[lower.count - 2] == "chat",
           lower.last == "completions" {
            segments.removeLast(2)
            return .openaiChatCompletions
        }
        if lower.last == "responses" {
            segments.removeLast()
            return .openaiResponses
        }
        if lower.last == "messages" {
            segments.removeLast()
            return .anthropicMessages
        }
        if lower.count >= 2,
           lower[lower.count - 2] == "models",
           let last = lower.last,
           last.contains(":generatecontent") || last.contains(":streamgeneratecontent") {
            segments.removeLast(2)
            return .geminiGenerateContent
        }
        if lower.last == "models" {
            segments.removeLast()
        }
        return nil
    }
}
