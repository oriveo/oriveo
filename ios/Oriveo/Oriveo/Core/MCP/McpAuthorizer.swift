import CryptoKit
import Foundation

// MARK: - Remote MCP authorization
//
// Covers: discovery from the 401 `WWW-Authenticate` header (RFC 9728, including the `resource` check),
// authorization server metadata (RFC 8414, with strict issuer validation), the three client registration
// tiers (CIMD / DCR / neither), PKCE (S256), a mandatory `state`, `resource` (RFC 8707) on both the
// authorization and token requests, the 2x2 `iss` check (RFC 9207), token exchange, refresh, and
// serialization of concurrent refreshes for the same server.
//
// The browser session and the HTTP transport are both protocols so tests can supply fakes; this file has
// no UI dependency. The production transport's https / redirect / byte-limit rules live in `McpHTTP.swift`.
//
// Every type carrying a verifier, state, token or `client_id` has a redacted string description, so being
// printed into a log never leaks a secret.

// MARK: - 401 / 403 challenges

/// The parameters of `WWW-Authenticate: Bearer ...` that matter here.
nonisolated struct McpAuthChallenge: Sendable, Equatable {
    var resourceMetadata: URL?
    var scope: String?
    var error: String?
    var errorDescription: String?

    init(
        resourceMetadata: URL? = nil,
        scope: String? = nil,
        error: String? = nil,
        errorDescription: String? = nil
    ) {
        self.resourceMetadata = resourceMetadata
        self.scope = scope
        self.error = error
        self.errorDescription = errorDescription
    }
}

