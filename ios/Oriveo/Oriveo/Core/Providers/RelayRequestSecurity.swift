import Darwin
import CryptoKit
import Foundation
import Security

/// Carries the connection's security intent from the request builder to `RelayRequestSecurity`,
/// which reads both and removes them again before the request is sent. Neither ever reaches the
/// network.
let relaySecurityModeHeader = "X-Oriveo-Internal-Relay-Security-Mode"
let relayCertificateFingerprintHeader = "X-Oriveo-Internal-Relay-Certificate-Fingerprint"

extension URLRequest {
    mutating func applyRelaySecurityMode(_ requested: RelayRequestedConfig?) {
        setValue(requested?.securityMode.rawValue ?? RelayConnectionSecurityMode.remoteHTTPS.rawValue,
                 forHTTPHeaderField: relaySecurityModeHeader)
        setValue(requested?.certificateFingerprint, forHTTPHeaderField: relayCertificateFingerprintHeader)
    }
}

extension URLSession {
    func relayData(for original: URLRequest) async throws -> (Data, URLResponse) {
        let prepared = try await RelayRequestSecurity.prepare(original)
        return try await RelayRequestSecurity.transportSession(for: self)
            .data(for: prepared.request, delegate: prepared.delegate)
    }

    func relayBytes(for original: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let prepared = try await RelayRequestSecurity.prepare(original)
        return try await RelayRequestSecurity.transportSession(for: self)
            .bytes(for: prepared.request, delegate: prepared.delegate)
    }
}

