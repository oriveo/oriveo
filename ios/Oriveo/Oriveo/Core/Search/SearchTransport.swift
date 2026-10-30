import Foundation

// MARK: - Restricted declarative transport json_http/v1 (external search services contract)
//
// Function-by-function port of scripts/lib/search-transport.mjs (same names on all three platforms): buildSearchRequest / parseSearchResponse /
// sanitizeSearchText / classifySearchError / validateCustomSearchService / validateManualMapping /
// keyBindingOrigin / snapshotPresetMapping / catalogOutageBehavior. Value extraction only; no templates, expressions or scripts.

/// Hard client-side cap, independent of the catalog.
nonisolated enum SearchHardLimits {
    static let maxCount = 10
    static let defaultCount = 5
    static let maxTimeoutSec = 60
    static let maxResponseBytes = 2 * 1024 * 1024
    static let titleMaxChars = 200
    static let snippetMaxChars = 1000
    static let siteMaxChars = 100
    static let dateMaxChars = 32
    static let maxQueryChars = 400
}

/// Request target: preset = catalog site (https + host + the site's static params); custom = the scheme / host / port / path split out of the user's address.
nonisolated struct SearchRequestTarget: Sendable, Equatable {
    var scheme: String
    var host: String
    var port: Int?
    /// Full path of a custom service; overrides spec.path.
    var path: String?
    /// Static params overridden by the site.
    var staticParams: SearchJSONObject?
}

/// Result of buildSearchRequest: send a request, or don't (an empty query costs the user nothing; the caller treats it as "no results").
nonisolated enum SearchRequestBuild: Sendable, Equatable {
    case send(SearchHTTPRequest)
    case skip(reason: String)
}

/// Normalized result of a user-pasted key.
nonisolated struct SearchKeyNormalization: Codable, Sendable, Equatable {
    var ok: Bool
    var key: String?
    var error: String?
}

/// The built request; body is a JSON object (compared by JSON semantics, not bytes).
nonisolated struct SearchHTTPRequest: Sendable, Equatable {
    var method: String
    var url: String
    var headers: [String: String]
    var body: SearchJSON?
}

nonisolated struct SearchResultItem: Codable, Sendable, Equatable {
    var title: String
    var url: String
    var snippet: String
    var site: String?
    var date: String?
}

nonisolated enum SearchParseOutcome: Sendable, Equatable, Encodable {
    case results([SearchResultItem])
    case empty
    case error(errorClass: String)

    private enum CodingKeys: String, CodingKey { case kind, results, errorClass }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .results(let items):
            try container.encode("results", forKey: .kind)
            try container.encode(items, forKey: .results)
        case .empty:
            try container.encode("empty", forKey: .kind)
        case .error(let errorClass):
            try container.encode("error", forKey: .kind)
            try container.encode(errorClass, forKey: .errorClass)
        }
    }
}

nonisolated enum SearchTransportFailure: String, Codable, Sendable {
    case timeout
    case network
    case tooLarge = "too_large"
    /// Refused by the device's security policy (cleartext address resolving to the public internet, DNS rebinding, cross-origin / too many hops / invalid-Location redirects aborted).
    case blocked
}

/// Input of classifySearchError. rules = the catalog entry's `transport.errors` or the custom protocol's own rules.
nonisolated struct SearchErrorInput: Sendable {
    var status: Int?
    var transportFailure: SearchTransportFailure?
    var preflight: PresetHostVerdict?
    var parseMismatch = false
    var body: SearchJSON?
    var rules: [SearchJSON] = []
    var custom = false
    var otherServices = 0
}

nonisolated struct SearchErrorCard: Codable, Sendable, Equatable {
    var headline: String
    var primaryAction: String
    var secondaryAction: String?
}

nonisolated struct SearchErrorClassification: Codable, Sendable, Equatable {
    var errorClass: String
    var retryOnce: Bool
    /// Key of the fixed message returned to the model (`SearchTransport.toolMessages`).
    var toolMessage: String
    var card: SearchErrorCard
}

/// Result of splitting a custom service address.
nonisolated struct SearchServiceAddress: Sendable, Equatable {
    var scheme: String
    var host: String
    var port: Int?
    var path: String
    var query: String
}

nonisolated enum SearchClientPlatform: String, Codable, Sendable {
    case ios
    case android
    case web
}

/// Provided by the existing local / LAN compute security check (after DNS resolution).
nonisolated enum SearchAddressClass: String, Codable, Sendable {
    case `public`
    case lan
    case unresolved
}

nonisolated struct CustomSearchServiceInput: Sendable {
    var name: String?
    var address: String?
    var protocolID: String?
    var platform: SearchClientPlatform
    var addressClass: SearchAddressClass?
    var presetID: String?
    var catalogAvailable: Bool?
    var presetActive: Bool?
    var manual: SearchJSON?
}

nonisolated struct CustomSearchServiceValidation: Codable, Sendable, Equatable {
    var ok: Bool
    var errors: [String]
    var warnings: [String]
    var origin: String?
    var requestPath: String?
}