nonisolated enum McpWWWAuthenticate {
    /// Parses `WWW-Authenticate` (RFC 7235 auth-param). Header names are compared case-insensitively
    /// elsewhere; only the value is parsed here.
    static func parse(_ header: String?) -> McpAuthChallenge? {
        guard let header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var challenge = McpAuthChallenge()
        guard let space = header.firstIndex(of: " ") else { return challenge }
        let parameters = header[header.index(after: space)...]
        for token in splitAuthParams(parameters) {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let name = token[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = token[token.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch name {
            case "resource_metadata": challenge.resourceMetadata = URL(string: value)
            case "scope": challenge.scope = value
            case "error": challenge.error = value
            case "error_description": challenge.errorDescription = value
            default: break
            }
        }
        return challenge
    }

    /// Splits on commas but not on commas inside quotes (a scope value may contain spaces and
    /// error_description may contain commas).
    private static func splitAuthParams(_ text: Substring) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                result.append(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        result.append(text[start...])
        return result
    }
}

/// Maps 401 / 403 onto the probe state machine.
nonisolated enum McpAuthResponseMapping {
    /// Step-up (re-authorizing for a larger scope) is not implemented yet, so 403 `insufficient_scope` is
    /// handled as `needs_auth`.
    static let stepUpImplemented = false

    static func needsAuthErrorCode(status: Int, wwwAuthenticate: String?) -> McpErrorCode? {
        if status == 401 { return .needsAuth }
        if status == 403, McpWWWAuthenticate.parse(wwwAuthenticate)?.error == "insufficient_scope" {
            return .needsAuth
        }
        return nil
    }
}

// MARK: - Protected resource metadata discovery (RFC 9728)

nonisolated enum McpProtectedResourceDiscovery {
    /// Discovery order: prefer `resource_metadata` from `WWW-Authenticate`; without it, build the
    /// well-known URIs in turn - first the one for the MCP endpoint path, then the one at the root.
    static func candidates(challenge: McpAuthChallenge?, endpoint: URL) -> [URL] {
        var result: [URL] = []
        if let fromHeader = challenge?.resourceMetadata { result.append(fromHeader) }
        if let origin = originString(endpoint) {
            let path = endpoint.path
            if !path.isEmpty, path != "/" {
                if let atPath = URL(string: origin + "/.well-known/oauth-protected-resource" + path) {
                    result.append(atPath)
                }
            }
            if let atRoot = URL(string: origin + "/.well-known/oauth-protected-resource") {
                result.append(atRoot)
            }
        }
        return dedupe(result)
    }

    static func originString(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return nil }
        var result = "\(scheme)://\(host)"
        if let port = components.port { result += ":\(port)" }
        return result
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}

/// Whether the `resource` in protected resource metadata corresponds to the MCP endpoint being requested
/// (RFC 9728 section 3.3).
nonisolated enum McpResourceBinding {
    /// It corresponds when it has the same origin and its path equals the endpoint path or is one of its
    /// parent path segments (the `resource` of a root well-known document is usually the whole origin or a
    /// parent path and covers the endpoints below it). A missing `resource`, one that is not https, or one
    /// with a query string or fragment that is not the endpoint itself never counts.
    static func covers(resource: String?, endpoint: URL) -> Bool {
        guard let resource, let resourceURL = URL(string: resource), McpOrigin.isHTTPS(resourceURL) else {
            return false
        }
        if McpCanonicalURI.canonical(resourceURL) == McpCanonicalURI.canonical(endpoint) { return true }
        guard McpOrigin.isSameOrigin(resourceURL, endpoint),
              resourceURL.query == nil, resourceURL.fragment == nil else { return false }
        let base = resourceURL.path.hasSuffix("/") ? String(resourceURL.path.dropLast()) : resourceURL.path
        return base.isEmpty || endpoint.path == base || endpoint.path.hasPrefix(base + "/")
    }
}

/// RFC 9728 protected resource metadata. MUST contain `authorization_servers` (at least one).
nonisolated struct McpProtectedResourceMetadata: Sendable, Equatable {
    /// The resource this metadata describes. Must pass `McpResourceBinding.covers` before it is used.
    var resource: String?
    var authorizationServers: [String]
    var scopesSupported: [String]

    init?(json: JSONValue) {
        guard let servers = json["authorization_servers"]?.arrayValue?.compactMap(\.stringValue),
              !servers.isEmpty else { return nil }
        self.resource = json["resource"]?.stringValue
        self.authorizationServers = servers
        self.scopesSupported = json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

// MARK: - Authorization server metadata (RFC 8414)

nonisolated enum McpAuthorizationServerDiscovery {
    /// Two or three well-known locations, in an order that depends on whether the issuer has a path.
    static func candidates(issuer: URL) -> [URL] {
        guard let origin = McpProtectedResourceDiscovery.originString(issuer) else { return [] }
        let path = issuer.path
        if !path.isEmpty, path != "/" {
            return [
                URL(string: origin + "/.well-known/oauth-authorization-server" + path),
                URL(string: origin + "/.well-known/openid-configuration" + path),
                URL(string: origin + path + "/.well-known/openid-configuration"),
            ].compactMap { $0 }
        }
        return [
            URL(string: origin + "/.well-known/oauth-authorization-server"),
            URL(string: origin + "/.well-known/openid-configuration"),
        ].compactMap { $0 }
    }
}

nonisolated struct McpAuthorizationServerMetadata: Sendable, Equatable {
    var issuer: String
    var authorizationEndpoint: URL?
    var tokenEndpoint: URL?
    var registrationEndpoint: URL?
    var scopesSupported: [String]
    var clientIDMetadataDocumentSupported: Bool
    var authorizationResponseIssParameterSupported: Bool
    /// The PKCE methods the authorization server declares (`code_challenge_methods_supported`). Empty
    /// when none are declared.
    var codeChallengeMethodsSupported: [String]

    /// Only S256 is used. The metadata must declare it; when it is missing or not listed the flow cannot
    /// continue (a MUST in the specification): an authorization server that does not declare it may simply
    /// ignore `code_challenge`, leaving the authorization code without PKCE protection.
    var supportsS256: Bool { codeChallengeMethodsSupported.contains("S256") }

    init?(json: JSONValue) {
        guard let issuer = json["issuer"]?.stringValue, !issuer.isEmpty else { return nil }
        self.issuer = issuer
        // Authorization / token / registration endpoints must be https; anything else is treated as absent
        // and the flow stops by itself later on.
        self.authorizationEndpoint = Self.httpsURL(json["authorization_endpoint"])
        self.tokenEndpoint = Self.httpsURL(json["token_endpoint"])
        self.registrationEndpoint = Self.httpsURL(json["registration_endpoint"])
        self.scopesSupported = json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.clientIDMetadataDocumentSupported = json["client_id_metadata_document_supported"]?.boolValue ?? false
        self.authorizationResponseIssParameterSupported = json["authorization_response_iss_parameter_supported"]?.boolValue ?? false
        self.codeChallengeMethodsSupported = json["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func httpsURL(_ value: JSONValue?) -> URL? {
        guard let url = value?.stringValue.flatMap(URL.init(string:)), McpOrigin.isHTTPS(url) else { return nil }
        return url
    }
}

// MARK: - Client registration

nonisolated enum McpClientRegistrationKind: String, Codable, Sendable, Equatable {
    /// Client ID Metadata Document (CIMD): `client_id` is a self-hosted https URL and is portable across
    /// authorization servers.
    case cimd
    /// Dynamic Client Registration (RFC 7591; the specification marks it deprecated, it is the fallback
    /// when CIMD is unavailable).
    case dcr
}

nonisolated struct McpClientRegistration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var kind: McpClientRegistrationKind
    var clientID: String
    /// Credentials are bound to an issuer and never reused across authorization servers (CIMD excepted,
    /// since it is a self-hosted URL).
    var issuer: String

    /// A DCR `client_id` is a credential and stays out of the string description.
    var description: String {
        "McpClientRegistration(kind: \(kind.rawValue), issuer: \(issuer), clientID: <redacted>)"
    }

    var debugDescription: String { description }
}

nonisolated enum McpClientRegistrationDecision {
    /// Priority: pre-registered credentials (no client ships any, so skipped) -> CIMD -> DCR -> `nil` when
    /// neither is available (meaning "access token required"). CIMD is only an option when this build was
    /// given a client metadata document to point at (`McpClientMetadata.documentURL`).
    static func decide(
        _ metadata: McpAuthorizationServerMetadata,
        clientMetadataDocumentURL: URL? = McpClientMetadata.documentURL
    ) -> McpClientRegistrationKind? {
        if metadata.clientIDMetadataDocumentSupported, clientMetadataDocumentURL != nil { return .cimd }
        if metadata.registrationEndpoint != nil { return .dcr }
        return nil
    }
}

/// How this client identifies itself to an authorization server.
nonisolated enum McpClientMetadata {
    /// Info.plist key that holds the URL of a client metadata document (CIMD).
    ///
    /// The document is a small JSON file served over https by whoever distributes the build. Its `client_id`
    /// is its own URL and its `redirect_uris` must list `oriveo://mcp/oauth/callback`. The key ships empty:
    /// without a document this registration method is skipped and the client registers itself dynamically
    /// with each authorization server (RFC 7591) instead. To use a document, host it and put its URL in the
    /// `ORIVEO_MCP_CLIENT_METADATA_URL` string of `Config/Info.plist`.
    static let documentURLInfoKey = "ORIVEO_MCP_CLIENT_METADATA_URL"

    /// The configured client metadata document, or `nil` when the build has none.
    static let documentURL: URL? = resolveDocumentURL(
        Bundle.main.object(forInfoDictionaryKey: documentURLInfoKey) as? String
    )

    /// Accepts only an absolute https URL with a host; anything else counts as "not configured".
    static func resolveDocumentURL(_ rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed), McpOrigin.isHTTPS(url), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    static let clientName = "Oriveo"
    /// The redirect URI: a custom scheme, so the callback returns straight to the app.
    static let iosRedirectURI = "oriveo://mcp/oauth/callback"
    static let callbackURLScheme = "oriveo"
    /// Every redirect URI that a client metadata document and a DCR registration must list.
    static let redirectURIs = [iosRedirectURI]

    /// DCR registration request body (RFC 7591). Native apps MUST specify `application_type: "native"`.
    static func registrationBody(scope: String?) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("client_name", .string(clientName)),
            ("redirect_uris", .array(redirectURIs.map { .string($0) })),
            ("grant_types", .array([.string("authorization_code"), .string("refresh_token")])),
            ("response_types", .array([.string("code")])),
            ("token_endpoint_auth_method", .string("none")),
            ("application_type", .string("native")),
        ]
        if let scope, !scope.isEmpty { pairs.append(("scope", .string(scope))) }
        return .object(JSONObject(pairs))
    }
}

// MARK: - Canonical URI (RFC 8707)

nonisolated enum McpCanonicalURI {
    /// Lowercase scheme and host, no fragment, no trailing slash.
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        // All clients strip trailing slashes, including the root path `/` (`https://a.com/` -> `https://a.com`).
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? url.absoluteString
    }
}

// MARK: - PKCE (S256) and random values

nonisolated enum McpPKCE {
    /// OAuth 2.1 section 7.5.2: `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))`.
    static func codeChallenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated enum McpAuthorizationRandom {
    /// `state` is always used (the specification only says "if used").
    static func state() -> String {
        McpPKCE.base64URL(Data(randomBytes(16)))
    }

    /// A `code_verifier` of 43-128 unreserved characters.
    static func codeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}

// MARK: - Authorization and token requests (pure functions, easy to replay against fixtures)

nonisolated struct McpFormField: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    /// Form values hold authorization codes, verifiers, refresh tokens and `client_id`; none of them ever
    /// enters the string description.
    var description: String { "McpFormField(\(name)=<redacted>)" }
    var debugDescription: String { description }
}

nonisolated struct McpAuthorizationRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The full authorization page URL. Its query string carries `state`, `code_challenge` and
    /// `client_id`, so never log it whole.
    var url: URL
    var state: String
    var codeVerifier: String
    var issuer: String
    var resource: String
    var redirectURI: String
    var clientID: String
    var scope: String?

    /// The parsed query items (decoded key/value pairs), convenient for assertions.
    var queryItems: [McpFormField] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.map { McpFormField($0.name, $0.value ?? "") }
    }

    /// Reports only the authorization endpoint (without the query string) and the issuer.
    var description: String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return "McpAuthorizationRequest(endpoint: \(components?.string ?? "<invalid>"), issuer: \(issuer), "
            + "clientID: <redacted>, state: <redacted>, codeVerifier: <redacted>)"
    }

    var debugDescription: String { description }
}

