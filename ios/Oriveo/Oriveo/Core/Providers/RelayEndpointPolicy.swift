import Foundation

nonisolated enum RelayEndpointPolicy {
    static let httpsRequiredMessageKey =
        "Use an HTTPS request URL. Local-network and VPN addresses are supported when they use a valid TLS certificate."

    struct Credentials: Sendable {
        var authMode: RelayAuthMode?
        var hasKey = false
        var sensitiveHeaders: [String] = []
        var sensitiveQueryKeys: [String] = []
    }

    struct Classification: Sendable {
        let allowed: Bool
        let reason: String
        let normalized: String?
        let pinnedIPs: [String]
    }

    static func classify(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS,
        resolvedIPs: [String] = [],
        recheckResolvedIPs: [String]? = nil,
        redirects: [String] = [],
        credentials: Credentials? = nil
    ) -> Classification {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return denied("invalid_url") }

        let hasScheme = trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
            options: .regularExpression
        ) != nil
        let localMode = securityMode == .localHTTP || securityMode == .privateVPN
        let withScheme = hasScheme ? trimmed : "\(localMode ? "http" : "https")://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else { return denied("invalid_url") }
        guard components.user == nil, components.password == nil else { return denied("userinfo") }
        guard let host = components.host, !host.isEmpty else { return denied("invalid_url") }
        guard components.query == nil else { return denied("embedded_query") }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        let normalized = components.string
        if components.scheme?.lowercased() == "https" {
            return Classification(allowed: true, reason: "encrypted_remote", normalized: normalized, pinnedIPs: unique(resolvedIPs))
        }
        guard components.scheme?.lowercased() == "http" else { return denied("unsupported_scheme") }
        guard localMode else { return denied("cleartext_not_allowed") }
        if let credentials,
           credentials.authMode.map({ $0 != .none }) == true || credentials.hasKey
            || !credentials.sensitiveHeaders.isEmpty || !credentials.sensitiveQueryKeys.isEmpty {
            return denied("cleartext_credentials")
        }

        let initialIPs = unique(resolvedIPs.isEmpty ? literalHostIPs(host) : resolvedIPs)
        let initial = classifyResolvedSet(initialIPs, securityMode: securityMode)
        guard initial.allowed else { return denied(initial.reason) }
        if let recheckResolvedIPs {
            let rechecked = unique(recheckResolvedIPs)
            let result = classifyResolvedSet(rechecked, securityMode: securityMode)
            guard result.allowed, Set(rechecked) == Set(initialIPs) else { return denied("dns_rebinding") }
        }
        guard let origin = components.url else { return denied("invalid_url") }
        for rawRedirect in redirects {
            guard let redirect = URL(string: rawRedirect, relativeTo: origin)?.absoluteURL else {
                return denied("invalid_redirect")
            }
            guard isSameOrigin(origin, redirect) else { return denied("cross_origin_redirect") }
            guard redirect.scheme?.lowercased() == "http" else { return denied("redirect_scheme_changed") }
        }
        return Classification(allowed: true, reason: initial.reason, normalized: normalized, pinnedIPs: initialIPs)
    }

    static func normalize(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    ) -> String? {
        let result = classify(raw, securityMode: securityMode)
        return result.allowed ? result.normalized : nil
    }

    static func requireSecure(_ raw: String) throws -> String {
        guard let normalized = normalize(raw) else {
            throw ProviderServiceError.invalidConfiguration(detail: httpsRequiredMessageKey)
        }
        return normalized
    }

    static func requireConfigured(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode,
        credentials: Credentials? = nil
    ) throws -> String {
        let structuralResolution = securityMode == .remoteHTTPS ? [] : ["127.0.0.1"]
        let result = classify(
            raw,
            securityMode: securityMode,
            resolvedIPs: structuralResolution,
            credentials: credentials
        )
        guard result.allowed, let normalized = result.normalized else {
            throw ProviderServiceError.invalidConfiguration(detail: result.reason)
        }
        return normalized
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func classifyResolvedSet(
        _ ips: [String],
        securityMode: RelayConnectionSecurityMode
    ) -> (allowed: Bool, reason: String) {
        guard !ips.isEmpty else { return (false, "unknown_address") }
        let results = ips.map { classifyIP($0, securityMode: securityMode) }
        let allowed = results.filter(\.allowed)
        if !allowed.isEmpty && allowed.count != results.count { return (false, "mixed_resolution") }
        guard !allowed.isEmpty else { return (false, "public_address") }
        let reasons = Set(allowed.map(\.reason))
        if reasons.contains("private_vpn") { return (true, "private_vpn") }
        if reasons.contains("link_local") { return (true, "link_local") }
        if reasons.contains("private_lan") { return (true, "private_lan") }
        return (true, "loopback")
    }

    private static func classifyIP(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode
    ) -> (allowed: Bool, reason: String) {
        let value = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = value.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) {
            let (a, b) = (octets[0], octets[1])
            if a == 127 { return (true, "loopback") }
            if a == 10 || (a == 172 && 16...31 ~= b) || (a == 192 && b == 168) { return (true, "private_lan") }
            if a == 169 && b == 254 { return (true, "link_local") }
            if a == 100 && 64...127 ~= b && securityMode == .privateVPN { return (true, "private_vpn") }
            return (false, "public_address")
        }
        if value == "::1" { return (true, "loopback") }
        if value.hasPrefix("fd7a:115c:a1e0:") {
            return securityMode == .privateVPN ? (true, "private_vpn") : (false, "public_address")
        }
        if value.hasPrefix("fc") || value.hasPrefix("fd") { return (true, "private_lan") }
        if ["fe8", "fe9", "fea", "feb"].contains(where: value.hasPrefix) { return (true, "link_local") }
        return (false, "public_address")
    }

    private static func literalHostIPs(_ host: String) -> [String] {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return value.contains(":") || value.split(separator: ".").count == 4 ? [value] : []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func denied(_ reason: String) -> Classification {
        Classification(allowed: false, reason: reason, normalized: nil, pinnedIPs: [])
    }
}

enum RelaySuccessResponsePolicy {
    static func acceptsGenerationResponse(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/html") || contentType.contains("application/xhtml+xml") {
            return false
        }
        guard let body = String(data: data, encoding: .utf8) else { return true }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        let prefix = body.trimmingCharacters(in: trimSet).lowercased()
        return !prefix.hasPrefix("<!doctype html")
            && !prefix.hasPrefix("<html")
            && !prefix.hasPrefix("<head")
            && !prefix.hasPrefix("<body")
    }
}