nonisolated struct SearchCatalogOutageBehavior: Codable, Sendable, Equatable {
    var usable: Bool
    var creatable: Bool
    var presentation: String?
}

nonisolated enum SearchTransport {
    static let kind = "json_http/v1"

        // MARK: Static param allowlist

    private enum StaticRule {
        case values([SearchJSON])
        case integer(ClosedRange<Int64>)
    }

        /// Allowlist of static params the catalog may enable (key = dotted path): stops the catalog from turning on surcharge params. Custom services are not bound by it.
    private static let staticParamWhitelist: [String: StaticRule] = [
        "search_engine": .values(["search_std", "search-prime"]),
        "search_intent": .values([false]),
        "search_depth": .values(["basic"]),
        "type": .values(["auto"]),
        "max_tokens_per_page": .integer(1...512),
        "contents.text": .values([false]),
        "contents.highlights.maxCharacters": .integer(1...1000),
        "format": .values(["json"]),
    ]

    static func staticParamAllowed(_ key: String, _ value: SearchJSON) -> Bool {
        switch staticParamWhitelist[key] {
        case .values(let allowed)?:
            return allowed.contains { strictEquals($0, value) }
        case .integer(let range)?:
            guard let integer = value.integerValue else { return false }
            return range.contains(integer)
        case nil:
            return false
        }
    }

        /// JS `===`: holds only for primitive values; objects / arrays compare by reference, so they are always unequal here. nil = undefined.
    static func strictEquals(_ lhs: SearchJSON?, _ rhs: SearchJSON?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (.array?, _), (.object?, _), (_, .array?), (_, .object?): return false
        default: return lhs == rhs
        }
    }

        // MARK: Text cleanup

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    private static func truncateChars(_ value: String, _ max: Int) -> String {
        guard SearchJSText.codePointCount(value) > max else { return value }
        return SearchJSText.prefix(value, codePoints: max - 1) + "…"
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
    private static func isASCIIHex(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
    }
    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

        /// Strip tags with `<[^>]*>`.
    private static func stripTags(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "<", let close = scalars[(index + 1)...].firstIndex(of: ">") {
                index = close + 1
                continue
            }
            out.append(scalars[index])
            index += 1
        }
        return out
    }

        /// Decode entities with `&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]+);`.
    private static func decodeEntities(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var index = 0
        func run(from start: Int, _ predicate: (Unicode.Scalar) -> Bool) -> Int {
            var end = start
            while end < scalars.count, predicate(scalars[end]) { end += 1 }
            return end
        }
        while index < scalars.count {
            guard scalars[index] == "&" else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let bodyStart = index + 1
            var replacement: [Unicode.Scalar]?
            var matchEnd = index
            if bodyStart + 1 < scalars.count, scalars[bodyStart] == "#", scalars[bodyStart + 1] == "x" {
                let digitsEnd = run(from: bodyStart + 2, isASCIIHex)
                let length = digitsEnd - (bodyStart + 2)
                if (1...6).contains(length), digitsEnd < scalars.count, scalars[digitsEnd] == ";" {
                    let hex = String(String.UnicodeScalarView(scalars[(bodyStart + 2)..<digitsEnd]))
                    replacement = [numericScalar(UInt32(hex, radix: 16))]
                    matchEnd = digitsEnd + 1
                }
            } else if bodyStart < scalars.count, scalars[bodyStart] == "#" {
                let digitsEnd = run(from: bodyStart + 1, isASCIIDigit)
                let length = digitsEnd - (bodyStart + 1)
                if (1...7).contains(length), digitsEnd < scalars.count, scalars[digitsEnd] == ";" {
                    let digits = String(String.UnicodeScalarView(scalars[(bodyStart + 1)..<digitsEnd]))
                    replacement = [numericScalar(UInt32(digits, radix: 10))]
                    matchEnd = digitsEnd + 1
                }
            } else {
                let lettersEnd = run(from: bodyStart, isASCIILetter)
                if lettersEnd > bodyStart, lettersEnd < scalars.count, scalars[lettersEnd] == ";" {
                    let name = String(String.UnicodeScalarView(scalars[bodyStart..<lettersEnd]))
                    replacement = entities[name].map { Array($0.unicodeScalars) } ?? Array(scalars[index...lettersEnd])
                    matchEnd = lettersEnd + 1
                }
            }
            if let replacement {
                out.append(contentsOf: replacement)
                index = matchEnd
            } else {
                out.append("&")
                index += 1
            }
        }
        return out
    }

    private static func numericScalar(_ code: UInt32?) -> Unicode.Scalar {
        guard let code, code > 0, code <= 0x10FFFF, !(0xD800...0xDFFF).contains(code),
              let scalar = Unicode.Scalar(code) else { return " " }
        return scalar
    }

        /// Text in a cleaned result: with html=true strip tags and decode entities; C0 / C1 control characters become spaces; runs of whitespace collapse to one space; trim both ends;
        /// truncate by code point (append … at the end).
    static func sanitizeSearchText(_ value: String?, html: Bool = false, maxChars: Int) -> String {
        guard let value else { return "" }
        var scalars = Array(value.unicodeScalars)
        if html {
            scalars = decodeEntities(stripTags(scalars))
        }
        var collapsed = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in scalars {
            let isControl = scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
            if isControl || SearchJSText.isWhitespace(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace, !collapsed.isEmpty { collapsed.append(" ") }
            pendingSpace = false
            collapsed.append(scalar)
        }
        return truncateChars(String(collapsed), maxChars)
    }

    private static func firstText(_ item: SearchJSON, _ paths: SearchJSON?, html: Bool, maxChars: Int) -> String {
        for path in paths?.arrayValue ?? [] {
            guard let dotted = path.stringValue else { continue }
            let value = SearchJSON.value(in: item, atPath: dotted)
            var text = ""
            if let string = value?.stringValue {
                text = string
            } else if let items = value?.arrayValue, items.allSatisfy({ $0.stringValue != nil }) {
                text = items.compactMap(\.stringValue).joined(separator: " … ")
            }
            let clean = sanitizeSearchText(text, html: html, maxChars: maxChars)
            if !clean.isEmpty { return clean }
        }
        return ""
    }

        /// `^https?:\/\/[^\s/?#]+` (case-insensitive); returns the original text with leading and trailing whitespace trimmed.
    private static func absoluteHTTPURL(_ value: SearchJSON?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = SearchJSText.trim(raw)
        let lowered = trimmed.lowercased()
        let prefixLength: Int
        if lowered.hasPrefix("https://") { prefixLength = 8 } else if lowered.hasPrefix("http://") { prefixLength = 7 } else { return nil }
        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.count > prefixLength else { return nil }
        let next = scalars[prefixLength]
        guard !SearchJSText.isWhitespace(next), next != "/", next != "?", next != "#" else { return nil }
        return trimmed
    }

        // MARK: Request construction

        /// Characters encodeURIComponent does not escape.
    static let uriComponentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return set
    }()

    private static func encodeURIComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? ""
    }

    private static func setPath(_ object: inout SearchJSONObject, _ dotted: String, _ value: SearchJSON) {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return }
        if parts.count == 1 {
            object[head] = value
            return
        }
        var child = object[head]?.objectValue ?? SearchJSONObject()
        setPath(&child, parts.dropFirst().joined(separator: "."), value)
        object[head] = .object(child)
    }

        /// spec: json_http/v1 description (the catalog entry's transport, or a custom service's mapping).
    static func buildSearchRequest(
        _ spec: SearchJSON,
        target: SearchRequestTarget,
        query: String,
        count: Int?,
        key: String?
    ) -> SearchRequestBuild {
        let declaredMax = spec["query"]?["maxChars"]?.clampedIntValue ?? SearchHardLimits.maxQueryChars
        let maxChars = min(declaredMax, SearchHardLimits.maxQueryChars)
        let q = SearchJSText.prefix(SearchJSText.trim(query), codePoints: maxChars)
                // An empty query sends no request (costs the user nothing); the caller treats it as "no results"
        if q.isEmpty { return .skip(reason: "query_empty") }
        let specMax = spec["count"]?["max"]?.clampedIntValue ?? SearchHardLimits.maxCount
                // A count that is not a positive integer (missing, 0, negative) falls back to the default 5 ("requested value || 5")
        let want = count.flatMap { $0 > 0 ? $0 : nil } ?? SearchHardLimits.defaultCount
        let n = max(1, min(want, specMax, SearchHardLimits.maxCount))

        var body = SearchJSONObject()
        var queryPairs: [(String, SearchJSON)] = []
        func put(_ location: String?, _ field: String, _ value: SearchJSON) {
            if location == "query" {
                queryPairs.append((field, value))
            } else {
                setPath(&body, field, value)
            }
        }
        put(spec["query"]?["in"]?.stringValue, spec["query"]?["field"]?.jsString ?? "undefined", .string(q))
        if let countSpec = spec["count"], countSpec.isTruthy {
            put(countSpec["in"]?.stringValue, countSpec["field"]?.jsString ?? "undefined", .int(Int64(n)))
        }
        var staticParams = spec["static"]?["params"]?.objectValue ?? SearchJSONObject()
        for (name, value) in target.staticParams?.entries ?? [] { staticParams[name] = value }
        let staticIn = spec["static"]?["in"].flatMap { $0.isNull ? nil : $0.stringValue } ?? spec["query"]?["in"]?.stringValue
        for name in staticParams.keys.sorted(by: SearchJSText.utf16Precedes) {
            put(staticIn, name, staticParams[name]!)
        }

        let port = target.port.map { $0 != 0 ? ":\($0)" : "" } ?? ""
        let path = target.path ?? spec["path"]?.stringValue ?? "/"
        let queryString = queryPairs.isEmpty
            ? ""
            : "?" + queryPairs.map { "\(encodeURIComponent($0.0))=\(encodeURIComponent($0.1.jsString))" }.joined(separator: "&")
        let method = spec["method"]?.stringValue ?? "GET"
        var headers = ["Accept": "application/json"]
        if method == "POST" { headers["Content-Type"] = "application/json" }
        if let key, !key.isEmpty {
            switch spec["auth"]?["kind"]?.stringValue {
            case "bearer": headers["Authorization"] = "Bearer \(key)"
            case "header":
                if let name = spec["auth"]?["name"]?.stringValue { headers[name] = key }
            default: break
            }
        }
        return .send(SearchHTTPRequest(
            method: method,
            url: "\(target.scheme)://\(target.host)\(port)\(path)\(queryString)",
            headers: headers,
            body: method == "POST" ? .object(body) : nil
        ))
    }

        // MARK: Response mapping

        /// 2xx response -> results / empty / error(parse_mismatch). Drops urls that are not absolute http(s); dedupes a result set by url; truncates to count.
    static func parseSearchResponse(_ spec: SearchJSON, body: SearchJSON?, count: Int?) -> SearchParseOutcome {
        let response = spec["response"]
        guard let list = SearchJSON.value(in: body, atPath: response?["results"]?.stringValue ?? "")?.arrayValue else {
            return .error(errorClass: "parse_mismatch")
        }
                // Same count rule as buildSearchRequest: a non-positive-integer becomes 5, then capped by the hard limit
        let n = min(count.flatMap { $0 > 0 ? $0 : nil } ?? SearchHardLimits.defaultCount, SearchHardLimits.maxCount)
        var seen = Set<String>()
        var results: [SearchResultItem] = []
        let html = response?["html"]?.boolValue == true
        for item in list {
            if results.count >= n { break }
            guard item.objectValue != nil else { continue }
            var url: String?
            for path in response?["url"]?.arrayValue ?? [] {
                url = absoluteHTTPURL(SearchJSON.value(in: item, atPath: path.stringValue ?? ""))
                if url != nil { break }
            }
            guard let url, !seen.contains(url) else { continue }
            seen.insert(url)
            let title = firstText(item, response?["title"], html: html, maxChars: SearchHardLimits.titleMaxChars)
            let site = firstText(item, response?["site"], html: html, maxChars: SearchHardLimits.siteMaxChars)
            let date = firstText(item, response?["date"], html: false, maxChars: SearchHardLimits.dateMaxChars)
            results.append(SearchResultItem(
                title: title.isEmpty ? url : title,
                url: url,
                snippet: firstText(item, response?["snippet"], html: html, maxChars: SearchHardLimits.snippetMaxChars),
                site: site.isEmpty ? nil : site,
                date: date.isEmpty ? nil : date
            ))
        }
        if !list.isEmpty && results.isEmpty { return .error(errorClass: "parse_mismatch") }
        return results.isEmpty ? .empty : .results(results)
    }

        // MARK: Error mapping

    struct ErrorClassDefinition: Sendable {
        let retryOnce: Bool
        let toolMessage: String
        let headline: String
        let primaryAction: String
    }

    static let errorClasses: [String: ErrorClassDefinition] = [
        "auth_invalid": .init(retryOnce: false, toolMessage: "unavailable", headline: "key_rejected", primaryAction: "update_key"),
        "insufficient_balance": .init(retryOnce: false, toolMessage: "unavailable", headline: "insufficient_balance", primaryAction: "top_up"),
        "rate_limited": .init(retryOnce: false, toolMessage: "unavailable", headline: "rate_limited", primaryAction: "retry_later"),
        "timeout": .init(retryOnce: false, toolMessage: "unavailable", headline: "no_response", primaryAction: "retry"),
        "network": .init(retryOnce: false, toolMessage: "unavailable", headline: "no_response", primaryAction: "retry"),
        "upstream_unavailable": .init(retryOnce: true, toolMessage: "unavailable", headline: "no_response", primaryAction: "retry"),
        "upstream_error": .init(retryOnce: false, toolMessage: "unavailable", headline: "service_error", primaryAction: "retry"),
        "request_rejected": .init(retryOnce: false, toolMessage: "unavailable", headline: "service_error", primaryAction: "switch_service"),
        "parse_mismatch": .init(retryOnce: false, toolMessage: "unavailable", headline: "format_mismatch", primaryAction: "switch_service"),
        "searxng_json_disabled": .init(retryOnce: false, toolMessage: "unavailable", headline: "searxng_json_disabled", primaryAction: "view_setup_guide"),
        "host_changed": .init(retryOnce: false, toolMessage: "unavailable", headline: "host_changed", primaryAction: "reconfirm"),
        "service_withdrawn": .init(retryOnce: false, toolMessage: "unavailable", headline: "service_withdrawn", primaryAction: "switch_service"),
        "response_too_large": .init(retryOnce: false, toolMessage: "unavailable", headline: "service_error", primaryAction: "switch_service"),
    ]

        /// Fixed messages returned to the model (English, identical on all three platforms; not localized).
    static let toolMessages: [String: String] = [
        "no_results": "The web search returned no results. Do not search again for this; answer from what you know and say that the search found nothing.",
        "unavailable": "Web search is not available right now. Do not call web_search again in this reply. Answer directly and tell the user you could not search the web.",
        "cap_reached": "The web search limit for this reply has been reached. Do not call web_search again. Answer from the results you already have.",
    ]

    static func classifySearchError(_ input: SearchErrorInput) -> SearchErrorClassification {
        var errorClass: String?
        switch input.transportFailure {
        case .timeout?: errorClass = "timeout"
        case .network?: errorClass = "network"
        case .tooLarge?: errorClass = "response_too_large"
                // No HTTP status, so retrying is pointless; treat as a rejected request
        case .blocked?: errorClass = "request_rejected"
        case nil:
            if input.preflight == .hostChanged {
                errorClass = "host_changed"
            } else if input.preflight == .serviceWithdrawn {
                errorClass = "service_withdrawn"
            } else if input.parseMismatch {
                errorClass = "parse_mismatch"
            }
        }
        if errorClass == nil {
            let status = input.status
            for rule in input.rules {
                                // Catalog entry rules are locked to a closed set by validateCatalogEntry; user-defined mappings skip rule validation, and unknown class names are not recognized
                guard let ruleClass = rule["class"]?.stringValue, errorClasses[ruleClass] != nil,
                      let ruleStatus = rule["status"]?.numberValue, let status, ruleStatus == Double(status) else { continue }
                if let match = rule["match"], match.isTruthy {
                    let actual = SearchJSON.value(in: input.body, atPath: match["path"]?.stringValue ?? "")
                    guard strictEquals(actual, match["equals"]) else { continue }
                }
                errorClass = ruleClass
                break
            }
            if errorClass == nil {
                switch status {
                case 401?, 403?: errorClass = "auth_invalid"
                case 402?: errorClass = "insufficient_balance"
                case 429?: errorClass = "rate_limited"
                                // HTTP 408 means upstream gave up waiting this time; like 502 / 503 it is retried once; a local timeout is transportFailure and is not retried
                case 408?, 502?, 503?: errorClass = "upstream_unavailable"
                case let code? where code >= 500: errorClass = "upstream_error"
                default: errorClass = "request_rejected"
                }
            }
        }
        let resolved = errorClass ?? "request_rejected"
        let definition = errorClasses[resolved]!
        return SearchErrorClassification(
            errorClass: resolved,
            retryOnce: definition.retryOnce,
            toolMessage: definition.toolMessage,
            card: searchErrorCard(resolved, custom: input.custom, otherServices: input.otherServices)
        )
    }

        /// Primary and secondary actions on the error card, shared by classifySearchError and the reply finish (SearchTurn.finishSearchReply). Unknown error classes are treated as request_rejected.
    static func searchErrorCard(_ errorClass: String, custom: Bool = false, otherServices: Int = 0) -> SearchErrorCard {
        let definition = errorClasses[errorClass] ?? errorClasses["request_rejected"]!
        var card = SearchErrorCard(headline: definition.headline, primaryAction: definition.primaryAction, secondaryAction: nil)
                // A custom service has no official link / catalog, so balance- and format-type primary actions become "Check settings"
        if custom, ["top_up", "switch_service"].contains(card.primaryAction), errorClass != "service_withdrawn" {
            card.primaryAction = "check_settings"
        }
                // A failure never switches service automatically; when other services exist, offer a "Switch to X" secondary action
                // On a local network failure no other service will connect either, so "Switch to X" is not offered
        if otherServices > 0, card.primaryAction != "switch_service", errorClass != "network" {
            card.secondaryAction = "switch_to_other_service"
        }
        return card
    }

        // MARK: Custom services

    static let customProtocols = ["searxng", "same_as", "manual"]

        /// Custom services (three protocols) carry no catalog limits, so this value is always used for the timeout (still bounded by maxTimeoutSec).
    static let customTimeoutSec = min(20, SearchHardLimits.maxTimeoutSec)

        /// SearXNG protocol: built into the client (not a catalog vendor), GET /search?format=json; an optional key is sent as Bearer.
    static let searxngSpec: SearchJSON = [
        "kind": .string(kind),
        "method": "GET",
        "auth": ["kind": "bearer"],
        "query": ["field": "q", "in": "query", "maxChars": .int(Int64(SearchHardLimits.maxQueryChars))],
        "count": nil,
        "static": ["in": "query", "params": ["format": "json"]],
        "response": [
            "results": "results", "title": ["title"], "url": ["url"], "snippet": ["content"],
            "date": ["publishedDate"], "html": true,
        ],
        "errors": [["status": 403, "class": "searxng_json_disabled"]],
    ]

        /// Web forwards through the server and can only reach ports the SSRF guard allows (mobile is not subject to this).
    static let webAllowedPorts = [80, 443, 8080, 8443]

    private static let headerNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+.^_`|~-".unicodeScalars)
    private static let blockedHeaders: Set<String> = [
        "host", "content-length", "content-type", "cookie", "connection", "transfer-encoding", "origin", "referer", "accept", "user-agent",
    ]
    private static let templateMarkers = ["{{", "${", "<%", "#{"]

    /// `^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$`
    static func isIdentPath(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        for part in value.split(separator: ".", omittingEmptySubsequences: false) {
            let scalars = Array(part.unicodeScalars)
            guard let first = scalars.first, isASCIILetter(first) || first == "_" else { return false }
            guard scalars.allSatisfy({ isASCIILetter($0) || isASCIIDigit($0) || $0 == "_" }) else { return false }
        }
        return true
    }

    private static func isHeaderName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        return (1...64).contains(scalars.count) && scalars.allSatisfy { headerNameCharacters.contains($0) }
    }

    private static func hasTemplate(_ value: SearchJSON?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return templateMarkers.contains { text.contains($0) }
    }

        /// Address split: accepts only ASCII hostnames or IPs; userinfo / fragment are rejected. nil = invalid.
    static func parseServiceAddress(_ address: String?) -> SearchServiceAddress? {
        guard let address else { return nil }
        let scalars = Array(SearchJSText.trim(address).unicodeScalars)
                // Any `#` implies a fragment (or a non-match overall); always rejected
        guard !scalars.contains("#"), let firstScalar = scalars.first, isASCIILetter(firstScalar) else { return nil }
        var index = 1
        while index < scalars.count,
              isASCIILetter(scalars[index]) || isASCIIDigit(scalars[index]) || ["+", ".", "-"].contains(scalars[index]) {
            index += 1
        }
        guard index + 3 <= scalars.count, scalars[index] == ":", scalars[index + 1] == "/", scalars[index + 2] == "/" else { return nil }
        let scheme = String(String.UnicodeScalarView(scalars[0..<index])).lowercased()
        let rest = Array(scalars[(index + 3)...])
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.count
        let authority = Array(rest[0..<authorityEnd])
        let afterAuthority = Array(rest[authorityEnd...])
        let queryStart = afterAuthority.firstIndex(of: "?") ?? afterAuthority.count
        let path = String(String.UnicodeScalarView(afterAuthority[0..<queryStart]))
        let query = String(String.UnicodeScalarView(afterAuthority[queryStart...]))
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        var hostScalars: [Unicode.Scalar]
        var portScalars: [Unicode.Scalar]?
        if authority.first == "[" {
            guard let close = authority.firstIndex(of: "]"), close > 1,
                  authority[1..<close].allSatisfy({ isASCIIHex($0) || $0 == ":" || $0 == "." }) else { return nil }
            hostScalars = Array(authority[0...close])
            let tail = Array(authority[(close + 1)...])
            if !tail.isEmpty {
                guard tail.first == ":" else { return nil }
                portScalars = Array(tail.dropFirst())
            }
        } else {
            let hostEnd = authority.firstIndex(of: ":") ?? authority.count
            hostScalars = Array(authority[0..<hostEnd])
            guard !hostScalars.isEmpty,
                  hostScalars.allSatisfy({ isASCIILetter($0) || isASCIIDigit($0) || $0 == "." || $0 == "-" }) else { return nil }
            if hostEnd < authority.count { portScalars = Array(authority[(hostEnd + 1)...]) }
        }
        var port: Int?
        if let portScalars {
            guard (1...5).contains(portScalars.count), portScalars.allSatisfy(isASCIIDigit) else { return nil }
            port = Int(String(String.UnicodeScalarView(portScalars)))
        }
        let host = String(String.UnicodeScalarView(hostScalars)).lowercased()
        if !host.hasPrefix("["), host.hasPrefix(".") || host.hasSuffix(".") || host.contains("..") { return nil }
        if let value = port, value < 1 || value > 65535 { return nil }
        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) { port = nil }
        return SearchServiceAddress(scheme: scheme, host: host, port: port, path: path, query: query)
    }

        /// Origin a key is bound to: scheme://host[:port] (default port omitted). A path change keeps the key; an origin change must clear it.
    static func keyBindingOrigin(_ address: String?) -> String? {
        guard let parsed = parseServiceAddress(address) else { return nil }
        return "\(parsed.scheme)://\(parsed.host)\(parsed.port.map { ":\($0)" } ?? "")"
    }

    static func addressChangeClearsKey(_ oldAddress: String?, _ newAddress: String?) -> Bool {
        keyBindingOrigin(oldAddress) != keyBindingOrigin(newAddress)
    }

    static func searxngPath(_ path: String) -> String {
        var base = path
        while base.hasSuffix("/") { base.removeLast() }
        return base.hasSuffix("/search") ? base : base + "/search"
    }

        /// Two paths in the same location (body or query string) that are equal, or where one is a prefix of the other (a and a.b), overwrite each other when expanded.
    private static func pathConflict(_ mapping: SearchJSON) -> Bool {
        var lists: [String: [String]] = ["body": [], "query": []]
        func push(_ location: String?, _ field: String) {
            guard let location, lists[location] != nil else { return }
            lists[location]!.append(field)
        }
        for key in ["query", "count"] {
            if let field = mapping[key]?["field"], field.isTruthy, let name = field.stringValue {
                push(mapping[key]?["in"]?.stringValue, name)
            }
        }
        let staticIn = mapping["static"]?["in"].flatMap { $0.isNull ? nil : $0.stringValue } ?? mapping["query"]?["in"]?.stringValue
        for name in mapping["static"]?["params"]?.objectValue?.keys ?? [] { push(staticIn, name) }
        for list in lists.values {
            for i in list.indices {
                for j in list.indices where i != j && (list[i] == list[j] || list[j].hasPrefix(list[i] + ".")) {
                    return true
                }
            }
        }
        return false
    }

        /// A user-pasted key (same for presets and custom): trimmed on save; empty -> key_empty; not 1-1024 printable ASCII characters
        /// (0x21-0x7E, i.e. no whitespace, control or non-ASCII characters) -> key_invalid, since it goes into an HTTP header. The saved value is sent as-is, unchanged.
    static func normalizeSearchKey(_ raw: String?) -> SearchKeyNormalization {
        let key = raw.map(SearchJSText.trim) ?? ""
        if key.isEmpty { return SearchKeyNormalization(ok: false, key: nil, error: "key_empty") }
        let scalars = key.unicodeScalars
        guard scalars.count <= 1024, scalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return SearchKeyNormalization(ok: false, key: nil, error: "key_invalid")
        }
        return SearchKeyNormalization(ok: true, key: key, error: nil)
    }

        /// Validates a manual mapping (json_http/v1 subset): returns an array of error codes; empty = valid.
    static func validateManualMapping(_ mapping: SearchJSON?) -> [String] {
        guard let mapping, mapping.objectValue != nil || mapping.arrayValue != nil else { return ["mapping_missing"] }
        var errors: [String] = []
        if !["GET", "POST"].contains(mapping["method"]?.stringValue ?? "") { errors.append("method_invalid") }
        let auth = mapping["auth"].flatMap { $0.isNull ? nil : $0 }
        let authKind = auth?["kind"]?.stringValue
        if !["bearer", "header", "none"].contains(authKind ?? "") { errors.append("auth_invalid") }
        if authKind == "header" {
            let rawName = auth?["name"]
            let name = rawName.flatMap { $0.isNull ? nil : $0.jsString } ?? ""
            if !isHeaderName(name) || blockedHeaders.contains((rawName?.jsString ?? "undefined").lowercased()) {
                errors.append("header_name_invalid")
            }
        }
        func fieldOK(_ field: SearchJSON?) -> Bool {
            guard let field, field.isTruthy, let name = field["field"]?.stringValue, isIdentPath(name),
                  let location = field["in"]?.stringValue else { return false }
            return ["body", "query"].contains(location)
        }
        if !fieldOK(mapping["query"]) { errors.append("query_field_invalid") }
        if let count = mapping["count"], !count.isNull, !fieldOK(count) { errors.append("count_field_invalid") }
        if mapping["method"]?.stringValue == "GET" {
            let staticIn = mapping["static"].flatMap { $0.isTruthy ? $0["in"]?.stringValue : nil }
            if mapping["query"]?["in"]?.stringValue == "body" || mapping["count"]?["in"]?.stringValue == "body" || staticIn == "body" {
                errors.append("get_has_body")
            }
        }
        let params = mapping["static"]?["params"]?.objectValue ?? SearchJSONObject()
        if params.count > 10 { errors.append("too_many_static_params") }
        for (name, value) in params.entries {
            if !isIdentPath(name) {
                errors.append("static_key_invalid")
            } else if !(value.boolValue != nil || value.isIntegral
                        || (value.stringValue.map { SearchJSText.codePointCount($0) <= 200 } ?? false)) {
                errors.append("static_value_invalid")
            } else if hasTemplate(value) {
                errors.append("template_rejected")
            }
        }
        let response = mapping["response"].flatMap { $0.isNull ? nil : $0 }
        if !isIdentPath(response?["results"]?.stringValue) { errors.append("results_path_invalid") }
        func pathsOK(_ value: SearchJSON?, required: Bool) -> Bool {
            guard let items = value?.arrayValue else { return false }
            if required && items.isEmpty { return false }
            return items.count <= 3 && items.allSatisfy { isIdentPath($0.stringValue) }
        }
        for key in ["title", "url", "snippet"] where !pathsOK(response?[key], required: true) {
            errors.append("\(key)_path_invalid")
        }
        for key in ["site", "date"] {
            if let value = response?[key], !pathsOK(value, required: false) { errors.append("\(key)_path_invalid") }
        }
        for value in [mapping["query"]?["field"], mapping["count"]?["field"], response?["results"]] where hasTemplate(value) {
            errors.append("template_rejected")
        }
        if pathConflict(mapping) { errors.append("path_conflict") }
        var seen = Set<String>()
        return errors.filter { seen.insert($0).inserted }
    }

        /// "Same as X": snapshots that vendor's mapping (host excluded) at save time, so later catalog changes do not affect the saved service.
    static func snapshotPresetMapping(_ entry: SearchJSON, regionId: String?) -> SearchJSON {
        let transport = entry["transport"]
        let region = SearchCatalog.region(of: entry, id: regionId) ?? entry["regions"]?.arrayValue?.first
        var params = transport?["static"]?["params"]?.objectValue ?? SearchJSONObject()
        for (name, value) in region?["static"]?.objectValue?.entries ?? [] { params[name] = value }
        let staticIn = transport?["static"]?["in"].flatMap { $0.isNull ? nil : $0 } ?? transport?["query"]?["in"] ?? .null
        let count = transport?["count"].flatMap { $0.isTruthy ? $0 : nil } ?? .null
        var snapshot = SearchJSONObject()
        snapshot["kind"] = .string(kind)
        snapshot["method"] = transport?["method"] ?? .null
        snapshot["auth"] = .object(transport?["auth"]?.objectValue ?? SearchJSONObject())
        snapshot["query"] = .object(transport?["query"]?.objectValue ?? SearchJSONObject())
        snapshot["count"] = count
        snapshot["static"] = params.isEmpty ? SearchJSON.null : SearchJSON.object(SearchJSONObject([("in", staticIn), ("params", .object(params))]))
        snapshot["response"] = transport?["response"] ?? .null
        snapshot["errors"] = transport?["errors"].flatMap { $0.isNull ? nil : $0 } ?? []
        snapshot["snapshotOf"] = ["serviceId": entry["id"] ?? .null, "region": region?["id"] ?? .null]
        return .object(snapshot)
    }

        /// Custom service form validation.
    static func validateCustomSearchService(_ input: CustomSearchServiceInput) -> CustomSearchServiceValidation {
        var errors: [String] = []
        var warnings: [String] = []
        let name = input.name.map(SearchJSText.trim) ?? ""
        if name.isEmpty {
            errors.append("name_empty")
        } else if SearchJSText.codePointCount(name) > 40 {
            errors.append("name_too_long")
        }
        let address = parseServiceAddress(input.address)
        if let address {
            if !["http", "https"].contains(address.scheme) {
                errors.append("scheme_not_allowed")
            } else if !address.query.isEmpty {
                errors.append("address_has_query")
            } else {
                let web = input.platform == .web
                if web && address.scheme == "http" { errors.append("http_not_allowed_on_web") }
                if web, let port = address.port, !webAllowedPorts.contains(port) { errors.append("port_not_allowed_on_web") }
                if web && input.addressClass == .lan { errors.append("private_address_on_web") }
                if !web && address.scheme == "http" && input.addressClass == .public { errors.append("http_public_not_allowed") }
                if !web && address.scheme == "http" && input.addressClass == .lan { warnings.append("cleartext_lan") }
                if input.addressClass == .unresolved { errors.append("address_unresolved") }
            }
        } else {
            errors.append("address_invalid")
        }
        let protocolID = input.protocolID ?? ""
        if !customProtocols.contains(protocolID) { errors.append("protocol_invalid") }
        if protocolID == "same_as" && !(input.catalogAvailable == true && input.presetActive == true) {
            errors.append("preset_unavailable")
        }
        if protocolID == "manual" { errors.append(contentsOf: validateManualMapping(input.manual)) }
        var requestPath: String?
        if let address, errors.isEmpty {
            requestPath = protocolID == "searxng" ? searxngPath(address.path) : (address.path.isEmpty ? "/" : address.path)
        }
        var seen = Set<String>()
        return CustomSearchServiceValidation(
            ok: errors.isEmpty,
            errors: errors.filter { seen.insert($0).inserted },
            warnings: warnings,
            origin: address == nil ? nil : keyBindingOrigin(input.address),
            requestPath: requestPath
        )
    }

        /// What happens to each service class when the preset catalog is unavailable (404 / signature verification failed / no snapshot). protocolID: preset | searxng | same_as | manual.
    static func catalogOutageBehavior(protocolID: String, saved: Bool, catalogAvailable: Bool) -> SearchCatalogOutageBehavior {
        if catalogAvailable { return SearchCatalogOutageBehavior(usable: true, creatable: true, presentation: nil) }
        if protocolID == "preset" { return SearchCatalogOutageBehavior(usable: false, creatable: false, presentation: "presets_unavailable") }
        if protocolID == "same_as" { return SearchCatalogOutageBehavior(usable: saved, creatable: false, presentation: nil) }
        return SearchCatalogOutageBehavior(usable: true, creatable: true, presentation: nil)
    }
}