/// Token endpoint response. Neither `expires_in` nor `refresh_token` is guaranteed (a client MUST NOT
/// assume a refresh token is always present).
nonisolated struct McpTokenResponse: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessToken: String
    var expiresIn: Double?
    var refreshToken: String?

    init?(json: JSONValue) {
        guard let accessToken = json["access_token"]?.stringValue, !accessToken.isEmpty else { return nil }
        // Only `Authorization: Bearer` is ever sent. A token the server explicitly labels as another type
        // (DPoP, MAC, ...) cannot be used as a Bearer token.
        if let tokenType = json["token_type"]?.stringValue, tokenType.lowercased() != "bearer" { return nil }
        self.accessToken = accessToken
        // A non-positive lifetime is meaningless and treated as absent (otherwise every call would see the
        // token as "about to expire" and refresh); absurdly large values are capped so the expiry never
        // works out to an unrepresentable date.
        self.expiresIn = json["expires_in"]?.doubleValue.flatMap { $0 > 0 ? min($0, Self.maxExpiresIn) : nil }
        self.refreshToken = json["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Upper bound for the lifetime: ten years.
    static let maxExpiresIn: Double = 10 * 365 * 24 * 3600

    /// Tokens stay out of the string description.
    var description: String {
        "McpTokenResponse(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"), "
            + "expiresIn: \(expiresIn.map { "\($0)" } ?? "nil"))"
    }

    var debugDescription: String { description }
}

nonisolated enum McpOAuthRequests {
    /// Authorization request: `resource` MUST be included; PKCE uses S256; `state` is mandatory.
    static func authorizationRequest(
        authorizationEndpoint: URL,
        clientID: String,
        redirectURI: String,
        state: String,
        codeVerifier: String,
        issuer: String,
        resource: String,
        scope: String?
    ) -> McpAuthorizationRequest {
        var fields: [McpFormField] = [
            McpFormField("response_type", "code"),
            McpFormField("client_id", clientID),
            McpFormField("redirect_uri", redirectURI),
            McpFormField("state", state),
            McpFormField("code_challenge", McpPKCE.codeChallenge(forVerifier: codeVerifier)),
            McpFormField("code_challenge_method", "S256"),
            McpFormField("resource", resource),
        ]
        if let scope, !scope.isEmpty { fields.append(McpFormField("scope", scope)) }
        // A query string already present on the authorization endpoint is kept (RFC 6749 section 3.1) and
        // our parameters are appended after it. The existing query is concatenated in its original
        // encoding, without decoding and re-encoding, so sequences such as `%2B` are not rewritten.
        var ours = URLComponents()
        ours.queryItems = fields.map { URLQueryItem(name: $0.name, value: $0.value) }
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let existing = components?.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
        components?.percentEncodedQuery = [existing, ours.percentEncodedQuery].compactMap { $0 }.joined(separator: "&")
        return McpAuthorizationRequest(
            url: components?.url ?? authorizationEndpoint,
            state: state,
            codeVerifier: codeVerifier,
            issuer: issuer,
            resource: resource,
            redirectURI: redirectURI,
            clientID: clientID,
            scope: scope
        )
    }

    /// Token exchange form: `resource` MUST be included and `code_verifier` matches S256.
    static func tokenExchangeForm(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String,
        resource: String
    ) -> [McpFormField] {
        [
            McpFormField("grant_type", "authorization_code"),
            McpFormField("code", code),
            McpFormField("redirect_uri", redirectURI),
            McpFormField("client_id", clientID),
            McpFormField("code_verifier", codeVerifier),
            McpFormField("resource", resource),
        ]
    }

    /// Refresh token form: `resource` MUST be included.
    static func refreshForm(refreshToken: String, clientID: String, resource: String) -> [McpFormField] {
        [
            McpFormField("grant_type", "refresh_token"),
            McpFormField("refresh_token", refreshToken),
            McpFormField("client_id", clientID),
            McpFormField("resource", resource),
        ]
    }
}

// MARK: - Callback validation

nonisolated enum McpCallbackRejectionReason: String, Sendable, Equatable {
    case stateMismatch = "state_mismatch"
    case issMissingWhileDeclaredSupported = "iss_missing_while_declared_supported"
    case issMismatch = "iss_mismatch"
    case issMismatchTrailingSlashNotNormalized = "iss_mismatch_trailing_slash_not_normalized"
    case redirectURIMismatch = "redirect_uri_mismatch"
    case authorizationError = "authorization_error"
    case missingCode = "missing_code"
}

