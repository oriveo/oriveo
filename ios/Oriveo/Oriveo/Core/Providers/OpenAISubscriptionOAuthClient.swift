import Foundation

struct OpenAISubscriptionOAuthClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func requestDeviceAuthorization(
        config: OpenAISubscriptionAuthConfig
    ) async throws -> OpenAIDeviceAuthorization {
        var request = URLRequest(url: config.deviceAuthorizationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": config.clientID])

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        guard let payload = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data),
              !payload.device_auth_id.isEmpty, !payload.user_code.isEmpty
        else {
            throw OpenAISubscriptionError.upstream(status: 200, body: Self.snippet(data))
        }
        return OpenAIDeviceAuthorization(
            deviceAuthID: payload.device_auth_id,
            userCode: payload.user_code,
            verificationURL: config.verificationURL,
            interval: max(1, payload.resolvedInterval ?? config.pollIntervalSeconds),
            expiresIn: payload.expires_in ?? config.pollTimeoutSeconds
        )
    }

    func pollToken(
        config: OpenAISubscriptionAuthConfig,
        deviceAuthID: String,
        userCode: String
    ) async throws -> OpenAISubscriptionTokens {
        var request = URLRequest(url: config.deviceTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthID,
            "user_code": userCode
        ])

        let (data, response) = try await send(request)
        if response.statusCode == 200 {
            guard let payload = try? JSONDecoder().decode(DevicePollResponse.self, from: data),
                  let code = payload.authorization_code, !code.isEmpty,
                  let verifier = payload.code_verifier, !verifier.isEmpty
            else {
                throw OpenAISubscriptionError.authorizationPending
            }
            return try await exchangeAuthorizationCode(config: config, code: code, codeVerifier: verifier)
        }

        let code = Self.errorCode(from: data)
        switch code {
        case "deviceauth_authorization_pending", "authorization_pending": throw OpenAISubscriptionError.authorizationPending
        case "slow_down": throw OpenAISubscriptionError.slowDown
        case "expired_token", "device_code_expired": throw OpenAISubscriptionError.codeExpired
        case "access_denied": throw OpenAISubscriptionError.accessDenied
        default: break
        }
        if response.statusCode == 403 || response.statusCode == 404 {
            throw OpenAISubscriptionError.authorizationPending
        }
        throw Self.mapFailure(status: response.statusCode, data: data)
    }

    func exchangeAuthorizationCode(
        config: OpenAISubscriptionAuthConfig,
        code: String,
        codeVerifier: String
    ) async throws -> OpenAISubscriptionTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": config.redirectURI.absoluteString
        ])

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        return try Self.decodeTokens(from: data, previous: nil)
    }

    func refreshTokens(
        config: OpenAISubscriptionAuthConfig,
        refreshToken: String,
        previous: OpenAISubscriptionTokens
    ) async throws -> OpenAISubscriptionTokens {
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
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        return try Self.decodeTokens(from: data, previous: previous)
    }

    func fetchModels(
        config: OpenAISubscriptionAuthConfig,
        accessToken: String,
        accountID: String
    ) async throws -> [CodexModelDescriptor] {
        guard let modelsURL = config.modelsURL,
              var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
        else { throw OpenAISubscriptionError.configurationUnavailable }
        if let clientVersion = config.requiredHeaders["version"], !clientVersion.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "client_version", value: clientVersion))
            components.queryItems = items
        }
        guard let url = components.url else { throw OpenAISubscriptionError.configurationUnavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        for (name, value) in config.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, data: data)
        }
        return try Self.parseModelDescriptors(from: data)
    }

    static func parseModelSlugs(from data: Data) throws -> [String] {
        try parseModelDescriptors(from: data).map(\.slug)
    }

    static func parseModelDescriptors(from data: Data) throws -> [CodexModelDescriptor] {
        guard let payload = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw OpenAISubscriptionError.upstream(status: 200, body: snippet(data))
        }
        return payload.models
            .filter { $0.visibility == "list" && ($0.supported_in_api ?? false) }
            .filter { !$0.slug.isEmpty }
            .map { item in
                CodexModelDescriptor(
                    slug: item.slug,
                    displayName: item.display_name,
                    supportsWebSearch: !(item.web_search_tool_type ?? "").isEmpty,
                    supportedReasoningLevels: item.supported_reasoning_levels ?? [],
                    defaultReasoningLevel: item.default_reasoning_level,
                    supportsImageInput: (item.input_modalities ?? []).contains("image"),
                    contextWindow: item.context_window
                )
            }
    }


    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAISubscriptionError.transport("missing http response")
            }
            return (data, http)
        } catch let error as OpenAISubscriptionError {
            throw error
        } catch {
            throw OpenAISubscriptionError.transport(error.localizedDescription)
        }
    }

    private static func decodeTokens(from data: Data, previous: OpenAISubscriptionTokens?) throws -> OpenAISubscriptionTokens {
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !payload.access_token.isEmpty
        else {
            throw OpenAISubscriptionError.upstream(status: 200, body: Self.snippet(data))
        }
        let claimSource = payload.id_token ?? payload.access_token
        guard let accountID = nonEmpty(OpenAIJWTClaims.string(claimSource, claim: "chatgpt_account_id"))
            ?? nonEmpty(previous?.accountID)
        else {
            throw OpenAISubscriptionError.upstream(status: 200, body: "missing chatgpt_account_id")
        }
        let planType = nonEmpty(OpenAIJWTClaims.string(claimSource, claim: "chatgpt_plan_type"))
            ?? nonEmpty(previous?.planType)
        let now = Date()
        let expiresAt = OpenAIJWTClaims.expiration(payload.access_token)
            ?? payload.expires_in.map { now.addingTimeInterval(TimeInterval($0)) }
        return OpenAISubscriptionTokens(
            accessToken: payload.access_token,
            refreshToken: nonEmpty(payload.refresh_token) ?? nonEmpty(previous?.refreshToken),
            idToken: payload.id_token,
            expiresAt: expiresAt,
            accountID: accountID,
            planType: planType,
            obtainedAt: now
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func mapFailure(status: Int, data: Data) -> OpenAISubscriptionError {
        switch errorCode(from: data) {
        case "authorization_pending", "deviceauth_authorization_pending": return .authorizationPending
        case "slow_down": return .slowDown
        case "expired_token", "device_code_expired": return .codeExpired
        case "access_denied": return .accessDenied
        case "usage_limit_reached", "rate_limit_exceeded": return .quotaExhausted
        case "usage_not_included": return .subscriptionNotEligible
        case "refresh_token_invalidated", "invalid_grant": return .unauthorized
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

    private static func errorCode(from data: Data) -> String? {
        if let obj = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            if let str = obj.errorString { return str.lowercased() }
            if let detail = obj.errorObject {
                return (detail.code ?? detail.type)?.lowercased()
            }
        }
        return nil
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
        let device_auth_id: String
        let user_code: String
        let expires_in: Int?
        private let intervalNumber: Int?
        private let intervalString: String?
        var resolvedInterval: Int? { intervalNumber ?? intervalString.flatMap { Int($0) } }

        enum CodingKeys: String, CodingKey {
            case device_auth_id, user_code, expires_in, interval
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device_auth_id = try c.decode(String.self, forKey: .device_auth_id)
            user_code = try c.decode(String.self, forKey: .user_code)
            expires_in = try c.decodeIfPresent(Int.self, forKey: .expires_in)
            intervalNumber = try? c.decodeIfPresent(Int.self, forKey: .interval)
            intervalString = try? c.decodeIfPresent(String.self, forKey: .interval)
        }
    }

    private struct DevicePollResponse: Decodable {
        let authorization_code: String?
        let code_verifier: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: String?
            let type: String?
        }
        let errorString: String?
        let errorObject: Detail?

        enum CodingKeys: String, CodingKey { case error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let str = try? c.decode(String.self, forKey: .error) {
                errorString = str
                errorObject = nil
            } else {
                errorString = nil
                errorObject = try? c.decode(Detail.self, forKey: .error)
            }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let slug: String
            let visibility: String?
            let supported_in_api: Bool?
            let display_name: String?
            let web_search_tool_type: String?
            let supported_reasoning_levels: [String]?
            let default_reasoning_level: String?
            let input_modalities: [String]?
            let context_window: Int?

            private enum CodingKeys: String, CodingKey {
                case slug, visibility, supported_in_api, display_name
                case web_search_tool_type, supported_reasoning_levels
                case default_reasoning_level, input_modalities, context_window
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
                visibility = try? c.decode(String.self, forKey: .visibility)
                supported_in_api = try? c.decode(Bool.self, forKey: .supported_in_api)
                display_name = try? c.decode(String.self, forKey: .display_name)
                web_search_tool_type = try? c.decode(String.self, forKey: .web_search_tool_type)
                supported_reasoning_levels = (try? c.decode([ReasoningLevelItem].self, forKey: .supported_reasoning_levels))?
                    .compactMap(\.effort)
                default_reasoning_level = try? c.decode(String.self, forKey: .default_reasoning_level)
                input_modalities = try? c.decode([String].self, forKey: .input_modalities)
                if let intValue = try? c.decode(Int.self, forKey: .context_window) {
                    context_window = intValue
                } else if let doubleValue = try? c.decode(Double.self, forKey: .context_window) {
                    context_window = Int(doubleValue)
                } else {
                    context_window = nil
                }
            }
        }
        let models: [Item]

        struct ReasoningLevelItem: Decodable {
            let effort: String?

            private enum CodingKeys: String, CodingKey { case effort }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let text = try? single.decode(String.self) {
                    effort = text
                    return
                }
                let keyed = try? decoder.container(keyedBy: CodingKeys.self)
                effort = keyed.flatMap { try? $0.decode(String.self, forKey: .effort) }
            }
        }
    }
}

struct CodexModelDescriptor: Equatable, Sendable {
    let slug: String
    let displayName: String?
    let supportsWebSearch: Bool
    let supportedReasoningLevels: [String]
    let defaultReasoningLevel: String?
    let supportsImageInput: Bool
    let contextWindow: Int?

    var supportsReasoning: Bool { !supportedReasoningLevels.isEmpty }
}
