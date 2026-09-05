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
    private static let knownVersions: Set<String> = ["v1", "v1beta"]

    static func describe(_ raw: String) throws -> RelayEndpointDescriptor {
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

    static func candidates(
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

    private static func preferredVersions(for transport: RelayTransport) -> [String] {
        switch transport {
        case .llamacppNative:
            return []
        case .geminiGenerateContent:
            return ["v1beta", "v1"]
        case .openaiChatCompletions, .openaiResponses, .anthropicMessages, .auto:
            return ["v1"]
        }
    }

    private static func apiBaseURL(origin: String, prefix: String, version: String?) -> String {
        let parts = [
            prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            version ?? ""
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? origin : origin + "/" + parts.joined(separator: "/")
    }

    private static func terminalTransportAndTrimmedSegments(
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