nonisolated enum McpCallbackValidation: Sendable, Equatable {
    case accepted(code: String)
    case rejected(McpCallbackRejectionReason)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var rejection: McpCallbackRejectionReason? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

nonisolated enum McpRedirectURI {
    /// The callback URL must be the one that was registered (compares scheme / host / path and ignores
    /// the query string).
    static func matches(callbackURL: URL, registered: String) -> Bool {
        guard let registeredURL = URL(string: registered),
              let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: registeredURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        return callback.scheme?.lowercased() == expected.scheme?.lowercased()
            && callback.host?.lowercased() == expected.host?.lowercased()
            && normalizedPath(callback.path) == normalizedPath(expected.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }
}

nonisolated enum McpCallbackValidator {
    /// Validates `iss` against the 2x2 table of RFC 9207 section 2.4, **with no normalization before comparing**.
    ///
    /// | `authorization_response_iss_parameter_supported` | `iss` in the response | Action |
    /// |---|---|---|
    /// | true | present | string comparison |
    /// | true | absent | reject |
    /// | false or missing | present | string comparison |
    /// | false or missing | absent | accept |
    static func validate(
        params: [String: String],
        expectedState: String,
        expectedIssuer: String,
        issParameterSupported: Bool,
        callbackURL: URL? = nil,
        registeredRedirectURI: String? = nil
    ) -> McpCallbackValidation {
        // A callback URL other than the registered one is always rejected (no token exists to be saved yet).
        if let callbackURL, let registeredRedirectURI,
           !McpRedirectURI.matches(callbackURL: callbackURL, registered: registeredRedirectURI) {
            return .rejected(.redirectURIMismatch)
        }
        guard params["state"] == expectedState else { return .rejected(.stateMismatch) }
        let iss = params["iss"]
        switch (issParameterSupported, iss) {
        case (true, .none):
            return .rejected(.issMissingWhileDeclaredSupported)
        case (_, .some(let value)) where value != expectedIssuer:
            if value == expectedIssuer + "/" {
                return .rejected(.issMismatchTrailingSlashNotNormalized)
            }
            return .rejected(.issMismatch)
        default:
            break
        }
        // When iss does not match, error / error_description / error_uri MUST NOT be used or displayed.
        if params["error"] != nil { return .rejected(.authorizationError) }
        guard let code = params["code"], !code.isEmpty else { return .rejected(.missingCode) }
        return .accepted(code: code)
    }

    /// Extracts the query parameters from the callback URL.
    static func parameters(from url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var result: [String: String] = [:]
        for item in items { result[item.name] = item.value ?? "" }
        return result
    }
}

// MARK: - Scope selection

nonisolated enum McpScope {
    /// Prefers the `scope` from the 401; otherwise uses `scopes_supported` from the protected resource
    /// metadata; adds `offline_access` when the authorization server's `scopes_supported` lists it (a
    /// client MAY request it to obtain a refresh token).
    static func resolve(
        challengeScope: String?,
        resourceScopes: [String],
        authorizationServerScopes: [String]
    ) -> String? {
        var parts: [String]
        if let challengeScope, !challengeScope.trimmingCharacters(in: .whitespaces).isEmpty {
            parts = challengeScope.split(separator: " ").map(String.init)
        } else {
            parts = resourceScopes
        }
        if authorizationServerScopes.contains("offline_access"), !parts.contains("offline_access") {
            parts.append("offline_access")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Transport and browser session abstractions

/// The HTTP transport for the OAuth side. Any error an implementation throws means "could not connect this
/// time" (network / timeout / refused redirect), which is different from "the server answered with a
/// status code" - the former is transient, only the latter is a conclusion.
nonisolated protocol McpAuthTransport: Sendable {
    func get(_ url: URL) async throws -> McpHTTPResponse
    func postForm(_ url: URL, form: [McpFormField]) async throws -> McpHTTPResponse
    func postJSON(_ url: URL, body: JSONValue) async throws -> McpHTTPResponse
}

/// The production transport. All three constraints are enforced in `McpHTTP`:
/// - https only: nothing is sent to an authorization / token / registration / metadata endpoint that is not https;
/// - redirects: metadata GETs follow same-origin https only; the token and registration endpoints **never
///   follow redirects** - the request body carries the authorization code, verifier and refresh token, and
///   following a 3xx would hand them to another address;
/// - a response body limit and an overall deadline.
nonisolated struct URLSessionMcpAuthTransport: McpAuthTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = McpHTTP.defaultSession, timeout: TimeInterval = 60) {
        self.session = session
        self.timeout = timeout
    }

    func get(_ url: URL) async throws -> McpHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request, redirect: .sameOriginHTTPS)
    }

    func postForm(_ url: URL, form: [McpFormField]) async throws -> McpHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.encodeForm(form).utf8)
        return try await send(request, redirect: .never)
    }

    func postJSON(_ url: URL, body: JSONValue) async throws -> McpHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.orderedJSONString.utf8)
        return try await send(request, redirect: .never)
    }

    static func encodeForm(_ form: [McpFormField]) -> String {
        form.map { "\(percentEncode($0.name))=\(percentEncode($0.value))" }.joined(separator: "&")
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func send(_ request: URLRequest, redirect: McpRedirectPolicy) async throws -> McpHTTPResponse {
        var request = request
        request.timeoutInterval = timeout + McpHTTPLimits.urlSessionTimeoutMargin
        let session = self.session
        let prepared = request
        return try await McpHTTP.withDeadline(timeout) {
            try await McpHTTP.send(
                prepared,
                session: session,
                redirect: redirect,
                limit: McpHTTPLimits.maxAuthResponseBytes
            )
        }
    }
}

/// Browser session abstraction (the iOS production implementation is `ASWebAuthenticationSession`; this
/// unit pulls in no UI).
nonisolated protocol McpBrowserSession: Sendable {
    /// Opens the authorization page and waits for the callback; throws when the user cancels.
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL
}

// MARK: - Errors

