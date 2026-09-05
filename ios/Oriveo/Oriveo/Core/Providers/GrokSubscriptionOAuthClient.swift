import Foundation

struct GrokDeviceAuthorization: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: Int
    let interval: Int?
}

struct GrokSubscriptionTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: String?
    var obtainedAt: Date

    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}

enum GrokSubscriptionError: Error, Equatable {
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
}

struct GrokSubscriptionOAuthClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func requestDeviceAuthorization(
        config: GrokSubscriptionAuthConfig
    ) async throws -> GrokDeviceAuthorization {
        var request = URLRequest(url: config.deviceAuthorizationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "client_id": config.clientID,
            "scope": config.scopes
        ])

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }

        guard let payload = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data),
              let verificationRaw = payload.verification_uri_complete ?? payload.verification_uri,
              let verificationURL = URL(string: verificationRaw),
              config.allowsVerificationURL(verificationURL)
        else {
            throw GrokSubscriptionError.configurationUnavailable
        }

        return GrokDeviceAuthorization(
            deviceCode: payload.device_code,
            userCode: payload.user_code,
            verificationURL: verificationURL,
            expiresIn: payload.expires_in ?? config.pollTimeoutSeconds,
            interval: payload.interval
        )
    }

    func pollToken(
        config: GrokSubscriptionAuthConfig,
        deviceCode: String
    ) async throws -> GrokSubscriptionTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": config.clientID
        ])

        let (data, response) = try await send(request)
        if response.statusCode != 200 {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        return try Self.decodeTokens(from: data)
    }

    func refreshTokens(
        config: GrokSubscriptionAuthConfig,
        refreshToken: String
    ) async throws -> GrokSubscriptionTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID
        ])

        let (data, response) = try await send(request)
        if response.statusCode != 200 {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        var tokens = try Self.decodeTokens(from: data)
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    func fetchModels(
        config: GrokSubscriptionAuthConfig,
        accessToken: String
    ) async throws -> [GrokModelDescriptor] {
        guard let url = config.modelsURL else { throw GrokSubscriptionError.configurationUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in config.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        return try Self.parseModelDescriptors(from: data)
    }

    static func parseModelDescriptors(from data: Data) throws -> [GrokModelDescriptor] {
        guard let payload = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw GrokSubscriptionError.upstream(status: 200, body: snippet(data))
        }
        return payload.data
            .filter { !$0.id.isEmpty && $0.hidden != true && $0.supported_in_api != false }
            .map { item in
                let efforts = (item.reasoning_efforts ?? []).compactMap(\.value).filter { !$0.isEmpty }
                return GrokModelDescriptor(
                    id: item.id,
                    displayName: item.name,
                    supportsWebSearch: item.supports_backend_search ?? false,
                    supportsReasoning: (item.supports_reasoning_effort ?? false) || !efforts.isEmpty,
                    reasoningEfforts: efforts,
                    defaultReasoningEffort: (item.reasoning_efforts ?? [])
                        .first { $0.default == true }?.value,
                    contextWindow: item.context_window,
                    apiBackend: item.api_backend?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    func revoke(config: GrokSubscriptionAuthConfig, token: String) async {
        guard let endpoint = config.revocationEndpoint else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token, "client_id": config.clientID])
        _ = try? await send(request)
    }


    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GrokSubscriptionError.transport("missing http response")
            }
            return (data, http)
        } catch let error as GrokSubscriptionError {
            throw error
        } catch {
            throw GrokSubscriptionError.transport(error.localizedDescription)
        }
    }

    private static func decodeTokens(from data: Data) throws -> GrokSubscriptionTokens {
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !payload.access_token.isEmpty
        else {
            throw GrokSubscriptionError.upstream(status: 200, body: Self.snippet(data))
        }
        let now = Date()
        return GrokSubscriptionTokens(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            expiresAt: payload.expires_in.map { now.addingTimeInterval(TimeInterval($0)) },
            scopes: payload.scope,
            obtainedAt: now
        )
    }

    static func mapFailure(status: Int, data: Data) -> GrokSubscriptionError {
        let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.lowercased()
        switch code {
        case "authorization_pending": return .authorizationPending
        case "slow_down": return .slowDown
        case "expired_token": return .codeExpired
        case "access_denied": return .accessDenied
        default: break
        }
        switch status {
        case 401: return .unauthorized
        case 403: return .subscriptionNotEligible
        case 426: return .clientVersionRejected
        case 429: return .quotaExhausted
        default: return .upstream(status: status, body: snippet(data))
        }
    }

    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(400), as: UTF8.self)
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String?
        let verification_uri_complete: String?
        let expires_in: Int?
        let interval: Int?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let scope: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String?
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String?
            let supports_backend_search: Bool?
            let api_backend: String?
            let supports_reasoning_effort: Bool?
            let reasoning_efforts: [ReasoningEffort]?
            let context_window: Int?
            let hidden: Bool?
            let supported_in_api: Bool?
        }
        struct ReasoningEffort: Decodable {
            let value: String?
            let `default`: Bool?
        }
        let data: [Item]
    }
}

struct GrokModelDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String?
    let supportsWebSearch: Bool
    let supportsReasoning: Bool
    let reasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let contextWindow: Int?
    let apiBackend: String?

    init(
        id: String,
        displayName: String?,
        supportsWebSearch: Bool,
        supportsReasoning: Bool,
        reasoningEfforts: [String],
        defaultReasoningEffort: String?,
        contextWindow: Int?,
        apiBackend: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsWebSearch = supportsWebSearch
        self.supportsReasoning = supportsReasoning
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.contextWindow = contextWindow
        self.apiBackend = apiBackend
    }
}
