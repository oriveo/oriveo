import Foundation

nonisolated enum BackendURLResolver {
    private static let productionURL = "https://api.oriveoai.com"
    private static let debugDefaultURL = ""

    static func resolve() -> String {
        #if DEBUG
        let environmentValue = ProcessInfo.processInfo.environment["ORIVEO_METADATA_BASE_URL"]
        let bundleValue = Bundle.main.object(forInfoDictionaryKey: "ORIVEO_METADATA_BASE_URL") as? String
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isCI = ProcessInfo.processInfo.environment["CI"] == "true"

        return resolveBaseURL(
            environmentValue: environmentValue,
            bundleValue: bundleValue,
            isRunningTests: isRunningTests,
            isCI: isCI,
            usesDebugFallback: false,
            debugDefaultURL: debugDefaultURL,
            productionURL: productionURL
        )
        #else
        return productionURL
        #endif
    }

    static func resolveBaseURL(
        environmentValue: String?,
        bundleValue: String?,
        isRunningTests: Bool,
        isCI: Bool,
        usesDebugFallback: Bool = true,
        debugDefaultURL: String = debugDefaultURL,
        productionURL: String = productionURL
    ) -> String {
        let requiresPublicURL = isRunningTests || isCI

        if let environmentURL = normalizedURL(environmentValue),
           isAllowedOverride(environmentURL, requiresPublicURL: requiresPublicURL) {
            return environmentURL
        }

        if let bundleURL = normalizedURL(bundleValue),
           isAllowedOverride(bundleURL, requiresPublicURL: requiresPublicURL) {
            return bundleURL
        }

        let fallback = usesDebugFallback && !requiresPublicURL ? debugDefaultURL : productionURL
        return normalizedURL(fallback) ?? productionURL
    }

    static func displayHost(for rawURL: String = resolve()) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        if let components = URLComponents(string: trimmed),
           let host = components.host,
           !host.isEmpty {
            return formatHost(host, port: components.port)
        }

        if let url = URL(string: trimmed),
           let host = url.host,
           !host.isEmpty {
            return formatHost(host, port: url.port)
        }

        let withoutScheme = trimmed.replacingOccurrences(
            of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
            with: "",
            options: .regularExpression
        )

        return withoutScheme
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmed
    }

    private static func formatHost(_ host: String, port: Int?) -> String {
        let base = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port else {
            return base
        }
        return "\(base):\(port)"
    }

    private static func normalizedURL(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isAllowedOverride(_ rawURL: String, requiresPublicURL: Bool) -> Bool {
        guard requiresPublicURL else { return true }
        guard let host = extractHost(from: rawURL) else { return false }
        return !isPrivateOrLocalHost(host)
    }

    private static func extractHost(from rawURL: String) -> String? {
        if let components = URLComponents(string: rawURL),
           let host = components.host,
           !host.isEmpty {
            return host
        }

        if let components = URLComponents(string: "http://\(rawURL)"),
           let host = components.host,
           !host.isEmpty {
            return host
        }

        return nil
    }

    private static func isPrivateOrLocalHost(_ rawHost: String) -> Bool {
        let lowered = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if lowered == "localhost" || lowered == "::1" || lowered == "0.0.0.0" || lowered.hasSuffix(".local") {
            return true
        }

        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") || lowered.hasPrefix("fe80:") {
            return true
        }

        let octets = lowered.split(separator: ".")
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]) else {
            return false
        }

        if first == 10 || first == 127 {
            return true
        }

        if first == 169 && second == 254 {
            return true
        }

        if first == 192 && second == 168 {
            return true
        }

        if first == 172 && (16...31).contains(second) {
            return true
        }

        return false
    }
}
