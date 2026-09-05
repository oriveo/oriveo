import Foundation

struct GrokSubscriptionAuthConfig: Sendable, Equatable {
    let clientID: String
    let scopes: String
    let deviceAuthorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
    let trustedVerificationHosts: [String]
    let resourceBaseURL: URL
    let requiredHeaders: [String: String]
    let modelsPath: String
    let chatPath: String
    let responsesPath: String
    let apiBackend: String?
    let pollIntervalSeconds: Int
    let pollTimeoutSeconds: Int

    var modelsURL: URL? {
        EndpointResolver.joinURL(base: resourceBaseURL.absoluteString, path: modelsPath)
    }

    var chatURL: URL? {
        EndpointResolver.joinURL(base: resourceBaseURL.absoluteString, path: chatPath)
    }

    var responsesURL: URL? {
        EndpointResolver.joinURL(base: resourceBaseURL.absoluteString, path: responsesPath)
    }

    static func transportKind(apiBackend raw: String?) -> TransportKind? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "responses": return .openaiResponses
        case "chat", "chat_completions", "chat.completions": return .openaiChat
        default: return nil
        }
    }

    func allowsVerificationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        return trustedVerificationHosts.contains { trusted in
            let normalized = trusted.lowercased()
            return host == normalized || host.hasSuffix("." + normalized)
        }
    }
}

struct GrokSubscriptionRequestContext: Hashable, Sendable {
    let chatURL: URL
    let responsesURL: URL?
    let requiredHeaders: [String: String]
    let transport: String

    init(
        chatURL: URL,
        responsesURL: URL? = nil,
        requiredHeaders: [String: String],
        transport: String = TransportKind.openaiChat.rawValue
    ) {
        self.chatURL = chatURL
        self.responsesURL = responsesURL
        self.requiredHeaders = requiredHeaders
        self.transport = transport
    }

    var usesResponses: Bool { transport == TransportKind.openaiResponses.rawValue }

    func withTransport(_ transport: String) -> GrokSubscriptionRequestContext {
        GrokSubscriptionRequestContext(
            chatURL: chatURL, responsesURL: responsesURL,
            requiredHeaders: requiredHeaders, transport: transport
        )
    }
}

enum GrokSubscriptionAvailability: Sendable, Equatable {
    case available(GrokSubscriptionAuthConfig)
    case disabled(notice: String?)
    case unavailable
}

enum GrokSubscriptionAuthResolver {
    static func resolve(
        raw: MetadataClient.RawGrokSubscriptionAuth?,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    ) -> GrokSubscriptionAvailability {
        guard let raw else { return .unavailable }

        guard raw.flow == "oauth_device_code" else { return .unavailable }

        guard raw.enabled == true else { return .disabled(notice: raw.disabledNotice) }

        if let minimum = raw.minAppVersion?["ios"], !minimum.isEmpty,
           compareVersions(appVersion, minimum) < 0 {
            return .disabled(notice: raw.disabledNotice)
        }

        guard let clientID = raw.clientId, !clientID.isEmpty,
              let scopes = raw.scopes, !scopes.isEmpty,
              let resourceBaseURL = normalizedHTTPSURL(raw.resourceBaseURL)
        else { return .unavailable }

        let trustedAuthHosts = (raw.trustedAuthHosts ?? []).map { $0.lowercased() }
        guard !trustedAuthHosts.isEmpty,
              let deviceEndpoint = trustedHTTPSURL(raw.deviceAuthorizationEndpoint, hosts: trustedAuthHosts),
              let tokenEndpoint = trustedHTTPSURL(raw.tokenEndpoint, hosts: trustedAuthHosts)
        else { return .unavailable }

        let verificationHosts = raw.trustedVerificationHosts ?? []
        guard !verificationHosts.isEmpty else { return .unavailable }

        return .available(
            GrokSubscriptionAuthConfig(
                clientID: clientID,
                scopes: scopes,
                deviceAuthorizationEndpoint: deviceEndpoint,
                tokenEndpoint: tokenEndpoint,
                revocationEndpoint: trustedHTTPSURL(raw.revocationEndpoint, hosts: trustedAuthHosts),
                trustedVerificationHosts: verificationHosts,
                resourceBaseURL: resourceBaseURL,
                requiredHeaders: raw.requiredHeaders ?? [:],
                modelsPath: Self.normalizedPath(raw.modelsPath, fallback: "/models"),
                chatPath: Self.normalizedPath(raw.chatPath, fallback: "/chat/completions"),
                responsesPath: Self.normalizedPath(raw.responsesPath, fallback: "/responses"),
                apiBackend: raw.apiBackend?.trimmingCharacters(in: .whitespacesAndNewlines),
                pollIntervalSeconds: max(1, raw.pollIntervalSeconds ?? 5),
                pollTimeoutSeconds: max(60, raw.pollTimeoutSeconds ?? 1800)
            )
        )
    }

    private static func normalizedPath(_ raw: String?, fallback: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func trustedHTTPSURL(_ raw: String?, hosts: [String]) -> URL? {
        guard let url = normalizedHTTPSURL(raw), let host = url.host?.lowercased() else { return nil }
        guard hosts.contains(host) else { return nil }
        return url
    }

    private static func normalizedHTTPSURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
