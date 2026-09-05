import Foundation

struct OpenAISubscriptionAuthConfig: Sendable, Equatable {
    let clientID: String
    let deviceAuthorizationEndpoint: URL
    let deviceTokenEndpoint: URL
    let tokenEndpoint: URL
    let verificationURL: URL
    let redirectURI: URL
    let trustedVerificationHosts: [String]
    let resourceBaseURL: URL
    let requiredHeaders: [String: String]
    let modelsPath: String
    let chatPath: String
    let pollIntervalSeconds: Int
    let pollTimeoutSeconds: Int

    var modelsURL: URL? {
        EndpointResolver.joinURL(base: resourceBaseURL.absoluteString, path: modelsPath)
    }

    var responsesURL: URL? {
        EndpointResolver.joinURL(base: resourceBaseURL.absoluteString, path: chatPath)
    }

    func allowsVerificationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased()
        else { return false }
        return trustedVerificationHosts.contains { trusted in
            host == trusted || host.hasSuffix("." + trusted)
        }
    }
}

struct OpenAISubscriptionRequestContext: Hashable, Sendable {
    let responsesURL: URL
    let accountID: String
    let requiredHeaders: [String: String]
}

enum OpenAISubscriptionAvailability: Sendable, Equatable {
    case available(OpenAISubscriptionAuthConfig)
    case disabled(notice: String?)
    case unavailable
}

enum OpenAISubscriptionAuthResolver {
    static func resolve(
        raw: MetadataClient.RawGrokSubscriptionAuth?,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    ) -> OpenAISubscriptionAvailability {
        guard let raw, raw.flow == "codex_device_code" else { return .unavailable }
        guard raw.enabled == true else { return .disabled(notice: raw.disabledNotice) }
        if let minimum = raw.minAppVersion?["ios"],
           GrokSubscriptionAuthResolver.compareVersions(appVersion, minimum) < 0 {
            return .disabled(notice: raw.disabledNotice)
        }

        let trustedAuthHosts = (raw.trustedAuthHosts ?? []).map { $0.lowercased() }
        guard let clientID = nonempty(raw.clientId),
              !trustedAuthHosts.isEmpty,
              let deviceAuthorizationEndpoint = trustedURL(raw.deviceAuthorizationEndpoint, hosts: trustedAuthHosts),
              let deviceTokenEndpoint = trustedURL(raw.deviceTokenEndpoint, hosts: trustedAuthHosts),
              let tokenEndpoint = trustedURL(raw.tokenEndpoint, hosts: trustedAuthHosts),
              let verificationURL = trustedURL(raw.verificationURL, hosts: raw.trustedVerificationHosts ?? []),
              let redirectURI = trustedURL(raw.redirectURI, hosts: trustedAuthHosts),
              let resourceBaseURL = httpsURL(raw.resourceBaseURL),
              let resourceHost = resourceBaseURL.host?.lowercased(),
              resourceHost == "chatgpt.com"
        else { return .unavailable }

        return .available(OpenAISubscriptionAuthConfig(
            clientID: clientID,
            deviceAuthorizationEndpoint: deviceAuthorizationEndpoint,
            deviceTokenEndpoint: deviceTokenEndpoint,
            tokenEndpoint: tokenEndpoint,
            verificationURL: verificationURL,
            redirectURI: redirectURI,
            trustedVerificationHosts: (raw.trustedVerificationHosts ?? []).map { $0.lowercased() },
            resourceBaseURL: resourceBaseURL,
            requiredHeaders: raw.requiredHeaders ?? [:],
            modelsPath: normalizedPath(raw.modelsPath, fallback: "/models"),
            chatPath: normalizedPath(raw.chatPath, fallback: "/responses"),
            pollIntervalSeconds: max(1, raw.pollIntervalSeconds ?? 5),
            pollTimeoutSeconds: max(60, raw.pollTimeoutSeconds ?? 900)
        ))
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPath(_ value: String?, fallback: String) -> String {
        guard let value = nonempty(value) else { return fallback }
        return value.hasPrefix("/") ? value : "/" + value
    }

    private static func trustedURL(_ value: String?, hosts: [String]) -> URL? {
        guard let url = httpsURL(value), let host = url.host?.lowercased() else { return nil }
        let normalizedHosts = hosts.map { $0.lowercased() }
        guard normalizedHosts.contains(host) else { return nil }
        return url
    }

    private static func httpsURL(_ value: String?) -> URL? {
        guard let value = nonempty(value), let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil, url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

struct OpenAISubscriptionTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date?
    let accountID: String
    let planType: String?
    let obtainedAt: Date

    func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= 300
    }
}

struct OpenAIDeviceAuthorization: Sendable, Equatable {
    let deviceAuthID: String
    let userCode: String
    let verificationURL: URL
    let interval: Int
    let expiresIn: Int
}

enum OpenAISubscriptionError: Error, Equatable, Sendable {
    case authorizationPending
    case slowDown
    case codeExpired
    case accessDenied
    case clientVersionRejected
    case subscriptionNotEligible
    case unauthorized
    case quotaExhausted
    case configurationUnavailable
    case transport(String)
    case upstream(status: Int, body: String)

    var userFacingMessage: String { L10n.tr(userFacingMessageKey, table: .providers) }

    var userFacingMessageKey: String {
        switch self {
        case .clientVersionRejected, .configurationUnavailable:
            return "ChatGPT subscription sign-in is temporarily unavailable while we update it. You can connect with an API key instead."
        case .subscriptionNotEligible:
            return "Your ChatGPT account's current plan doesn't allow using Codex in third-party apps."
        case .unauthorized:
            return "Your ChatGPT sign-in has expired. Please authorize again."
        case .quotaExhausted:
            return "You've used up this period's Codex quota. It will resume after the next reset."
        case .codeExpired:
            return "The authorization code expired. Please start again."
        case .accessDenied:
            return "Authorization was declined."
        case .authorizationPending, .slowDown:
            return "Waiting for authorization in your browser…"
        case .transport:
            return "Couldn't reach Codex. Check your connection and try again."
        case .upstream:
            return "Codex returned an unexpected response. Please try again."
        }
    }


    var requiresConfigRefresh: Bool {
        self == .clientVersionRejected
    }

    var allowsRetry: Bool {
        switch self {
        case .codeExpired, .accessDenied, .transport, .upstream, .authorizationPending, .slowDown:
            return true
        case .clientVersionRejected, .subscriptionNotEligible, .unauthorized, .quotaExhausted,
             .configurationUnavailable:
            return false
        }
    }
}

enum OpenAIJWTClaims {
    static func string(_ token: String, claim: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let value = object[claim] as? String { return value }
        if let auth = object["https://api.openai.com/auth"] as? [String: Any] {
            return auth[claim] as? String
        }
        return nil
    }

    static func expiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = object["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: expiration)
    }
}