nonisolated enum RelayRequestSecurity {
    typealias AddressResolver = @Sendable (String) async throws -> Set<String>

    struct Prepared {
        let request: URLRequest
        let delegate: (any URLSessionTaskDelegate)?
    }

    /// Production services historically inject `.shared`. Custom LLM traffic must never inherit
    /// its process-wide cookies, cache, or credential storage. Explicitly injected test sessions
    /// are retained so URLProtocol production-path tests keep exercising the real executor.
    private static let ephemeralTransportSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func transportSession(for injected: URLSession) -> URLSession {
        injected === URLSession.shared ? ephemeralTransportSession : injected
    }

    static func prepare(_ original: URLRequest) async throws -> Prepared {
        try await prepare(original, resolver: resolveNumericAddressesAsync)
    }

    static func prepare(
        _ original: URLRequest,
        resolver: @escaping AddressResolver
    ) async throws -> Prepared {
        var request = original
        guard let url = request.url else { throw securityError("invalid_url") }
        let marker = request.value(forHTTPHeaderField: relaySecurityModeHeader)
        let certificateFingerprint = request.value(forHTTPHeaderField: relayCertificateFingerprintHeader)
        request.setValue(nil, forHTTPHeaderField: relaySecurityModeHeader)
        request.setValue(nil, forHTTPHeaderField: relayCertificateFingerprintHeader)
        let mode = marker.flatMap(RelayConnectionSecurityMode.init(rawValue:)) ?? .remoteHTTPS

        if mode == .remoteHTTPS {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
                throw securityError("cleartext_not_allowed")
            }
            return Prepared(
                request: request,
                delegate: RelayHTTPSRedirectGuard(originalURL: url)
            )
        }

        if mode == .tofuHTTPS {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  let certificateFingerprint,
                  RelayTLSFingerprintGuard.isValidFingerprint(certificateFingerprint) else {
                throw securityError("tofu_fingerprint_required")
            }
            return Prepared(
                request: request,
                delegate: RelayTLSFingerprintGuard(expectedFingerprint: certificateFingerprint)
            )
        }

        try requireNoSensitiveMaterial(request)
        let pinned = try await resolveAndClassify(url, mode: mode, resolver: resolver)
        let rechecked = try await resolveAndClassify(url, mode: mode, resolver: resolver)
        guard pinned == rechecked else { throw securityError("dns_rebinding") }
        let pinnedRequest = try pinCleartextRequest(request, logicalURL: url, addresses: pinned)
        return Prepared(
            request: pinnedRequest,
            delegate: RelayLocalRedirectGuard(mode: mode, pinnedIPs: pinned, originalURL: url)
        )
    }

    static func pinCleartextRequest(
        _ original: URLRequest,
        logicalURL: URL,
        addresses: Set<String>
    ) throws -> URLRequest {
        guard logicalURL.scheme?.lowercased() == "http",
              let logicalHost = logicalURL.host,
              let pinnedAddress = addresses.sorted().first,
              var components = URLComponents(url: logicalURL, resolvingAgainstBaseURL: false) else {
            throw securityError("cleartext_not_allowed")
        }
        components.host = pinnedAddress
        guard let pinnedURL = components.url else { throw securityError("invalid_url") }
        var request = original
        request.url = pinnedURL
        let hostHeader = logicalURL.port.map { "\(logicalHost):\($0)" } ?? logicalHost
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        return request
    }

    static func resolveAndClassify(
        _ url: URL,
        mode: RelayConnectionSecurityMode,
        resolver: @escaping AddressResolver = resolveNumericAddressesAsync
    ) async throws -> Set<String> {
        guard let host = url.host else { throw securityError("invalid_url") }
        let addresses = try await resolver(host)
        let origin = try originString(url)
        let result = RelayEndpointPolicy.classify(
            origin,
            securityMode: mode,
            resolvedIPs: Array(addresses)
        )
        guard result.allowed else { throw securityError(result.reason) }
        return addresses
    }

    static func classifyForModeSelection(
        _ raw: String,
        mode: RelayConnectionSecurityMode
    ) async -> RelayEndpointPolicy.Classification {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme: String
        if trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
            options: .regularExpression
        ) == nil {
            withScheme = "http://\(trimmed)"
        } else if var components = URLComponents(string: trimmed) {
            components.scheme = "http"
            withScheme = components.string ?? trimmed
        } else {
            withScheme = trimmed
        }

        guard let url = URL(string: withScheme), let host = url.host else {
            return RelayEndpointPolicy.classify(withScheme, securityMode: mode)
        }
        do {
            let addresses = try await Task.detached(priority: .userInitiated) {
                try resolveNumericAddresses(host)
            }.value
            return RelayEndpointPolicy.classify(
                withScheme,
                securityMode: mode,
                resolvedIPs: Array(addresses)
            )
        } catch {
            let reason: String
            if case ProviderServiceError.invalidConfiguration(let detail) = error {
                reason = detail
            } else {
                reason = "dns_resolution_failed"
            }
            return RelayEndpointPolicy.Classification(
                allowed: false,
                reason: reason,
                normalized: nil,
                pinnedIPs: []
            )
        }
    }

    static func requireNoSensitiveMaterial(_ request: URLRequest) throws {
        let headerNames = request.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys
        let queryNames = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? []
        guard !headerNames.contains(where: isSensitiveName),
              !queryNames.contains(where: isSensitiveName) else {
            throw securityError("cleartext_credentials")
        }
    }

    static func originString(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw securityError("invalid_url")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let result = components.string else { throw securityError("invalid_url") }
        return result
    }

    static func isSensitiveName(_ raw: String) -> Bool {
        let value = raw.lowercased()
        return value == "x-api-key" || value == "api-key" || value == "x-goog-api-key"
            || value == "key" || value == "api_key" || value == "apikey"
            || value == "openai-organization"
            || value.contains("authorization") || value.contains("token")
            || value.contains("secret") || value.hasSuffix("key")
    }

    static func credentialMaterial(in request: URLRequest) -> [String] {
        var material: [String] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] where isSensitiveName(name) {
            let stripped = value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
            material.append(stripped.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let url = request.url,
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where isSensitiveName(item.name) {
                material.append((item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return material.filter { $0.count >= 8 }
    }

    static func redactingCredentials(_ text: String, credentials: [String]) -> String {
        var output = text
        for credential in credentials where credential.count >= 8 {
            output = output.replacingOccurrences(of: credential, with: redactedPlaceholder)
            if let encoded = credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               encoded != credential {
                output = output.replacingOccurrences(of: encoded, with: redactedPlaceholder)
            }
        }
        return output
    }

    static let redactedPlaceholder = "***hidden"

    static func securityError(_ reason: String) -> ProviderServiceError {
        .invalidConfiguration(detail: reason)
    }
}

private final class RelayHTTPSRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL

    init(originalURL: URL) {
        self.originalURL = originalURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(RelayRequestSecurity.validatedHTTPSRedirect(
            originalURL: originalURL,
            response: response,
            request: request
        ))
    }
}

extension RelayRequestSecurity {
    static func validatedHTTPSRedirect(
        originalURL: URL,
        response: HTTPURLResponse,
        request: URLRequest
    ) -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let redirected = request.url,
              redirected.scheme?.lowercased() == "https",
              redirected.user == nil,
              redirected.password == nil,
              RelayEndpointPolicy.isSameOrigin(originalURL, redirected) else {
            return nil
        }
        return request
    }
}

private final class RelayTLSFingerprintGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = Self.normalize(expectedFingerprint)
    }

    static func isValidFingerprint(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        return normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)
    }

    private static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .replacingOccurrences(of: ":", with: "")
            .filter { !$0.isWhitespace }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class RelayLocalRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let mode: RelayConnectionSecurityMode
    private let pinnedIPs: Set<String>
    private let originalURL: URL

    init(mode: RelayConnectionSecurityMode, pinnedIPs: Set<String>, originalURL: URL) {
        self.mode = mode
        self.pinnedIPs = pinnedIPs
        self.originalURL = originalURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        Task {
            guard let redirected = request.url,
                  redirected.scheme?.lowercased() == "http",
                  (try? RelayRequestSecurity.requireNoSensitiveMaterial(request)) != nil else {
                completionHandler(nil)
                return
            }

            let logicalRedirect: URL
            if redirected.host == pinnedIPs.sorted().first {
                guard var components = URLComponents(url: redirected, resolvingAgainstBaseURL: false) else {
                    completionHandler(nil)
                    return
                }
                components.host = originalURL.host
                guard let rebuilt = components.url else {
                    completionHandler(nil)
                    return
                }
                logicalRedirect = rebuilt
            } else {
                logicalRedirect = redirected
            }

            guard RelayEndpointPolicy.isSameOrigin(originalURL, logicalRedirect),
                  let rechecked = try? await RelayRequestSecurity.resolveAndClassify(logicalRedirect, mode: mode),
                  rechecked == pinnedIPs,
                  let pinnedRequest = try? RelayRequestSecurity.pinCleartextRequest(
                      request,
                      logicalURL: logicalRedirect,
                      addresses: rechecked
                  ) else {
                completionHandler(nil)
                return
            }
            completionHandler(pinnedRequest)
        }
    }
}

nonisolated private func resolveNumericAddresses(_ host: String) throws -> Set<String> {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    hints.ai_flags = AI_ADDRCONFIG
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0, let first = result else {
        throw RelayRequestSecurity.securityError("dns_resolution_failed")
    }
    defer { freeaddrinfo(first) }
    var addresses = Set<String>()
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor?.pointee {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.insert(String(cString: buffer).split(separator: "%", maxSplits: 1).first.map(String.init) ?? "")
        }
        cursor = info.ai_next
    }
    addresses.remove("")
    guard !addresses.isEmpty else { throw RelayRequestSecurity.securityError("dns_resolution_failed") }
    return addresses
}

nonisolated private func resolveNumericAddressesAsync(_ host: String) async throws -> Set<String> {
    try await Task.detached(priority: .userInitiated) {
        try resolveNumericAddresses(host)
    }.value
}
