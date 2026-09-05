import Foundation

enum ProviderKeyValidator {

    enum Result: Equatable, Sendable {
        case valid
        case invalid(httpStatus: Int)
        case unverified(reason: UnverifiedReason)

        var isValid: Bool { if case .valid = self { return true }; return false }
        var isInvalid: Bool { if case .invalid = self { return true }; return false }
        var isUnverified: Bool { if case .unverified = self { return true }; return false }
    }

    enum UnverifiedReason: Equatable, Sendable {
        case unexpectedStatus(Int)
        case timeout
        case network
        case invalidEndpoint
    }

    static let timeoutInterval: TimeInterval = 18


    static func judge(
        statusCode: Int,
        body: Data,
        signals: [MetadataClient.ProviderValidation.InvalidKeySignal]
    ) -> Result {
        if (200 ..< 300).contains(statusCode) {
            return .valid
        }

        let bodyText = String(data: body, encoding: .utf8) ?? ""
        for signal in signals {
            guard signal.status == statusCode else { continue }
            let needles = signal.bodyIncludes ?? []
            if needles.allSatisfy({ bodyText.contains($0) }) {
                return .invalid(httpStatus: statusCode)
            }
        }

        return .unverified(reason: .unexpectedStatus(statusCode))
    }


    /// - Parameters:
    static func validate(
        provider: Provider,
        apiKey: String,
        session: URLSession = .shared
    ) async -> Result {
        let kind = provider.kind
        let validation = MetadataClient.shared.syncProviderValidation(providerKind: kind)
        let probePath = sanitizedPath(validation?.probePath) ?? "/models"
        let authMode = AuthMode(rawValue: validation?.authMode) ?? .bearer
        let headerProfile = HeaderProfile(rawValue: validation?.headerProfile) ?? .none
        let signals = validation?.invalidKeySignals ?? [.init(status: 401, bodyIncludes: nil)]

        let metadataTransport = MetadataClient.shared.syncProviderTransport(providerKind: kind)
        let baseURL = EndpointResolver.resolveBaseURL(
            provider: provider,
            metadataTransport: metadataTransport
        )

        guard let url = buildProbeURL(
            baseURL: baseURL,
            probePath: probePath,
            authMode: authMode,
            apiKey: apiKey
        ) else {
            return .unverified(reason: .invalidEndpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        applyAuthHeaders(
            to: &request,
            authMode: authMode,
            headerProfile: headerProfile,
            apiKey: apiKey
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unverified(reason: .network)
            }
            return judge(statusCode: http.statusCode, body: data, signals: signals)
        } catch let error as URLError where error.code == .timedOut {
            return .unverified(reason: .timeout)
        } catch {
            return .unverified(reason: .network)
        }
    }


    enum AuthMode: String {
        case bearer
        case xApiKey = "x_api_key"
        case queryKey = "query_key"

        init?(rawValue: String?) {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            switch raw {
            case AuthMode.bearer.rawValue: self = .bearer
            case AuthMode.xApiKey.rawValue: self = .xApiKey
            case AuthMode.queryKey.rawValue: self = .queryKey
            default: return nil
            }
        }
    }

    enum HeaderProfile: String {
        case none
        case anthropicV2023 = "anthropic_v2023_06_01"
        case openRouter = "openrouter"

        init?(rawValue: String?) {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            switch raw {
            case HeaderProfile.none.rawValue: self = .none
            case HeaderProfile.anthropicV2023.rawValue: self = .anthropicV2023
            case HeaderProfile.openRouter.rawValue: self = .openRouter
            default: return nil
            }
        }
    }


    static func buildProbeURL(
        baseURL: String,
        probePath: String,
        authMode: AuthMode,
        apiKey: String
    ) -> URL? {
        let normalizedBase = baseURL.hasPrefix("http") ? baseURL : "https://\(baseURL)"
        let effectiveProbePath = deduplicateVersionPrefix(base: normalizedBase, probePath: probePath)
        guard let base = EndpointResolver.joinURL(base: normalizedBase, path: effectiveProbePath) else {
            return nil
        }
        guard authMode == .queryKey else { return base }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = items
        return components.url ?? base
    }

    static func applyAuthHeaders(
        to request: inout URLRequest,
        authMode: AuthMode,
        headerProfile: HeaderProfile,
        apiKey: String
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UserAgentProvider.nativeUserAgent, forHTTPHeaderField: "User-Agent")

        switch authMode {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .queryKey:
            break
        }

        switch headerProfile {
        case .none:
            break
        case .anthropicV2023:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            request.setValue("https://github.com/oriveo/oriveo", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Oriveo", forHTTPHeaderField: "X-Title")
        }
    }

    // MARK: - Helpers

    private static func sanitizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func deduplicateVersionPrefix(base: String, probePath: String) -> String {
        guard let components = URLComponents(string: base) else { return probePath }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath = String(basePath.dropLast()) }
        guard !basePath.isEmpty else { return probePath }

        if probePath == basePath {
            return ""
        }
        if probePath.hasPrefix(basePath + "/") {
            return String(probePath.dropFirst(basePath.count))
        }
        return probePath
    }
}