nonisolated enum McpAuthorizerError: Error, Equatable {
    /// A client cannot be registered automatically (no usable metadata, or none of the registration
    /// mechanisms is available); the flow falls back to "access token required".
    case notAutoRegisterable
    case registrationFailed
    /// The authorization server considers our client registration invalid (`invalid_client` /
    /// `unauthorized_client`). The locally cached DCR registration has been cleared by then and the next
    /// sign-in registers again.
    case clientRejected
    /// The authorization server's metadata is **definitely** unavailable (all 404 / not JSON / issuer
    /// validation failed).
    case metadataUnavailable
    /// Could not connect this time (network, timeout, 5xx). **A transient error**: retrying later is
    /// enough, it does not mean the credentials are invalid and must not be used as a reason to ask the
    /// user to sign in again.
    case temporarilyUnavailable
    /// The callback was rejected. **Carries no server text**, so `error_description` cannot leak out.
    case callbackRejected(McpCallbackRejectionReason)
    case tokenRequestFailed
    /// No usable refresh token (the server issued none, or it was discarded after being invalidated);
    /// the only option is signing in again.
    case noRefreshToken
    /// The credentials could not be written to the device's secure storage. Callers must not treat this
    /// sign-in / refresh as persisted.
    case credentialPersistenceFailed
    case cancelled

    /// A retryable transient error: the connection state should not switch to `needsAuth`.
    var isTransient: Bool { self == .temporarilyUnavailable }

    /// Classifies an error thrown by the transport: cancellation stays cancellation, everything else is
    /// "could not connect this time".
    static func transport(_ error: Error) -> McpAuthorizerError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .temporarilyUnavailable
    }
}

// MARK: - Discovery result

/// The product of the discovery phase: **only metadata has been read and nothing has been registered with
/// the authorization server yet**. Registration (DCR) is a write against a third-party server and must wait
/// until the user has agreed to open the browser (see `McpAuthorizer.authorize(plan:)`).
nonisolated struct McpAuthorizationPlan: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    /// The registration mechanism this authorization server supports.
    var registrationKind: McpClientRegistrationKind
    /// The DCR registration endpoint (always set when `registrationKind == .dcr`).
    var registrationEndpoint: URL?
    var scope: String?
    var resource: String
    /// `authorization_response_iss_parameter_supported`, needed by the 2x2 table of callback validation.
    var issParameterSupported: Bool

    var description: String {
        "McpAuthorizationPlan(issuer: \(issuer), registration: \(registrationKind.rawValue), resource: \(resource))"
    }

    var debugDescription: String { description }
}

nonisolated enum McpAuthDiscoveryOutcome: Sendable, Equatable {
    /// A client can be registered automatically, so the browser may be opened (once the user consents).
    case ready(McpAuthorizationPlan)
    /// Automatic registration is impossible or the metadata is definitely unavailable -> access token required.
    case needsToken
    /// The metadata could not be fetched this time (network, timeout, 5xx). Not evidence that an access
    /// token is required; retry later.
    case temporarilyUnavailable
}

/// The per-request record of one authorization attempt: the PKCE verifier, issuer and state are kept in
/// the same record.
nonisolated struct McpAuthorizationAttempt: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var request: McpAuthorizationRequest
    var issuer: String
    var codeVerifier: String
    var state: String
    var redirectURI: String
    var clientID: String
    var registrationKind: McpClientRegistrationKind
    var tokenEndpoint: URL
    var resource: String
    var issParameterSupported: Bool

    /// The verifier, state and `client_id` all stay out of the string description.
    var description: String {
        "McpAuthorizationAttempt(issuer: \(issuer), registration: \(registrationKind.rawValue), "
            + "clientID: <redacted>, state: <redacted>, codeVerifier: <redacted>)"
    }

    var debugDescription: String { description }
}

// MARK: - Authorizer

/// The OAuth authorizer for remote MCP. The add flow uses it in three steps:
///
/// 1. `discover(challenge:endpoint:)` - reads metadata only and decides whether automatic registration is
///    possible; **registers nothing**.
/// 2. The caller shows the user the pre-sign-in prompt and the user consents.
/// 3. `authorize(plan:serverId:uid:)` - register (reusing the locally cached DCR registration) -> open the
///    browser -> validate the callback -> exchange the code for tokens -> persist. The discovery result is
///    passed in as is, with no second discovery.
actor McpAuthorizer {
    private let transport: any McpAuthTransport
    private let browser: any McpBrowserSession
    private let credentialStore: McpCredentialStore
    /// The client metadata document this authorizer may present as its `client_id`; `nil` skips that
    /// registration method.
    private let clientMetadataDocumentURL: URL?
    private let now: @Sendable () -> Date
    /// Serializes concurrent refreshes for the same server: the key is `uid:serverId`, the value the
    /// refresh task in flight.
    private var refreshTasks: [String: Task<McpCredentials, Error>] = [:]
    /// Serializes concurrent registrations for the same `uid + issuer`, so two flows do not each register once.
    private var registrationTasks: [String: Task<McpClientRegistration, Error>] = [:]

    init(
        transport: any McpAuthTransport,
        browser: any McpBrowserSession,
        credentialStore: McpCredentialStore = .shared,
        clientMetadataDocumentURL: URL? = McpClientMetadata.documentURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.browser = browser
        self.credentialStore = credentialStore
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.now = now
    }

    // MARK: Discovery

    /// Discovers the authorization server and decides whether automatic registration is possible.
    /// **Sends GET requests only; registers nothing and writes no storage.**
    func discover(challenge: McpAuthChallenge?, endpoint: URL) async -> McpAuthDiscoveryOutcome {
        let resourceCandidates = McpProtectedResourceDiscovery.candidates(challenge: challenge, endpoint: endpoint)
        let protected: McpProtectedResourceMetadata
        switch await fetchProtectedResourceMetadata(resourceCandidates, endpoint: endpoint) {
        case .found(let metadata): protected = metadata
        case .absent: return .needsToken
        case .transient: return .temporarilyUnavailable
        }
        // With several authorization servers, take the first usable one (RFC 9728 section 7.6 leaves the
        // choice to the client); the issuer must be https.
        guard let issuerURL = protected.authorizationServers.lazy.compactMap(URL.init(string:)).first(where: McpOrigin.isHTTPS) else {
            return .needsToken
        }
        let serverMetadata: McpAuthorizationServerMetadata
        switch await fetchAuthorizationServerMetadata(issuer: issuerURL) {
        case .found(let metadata): serverMetadata = metadata
        // All three well-known locations unavailable, or issuer validation failed -> "a client cannot be
        // registered automatically"; default endpoints are never guessed.
        case .absent: return .needsToken
        case .transient: return .temporarilyUnavailable
        }
        // An authorization server that does not declare S256 gets no browser sign-in and ends up where
        // "cannot register automatically" does: access token required.
        guard serverMetadata.supportsS256,
              let authorizationEndpoint = serverMetadata.authorizationEndpoint,
              let tokenEndpoint = serverMetadata.tokenEndpoint,
              let registrationKind = McpClientRegistrationDecision.decide(
                  serverMetadata, clientMetadataDocumentURL: clientMetadataDocumentURL
              ) else {
            return .needsToken
        }
        return .ready(McpAuthorizationPlan(
            issuer: serverMetadata.issuer,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationKind: registrationKind,
            registrationEndpoint: registrationKind == .dcr ? serverMetadata.registrationEndpoint : nil,
            scope: McpScope.resolve(
                challengeScope: challenge?.scope,
                resourceScopes: protected.scopesSupported,
                authorizationServerScopes: serverMetadata.scopesSupported
            ),
            resource: McpCanonicalURI.canonical(endpoint),
            issParameterSupported: serverMetadata.authorizationResponseIssParameterSupported
        ))
    }

    // MARK: Registration

    /// Obtains the client registration for this authorization server. CIMD needs no registration; DCR first
    /// checks the local cache (keyed by `uid + issuer`) and only registers with the authorization server -
    /// storing the result - when nothing is cached, so the same authorization server is not registered
    /// against over and over, piling up clients.
    ///
    /// **Call it only after the user has agreed to open the browser.** The discovery phase never calls it.
    func register(plan: McpAuthorizationPlan, uid: String) async throws -> McpClientRegistration {
        switch plan.registrationKind {
        case .cimd:
            guard let documentURL = clientMetadataDocumentURL else { throw McpAuthorizerError.registrationFailed }
            return McpClientRegistration(
                kind: .cimd,
                clientID: documentURL.absoluteString,
                issuer: plan.issuer
            )
        case .dcr:
            // A cached registration whose redirect URIs have changed (after an app update) can no longer be
            // used; register again.
            if let cached = credentialStore.loadClientRegistration(issuer: plan.issuer, uid: uid),
               cached.redirectURIs == McpClientMetadata.redirectURIs {
                return McpClientRegistration(kind: .dcr, clientID: cached.clientID, issuer: cached.issuer)
            }
            let key = McpCredentialStore.registrationAccount(issuer: plan.issuer, uid: uid)
            if let existing = registrationTasks[key] { return try await existing.value }
            let task = Task<McpClientRegistration, Error> { [self] in
                try await registerDynamically(plan: plan, uid: uid)
            }
            registrationTasks[key] = task
            defer { registrationTasks[key] = nil }
            return try await task.value
        }
    }

    private func registerDynamically(plan: McpAuthorizationPlan, uid: String) async throws -> McpClientRegistration {
        guard let endpoint = plan.registrationEndpoint else {
            throw McpAuthorizerError.registrationFailed
        }
        let response: McpHTTPResponse
        do {
            response = try await transport.postJSON(endpoint, body: McpClientMetadata.registrationBody(scope: plan.scope))
        } catch {
            throw McpAuthorizerError.transport(error)
        }
        if Self.isTransientStatus(response.status) { throw McpAuthorizerError.temporarilyUnavailable }
        guard (200..<300).contains(response.status),
              let json = try? JSONValue(data: response.body),
              let clientID = json["client_id"]?.stringValue, !clientID.isEmpty else {
            throw McpAuthorizerError.registrationFailed
        }
        // Client credentials are bound to an issuer and never reused across authorization servers; they are
        // kept in the device's secure storage only.
        do {
            try credentialStore.saveClientRegistration(
                McpStoredClientRegistration(
                    clientID: clientID,
                    issuer: plan.issuer,
                    redirectURIs: McpClientMetadata.redirectURIs
                ),
                uid: uid
            )
        } catch {
            throw McpAuthorizerError.credentialPersistenceFailed
        }
        return McpClientRegistration(kind: .dcr, clientID: clientID, issuer: plan.issuer)
    }

    /// Clears the local cache when the authorization server rejects the registration, so the next
    /// registration starts over. Only clears the very registration that was just used.
    private func discardRejectedRegistration(clientID: String, issuer: String, uid: String) {
        guard credentialStore.loadClientRegistration(issuer: issuer, uid: uid)?.clientID == clientID else { return }
        credentialStore.deleteClientRegistration(issuer: issuer, uid: uid)
    }

    // MARK: Authorization

    /// A complete browser sign-in: register -> open the browser -> validate the callback -> exchange the
    /// code for tokens -> persist.
    ///
    /// `plan` is the result of `discover`; no second discovery happens here. When the authorization server
    /// rejects the cached DCR registration it is cleared, registered again, and the flow runs once more
    /// (once only).
    ///
    /// With `persist = false` the tokens are returned without being written to disk: the add flow calls
    /// `persistCredentials` after the server record has been saved. Storing the tokens first would mean a
    /// process killed midway leaves tokens without a server and no way to ever clear them.
    func authorize(
        plan: McpAuthorizationPlan,
        serverId: UUID,
        uid: String,
        redirectURI: String = McpClientMetadata.iosRedirectURI,
        persist: Bool = true
    ) async throws -> McpCredentials {
        var retriesLeft = plan.registrationKind == .dcr ? 1 : 0
        while true {
            let attempt = try await beginAuthorization(plan: plan, uid: uid, redirectURI: redirectURI)
            let callback: URL
            do {
                callback = try await browser.authorize(
                    url: attempt.request.url,
                    callbackURLScheme: McpClientMetadata.callbackURLScheme
                )
            } catch {
                throw McpAuthorizerError.cancelled
            }
            do {
                return try await completeAuthorization(
                    attempt: attempt, callbackURL: callback, serverId: serverId, uid: uid, persist: persist
                )
            } catch McpAuthorizerError.clientRejected where retriesLeft > 0 {
                retriesLeft -= 1
            }
        }
    }

    /// Registers and assembles the authorization request, leaving a per-request record. Tests can inject a
    /// deterministic `state` / `codeVerifier`.
    func beginAuthorization(
        plan: McpAuthorizationPlan,
        uid: String,
        redirectURI: String = McpClientMetadata.iosRedirectURI,
        state: String = McpAuthorizationRandom.state(),
        codeVerifier: String = McpAuthorizationRandom.codeVerifier()
    ) async throws -> McpAuthorizationAttempt {
        let registration = try await register(plan: plan, uid: uid)
        let request = McpOAuthRequests.authorizationRequest(
            authorizationEndpoint: plan.authorizationEndpoint,
            clientID: registration.clientID,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: codeVerifier,
            issuer: plan.issuer,
            resource: plan.resource,
            scope: plan.scope
        )
        return McpAuthorizationAttempt(
            request: request,
            issuer: plan.issuer,
            codeVerifier: codeVerifier,
            state: state,
            redirectURI: redirectURI,
            clientID: registration.clientID,
            registrationKind: registration.kind,
            tokenEndpoint: plan.tokenEndpoint,
            resource: plan.resource,
            issParameterSupported: plan.issParameterSupported
        )
    }

    /// Exchanges the code and persists only after callback validation passes. Every rejection returns
    /// before the token exchange and **saves no token**.
    func completeAuthorization(
        attempt: McpAuthorizationAttempt,
        callbackURL: URL,
        serverId: UUID,
        uid: String,
        persist: Bool = true
    ) async throws -> McpCredentials {
        let params = McpCallbackValidator.parameters(from: callbackURL)
        let validation = McpCallbackValidator.validate(
            params: params,
            expectedState: attempt.state,
            expectedIssuer: attempt.issuer,
            issParameterSupported: attempt.issParameterSupported,
            callbackURL: callbackURL,
            registeredRedirectURI: attempt.redirectURI
        )
        guard case .accepted(let code) = validation else {
            let reason = validation.rejection ?? .stateMismatch
            // Reaching authorizationError means the callback URL, state and iss have all been validated,
            // so `error` can be trusted.
            if reason == .authorizationError, attempt.registrationKind == .dcr,
               Self.isClientRejection(params["error"]) {
                discardRejectedRegistration(clientID: attempt.clientID, issuer: attempt.issuer, uid: uid)
                throw McpAuthorizerError.clientRejected
            }
            throw McpAuthorizerError.callbackRejected(reason)
        }
        let form = McpOAuthRequests.tokenExchangeForm(
            code: code,
            clientID: attempt.clientID,
            redirectURI: attempt.redirectURI,
            codeVerifier: attempt.codeVerifier,
            resource: attempt.resource
        )
        let response: McpHTTPResponse
        do {
            response = try await transport.postForm(attempt.tokenEndpoint, form: form)
        } catch {
            throw McpAuthorizerError.transport(error)
        }
        if Self.isTransientStatus(response.status) { throw McpAuthorizerError.temporarilyUnavailable }
        let json = try? JSONValue(data: response.body)
        guard (200..<300).contains(response.status), let json, let tokens = McpTokenResponse(json: json) else {
            if attempt.registrationKind == .dcr, Self.isClientRejection(json?["error"]?.stringValue) {
                discardRejectedRegistration(clientID: attempt.clientID, issuer: attempt.issuer, uid: uid)
                throw McpAuthorizerError.clientRejected
            }
            throw McpAuthorizerError.tokenRequestFailed
        }
        // Signing in again replaces only the OAuth fields; a token the user pasted is left as it is.
        let previous = credentialStore.load(serverId: serverId, uid: uid)
        let credentials = McpCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresIn.map { now().addingTimeInterval($0) },
            issuer: attempt.issuer,
            clientID: attempt.clientID,
            resource: attempt.resource,
            pastedToken: previous?.pastedToken
        )
        if persist { try persistCredentials(credentials, serverId: serverId, uid: uid) }
        return credentials
    }

    // MARK: Refresh

    /// Refreshes the access token. **Concurrent refreshes for the same server are serialized**: two
    /// concurrent calls trigger a single refresh.
    ///
    /// Throwing `temporarilyUnavailable` means the connection failed this time (retryable, the credentials
    /// are kept as they are); only `noRefreshToken` / `tokenRequestFailed` / `metadataUnavailable` mean the
    /// user has to sign in again.
    func refresh(serverId: UUID, uid: String) async throws -> McpCredentials {
        let key = McpCredentialStore.account(serverId: serverId, uid: uid)
        if let existing = refreshTasks[key] { return try await existing.value }
        let task = Task<McpCredentials, Error> { [self] in
            try await performRefresh(serverId: serverId, uid: uid)
        }
        refreshTasks[key] = task
        defer { refreshTasks[key] = nil }
        return try await task.value
    }

    /// Returns a usable access token before a call, refreshing first when it is about to expire.
    ///
    /// When the refresh hits a transient error while the access token has not actually expired, the
    /// existing token is returned as usual - a network blip should not fail the call.
    func validAccessToken(
        serverId: UUID,
        uid: String,
        expirySkew: TimeInterval = 60
    ) async throws -> String? {
        guard let credentials = credentialStore.load(serverId: serverId, uid: uid) else { return nil }
        guard let accessToken = credentials.accessToken else { return credentials.pastedToken }
        guard let expiresAt = credentials.expiresAt,
              expiresAt.timeIntervalSince(now()) < expirySkew,
              credentials.refreshToken != nil else {
            return accessToken
        }
        do {
            // If the credentials were replaced by a pasted token during the refresh (see the re-read in
            // `performRefresh`), the returned set has no OAuth access token.
            let refreshed = try await refresh(serverId: serverId, uid: uid)
            return refreshed.accessToken ?? refreshed.pastedToken
        } catch let error as McpAuthorizerError where error.isTransient && expiresAt > now() {
            return accessToken
        }
    }

    /// Stores an access token pasted by the user (the "access token" sign-in method). Throws
    /// `credentialPersistenceFailed` when it cannot be written to secure storage.
    ///
    /// The previous OAuth fields (access token, refresh token, expiry, issuer, client_id, resource) are
    /// cleared with it: if they stayed, token lookup would still prefer the old access token and the newly
    /// pasted one would never be sent.
    func storePastedToken(_ token: String, serverId: UUID, uid: String) throws {
        try persistCredentials(McpCredentials(pastedToken: token), serverId: serverId, uid: uid)
    }

    private func performRefresh(serverId: UUID, uid: String) async throws -> McpCredentials {
        // "No refresh token" and "metadata temporarily unavailable" are different things: the former
        // requires signing in again, the latter only a retry later.
        guard let existing = credentialStore.load(serverId: serverId, uid: uid),
              let refreshToken = existing.refreshToken, !refreshToken.isEmpty,
              let issuer = existing.issuer,
              let clientID = existing.clientID,
              let resource = existing.resource,
              let issuerURL = URL(string: issuer) else {
            throw McpAuthorizerError.noRefreshToken
        }
        let serverMetadata: McpAuthorizationServerMetadata
        switch await fetchAuthorizationServerMetadata(issuer: issuerURL) {
        case .found(let metadata): serverMetadata = metadata
        case .transient: throw McpAuthorizerError.temporarilyUnavailable
        case .absent: throw McpAuthorizerError.metadataUnavailable
        }
        guard let tokenEndpoint = serverMetadata.tokenEndpoint else {
            throw McpAuthorizerError.metadataUnavailable
        }
        let response: McpHTTPResponse
        do {
            response = try await transport.postForm(
                tokenEndpoint,
                form: McpOAuthRequests.refreshForm(refreshToken: refreshToken, clientID: clientID, resource: resource)
            )
        } catch {
            throw McpAuthorizerError.transport(error)
        }
        if Self.isTransientStatus(response.status) { throw McpAuthorizerError.temporarilyUnavailable }
        let json = try? JSONValue(data: response.body)
        guard (200..<300).contains(response.status), let json, let tokens = McpTokenResponse(json: json) else {
            let oauthError = json?["error"]?.stringValue
            if oauthError == "invalid_grant" {
                // Re-read before writing: while waiting for the response the credentials may have been
                // replaced elsewhere (a new sign-in, a newly pasted token), or the whole server may have
                // been removed. If the stored refresh token is no longer the one that was sent, the
                // stored value wins and must not be wiped; if the record is gone, write nothing, so a
                // removed server is not left with credentials.
                guard let current = credentialStore.load(serverId: serverId, uid: uid) else {
                    throw McpAuthorizerError.tokenRequestFailed
                }
                if current.refreshToken != refreshToken {
                    if current.accessToken != nil || current.pastedToken != nil { return current }
                    throw McpAuthorizerError.tokenRequestFailed
                }
                // Still the one that was sent: the refresh token is invalid -> drop the tokens, keep the
                // client registration (issuer / clientID / resource), and the connection state moves to
                // needsAuth (fixture auth/token.error.json).
                try persistCredentials(
                    McpCredentials(issuer: issuer, clientID: clientID, resource: resource, pastedToken: current.pastedToken),
                    serverId: serverId,
                    uid: uid
                )
            } else if Self.isClientRejection(oauthError) {
                // The registration itself was rejected: clear the cached DCR registration; signing in
                // again registers anew.
                discardRejectedRegistration(clientID: clientID, issuer: issuer, uid: uid)
            }
            throw McpAuthorizerError.tokenRequestFailed
        }
        let updated = McpCredentials(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? refreshToken,
            expiresAt: tokens.expiresIn.map { now().addingTimeInterval($0) },
            issuer: issuer,
            clientID: clientID,
            resource: resource,
            pastedToken: existing.pastedToken
        )
        // Persist immediately after a successful refresh. If the write fails, throw rather than hand out
        // an in-memory token as if it had been saved.
        try persistCredentials(updated, serverId: serverId, uid: uid)
        return updated
    }

    /// Writes credentials to the device's secure storage. Tokens obtained with `authorize(persist: false)`
    /// are stored through here by the add flow once the record has been saved.
    func persistCredentials(_ credentials: McpCredentials, serverId: UUID, uid: String) throws {
        do {
            try credentialStore.save(credentials, serverId: serverId, uid: uid)
        } catch {
            throw McpAuthorizerError.credentialPersistenceFailed
        }
    }

    // MARK: Internals: fetching metadata

    /// The three outcomes of fetching metadata. "Definitely absent" and "could not connect this time" must
    /// stay separate: the former is a conclusion, the latter only a transient error.
    private enum Fetched<Value> {
        case found(Value)
        case absent
        case transient
    }

    private static func isTransientStatus(_ status: Int) -> Bool {
        status >= 500 || status == 429 || status == 408
    }

    private static func isClientRejection(_ oauthError: String?) -> Bool {
        oauthError == "invalid_client" || oauthError == "unauthorized_client"
    }

    private func fetchProtectedResourceMetadata(
        _ candidates: [URL],
        endpoint: URL
    ) async -> Fetched<McpProtectedResourceMetadata> {
        var sawTransient = false
        for url in candidates where McpOrigin.isHTTPS(url) {
            guard let response = try? await transport.get(url) else {
                sawTransient = true
                continue
            }
            if Self.isTransientStatus(response.status) {
                sawTransient = true
                continue
            }
            guard response.status == 200,
                  let json = try? JSONValue(data: response.body),
                  let metadata = McpProtectedResourceMetadata(json: json) else {
                continue
            }
            // RFC 9728 section 3.3: the `resource` in the document must correspond to the MCP endpoint being
            // requested, otherwise the metadata MUST NOT be used - or anyone's metadata could steer us to
            // an authorization server of their choosing.
            guard McpResourceBinding.covers(resource: metadata.resource, endpoint: endpoint) else { continue }
            return .found(metadata)
        }
        return sawTransient ? .transient : .absent
    }

    private func fetchAuthorizationServerMetadata(
        issuer: URL
    ) async -> Fetched<McpAuthorizationServerMetadata> {
        guard McpOrigin.isHTTPS(issuer) else { return .absent }
        var sawTransient = false
        for url in McpAuthorizationServerDiscovery.candidates(issuer: issuer) {
            guard let response = try? await transport.get(url) else {
                sawTransient = true
                continue
            }
            if Self.isTransientStatus(response.status) {
                sawTransient = true
                continue
            }
            guard response.status == 200,
                  let json = try? JSONValue(data: response.body),
                  let metadata = McpAuthorizationServerMetadata(json: json) else {
                continue
            }
            // RFC 8414 section 3.3: the `issuer` in the document MUST be **identical** to the identifier
            // used to build the URL; otherwise the document is rejected.
            guard metadata.issuer == issuer.absoluteString else { continue }
            return .found(metadata)
        }
        return sawTransient ? .transient : .absent
    }
}
