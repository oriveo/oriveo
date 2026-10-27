import CryptoKit
import Foundation

// MARK: - External search catalog search-catalog/v1 (external search services contract)
//
// Function-by-function port of scripts/lib/search-catalog.mjs (same names on all three platforms): canonicalCatalogJson / verifyCatalogSignature /
// acceptSearchCatalog / regionForConnection / presetHostCheck / regionLinks. Entries stay raw JSON,
// validated field by field like the reference implementation rather than decoded into strong types first (otherwise unknown fields and illegal shapes could not be skipped per entry).

nonisolated enum SearchCatalogError: Error, Equatable {
    /// The catalog contains a number that is not an integer or exceeds the safe-integer range (prices are always written as strings).
    case nonIntegerNumber
}

nonisolated enum SearchCatalogSource: String, Codable, Sendable {
    case network
    case cache
    case builtin
}

/// Entry limits after the client's hard caps have been applied.
nonisolated struct SearchCatalogLimits: Codable, Sendable, Equatable {
    var timeoutSec: Int
    var maxCount: Int
}

nonisolated struct SearchCatalogServiceStatus: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case active
        case withdrawn
    }

    var id: String
    var status: Status
    var limits: SearchCatalogLimits?
}

nonisolated struct SearchCatalogCurrent: Codable, Sendable, Equatable {
    var revision: Int
    var services: [SearchCatalogServiceStatus]
}

/// Local adoption state: the highest revision seen (anti-rollback; the built-in snapshot is bound by it too) and the currently adopted catalog.
nonisolated struct SearchCatalogState: Codable, Sendable, Equatable {
    var maxSeenRevision: Int
    var current: SearchCatalogCurrent?

    static let empty = SearchCatalogState(maxSeenRevision: 0, current: nil)
}

nonisolated struct SearchCatalogSkip: Codable, Sendable, Equatable {
    var id: String?
    var reason: String
}

nonisolated struct SearchCatalogAcceptance: Codable, Sendable, Equatable {
    var accepted: Bool
    var reason: String?
    var source: SearchCatalogSource?
    var maxSeenRevision: Int
    var current: SearchCatalogCurrent?
    var skipped: [SearchCatalogSkip]?

    /// Local state after adoption (not adopted = unchanged state).
    var state: SearchCatalogState {
        SearchCatalogState(maxSeenRevision: maxSeenRevision, current: current)
    }
}

nonisolated struct SearchCatalogSignatureVerdict: Sendable, Equatable {
    var ok: Bool
    var reason: String?
}

/// Result of the host check before a key is sent.
nonisolated enum PresetHostVerdict: String, Codable, Sendable {
    case ok
    case hostChanged = "host_changed"
    case serviceWithdrawn = "service_withdrawn"
}

/// How to handle the result of fetching `?view=search` (metadata view contract).
nonisolated enum SearchCatalogFetchAction: String, Codable, Sendable {
    /// 200: hand to acceptSearchCatalog.
    case adopt
    /// 304, any other status, network error: keep the one in hand.
    case keep
    /// 404: the Server explicitly says the catalog is unavailable / withdrawn as a whole; the whole preset block shows "unavailable" (including cache and built-in snapshot).
    case withdrawPresets = "withdraw_presets"
}

/// The official links to show for a site.
nonisolated struct SearchRegionLinks: Codable, Sendable, Equatable {
    var homepage: String?
    var docs: String?
    var terms: String?
    var keyHelp: String?
    var pricing: String?
}

nonisolated enum SearchCatalog {
    static let schema = "search-catalog/v1"

        // MARK: Canonical JSON and signature

        /// Canonical JSON (signature input): object keys in ascending UTF-16 code unit order, no whitespace, strings escaped as JSON.stringify does;
        /// numbers must be safe integers, and a non-integer is an immediate error. Arrays keep their order.
    static func canonicalCatalogJson(_ value: SearchJSON) throws -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int, .double:
            guard let integer = value.safeIntegerValue else { throw SearchCatalogError.nonIntegerNumber }
            return String(integer)
        case .string(let text): return SearchJSON.quoted(text)
        case .array(let items):
            return "[" + (try items.map { try canonicalCatalogJson($0) }).joined(separator: ",") + "]"
        case .object(let object):
            let keys = object.keys.sorted(by: SearchJSText.utf16Precedes)
            let parts = try keys.map { key in
                SearchJSON.quoted(key) + ":" + (try canonicalCatalogJson(object[key]!))
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    private static func signingPayload(_ doc: SearchJSON) throws -> Data {
        var rest = doc.objectValue ?? SearchJSONObject()
        rest["signature"] = nil
        return Data(try canonicalCatalogJson(.object(rest)).utf8)
    }

        /// trustedKeys: keyId -> base64 of the raw 32-byte Ed25519 public key (built into the client).
    static func verifyCatalogSignature(_ doc: SearchJSON?, trustedKeys: [String: String]) -> SearchCatalogSignatureVerdict {
        guard let signature = doc?["signature"], signature.isTruthy,
              signature["alg"]?.stringValue == "ed25519",
              let value = signature["value"]?.stringValue else {
            return SearchCatalogSignatureVerdict(ok: false, reason: "signature_missing")
        }
        guard let keyID = signature["keyId"]?.stringValue, let key = trustedKeys[keyID] else {
            return SearchCatalogSignatureVerdict(ok: false, reason: "signature_unknown_key")
        }
        var ok = false
        if let doc,
           let raw = Data(base64Encoded: key),
           let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
           let signatureBytes = Data(base64Encoded: value),
           let payload = try? signingPayload(doc) {
            ok = publicKey.isValidSignature(signatureBytes, for: payload)
        }
        return ok
            ? SearchCatalogSignatureVerdict(ok: true, reason: nil)
            : SearchCatalogSignatureVerdict(ok: false, reason: "signature_invalid")
    }

        // MARK: Entry validation

    private static let regionURLKeys = ["docs", "pricing", "keyHelp"]

    /// `^[a-z][a-z0-9_]{1,31}$`
    static func isCatalogID(_ value: String?) -> Bool {
        guard let value else { return false }
        let scalars = Array(value.unicodeScalars)
        guard (2...32).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

        /// `^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`: only lowercase ASCII hostnames are accepted, not IPs.
    static func isCatalogHostname(_ value: String?) -> Bool {
        guard let value else { return false }
        let scalars = Array(value.unicodeScalars)
        guard (1...253).contains(scalars.count) else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        guard labels.count >= 2, let tld = labels.last,
              (2...63).contains(tld.count), tld.allSatisfy({ ("a"..."z").contains($0) }) else { return false }
        for label in labels.dropLast() {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }),
                  label.first != "-", label.last != "-" else { return false }
        }
        return true
    }

    /// `^https:\/\/[^\s/?#]+`
    static func isHTTPSURL(_ value: SearchJSON?) -> Bool {
        guard let text = value?.stringValue else { return false }
        let scalars = Array(text.unicodeScalars)
        let prefix = Array("https://".unicodeScalars)
        guard scalars.count > prefix.count, Array(scalars[0..<prefix.count]) == prefix else { return false }
        let next = scalars[prefix.count]
        return !SearchJSText.isWhitespace(next) && next != "/" && next != "?" && next != "#"
    }

    /// `^\d{4}-\d{2}-\d{2}$`
    static func isCatalogDate(_ value: SearchJSON?) -> Bool {
        guard let text = value?.stringValue else { return false }
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 {
                guard scalar == "-" else { return false }
            } else {
                guard ("0"..."9").contains(scalar) else { return false }
            }
        }
        return true
    }

    private static func validTransport(_ transport: SearchJSON?) -> String? {
        guard let transport, transport.isTruthy, transport["kind"]?.stringValue == SearchTransport.kind else {
            return "unsupported_transport"
        }
        guard let method = transport["method"]?.stringValue, ["GET", "POST"].contains(method) else { return "transport_invalid" }
        guard let path = transport["path"]?.stringValue, path.hasPrefix("/") else { return "transport_invalid" }
        guard let auth = transport["auth"]?["kind"]?.stringValue, ["bearer", "header"].contains(auth) else { return "transport_invalid" }
        guard transport["query"]?["field"]?.isTruthy == true,
              let queryIn = transport["query"]?["in"]?.stringValue, ["body", "query"].contains(queryIn) else { return "transport_invalid" }
        guard transport["response"]?["results"]?.isTruthy == true,
              transport["response"]?["url"]?.arrayValue != nil,
              transport["response"]?["title"]?.arrayValue != nil else { return "transport_invalid" }
        for (key, value) in transport["static"]?["params"]?.objectValue?.entries ?? [] {
            if !SearchTransport.staticParamAllowed(key, value) { return "static_param_not_allowed" }
        }
                // Dedicated error rules: status codes 400-599, class names in the closed set, match is string equality only; a non-conforming rule skips the whole entry so platforms do not each improvise for unknown classes
        if let errors = transport["errors"] {
            guard let rules = errors.arrayValue else { return "transport_invalid" }
            for rule in rules {
                guard rule.objectValue != nil, let status = rule["status"]?.safeIntegerValue, (400...599).contains(status),
                      let ruleClass = rule["class"]?.stringValue, SearchTransport.errorClasses[ruleClass] != nil else {
                    return "transport_invalid"
                }
                if let match = rule["match"], !match.isNull {
                    guard match.objectValue != nil, let path = match["path"]?.stringValue, !path.isEmpty,
                          match["equals"]?.stringValue != nil else { return "transport_invalid" }
                }
            }
        }
        return nil
    }

        /// Single-entry validation: nil = usable, otherwise the skip reason (only this entry is skipped, the whole catalog is not rejected).
    static func validateCatalogEntry(_ entry: SearchJSON?) -> String? {
        guard let entry, entry.objectValue != nil, isCatalogID(entry["id"]?.stringValue) else { return "entry_invalid" }
        if let tombstone = entry["tombstone"], tombstone.isTruthy {
            return isCatalogDate(tombstone["at"]) ? nil : "entry_invalid"
        }
        guard let displayName = entry["displayName"]?.stringValue, !displayName.isEmpty else { return "entry_invalid" }
        guard let group = entry["group"]?.stringValue, ["domestic", "overseas"].contains(group) else { return "entry_invalid" }
        for key in ["homepage", "docs", "terms", "keyHelp"] where !isHTTPSURL(entry["urls"]?[key]) {
            return "entry_invalid"
        }
        guard isHTTPSURL(entry["pricing"]?["sourceUrl"]) else { return "entry_invalid" }
        guard let regions = entry["regions"]?.arrayValue, !regions.isEmpty else { return "entry_invalid" }
        for region in regions {
            guard isCatalogID(region["id"]?.stringValue), isCatalogHostname(region["host"]?.stringValue) else { return "host_invalid" }
            for (key, value) in region["static"]?.objectValue?.entries ?? [] {
                if !SearchTransport.staticParamAllowed(key, value) { return "static_param_not_allowed" }
            }
                        // Site-level links are optional; only known keys are validated and unknown keys are ignored (adding a key later must not make old clients skip the whole entry)
            if let urls = region["urls"] {
                guard let object = urls.objectValue else { return "entry_invalid" }
                for key in regionURLKeys where object[key] != nil && !isHTTPSURL(object[key]) {
                    return "entry_invalid"
                }
            }
        }
        if let error = validTransport(entry["transport"]) { return error }
        guard let timeout = entry["limits"]?["timeoutSec"], timeout.isIntegral, let seconds = timeout.numberValue, seconds >= 1 else {
            return "entry_invalid"
        }
        guard let storage = entry["citationStorage"]?.stringValue, ["full", "urlTitleOnly"].contains(storage) else { return "entry_invalid" }
        guard entry["trust"]?["entity"]?.stringValue != nil,
              let evidence = entry["trust"]?["evidence"]?.arrayValue, !evidence.isEmpty,
              evidence.allSatisfy({ isHTTPSURL($0) }),
              isCatalogDate(entry["trust"]?["reviewedAt"]) else { return "trust_invalid" }
        if let reuse = entry["reuse"], reuse.isTruthy {
            guard reuse["providerKind"]?.stringValue != nil else { return "entry_invalid" }
            for (host, region) in reuse["regionByConnectionHost"]?.objectValue?.entries ?? [] {
                guard isCatalogHostname(host),
                      regions.contains(where: { $0["id"] != nil && $0["id"] == region }) else { return "entry_invalid" }
            }
        }
        return nil
    }

        /// Hard client-side cap: whatever size the catalog gives, truncate to this. Call only for entries that passed validation.
    static func clampedLimits(_ entry: SearchJSON) -> SearchCatalogLimits {
        let timeout = entry["limits"]?["timeoutSec"]?.integerValue ?? Int64(SearchHardLimits.maxTimeoutSec)
        let countMax = entry["transport"]?["count"]?["max"]?.clampedIntValue ?? SearchHardLimits.maxCount
        return SearchCatalogLimits(
            timeoutSec: Int(min(timeout, Int64(SearchHardLimits.maxTimeoutSec))),
            maxCount: min(countMax, SearchHardLimits.maxCount)
        )
    }

        // MARK: Adoption

        /// Adopt a catalog. Rules: signature fails -> not adopted, keep the previous one; revision below the highest seen locally -> not adopted (anti-rollback, the built-in snapshot included);
        /// equal -> unchanged; entries are validated one by one and a non-conforming one is skipped alone; tombstone -> withdrawn, immediately stop sending keys to that service.
    static func acceptSearchCatalog(
        state: SearchCatalogState,
        incoming: SearchJSON?,
        source: SearchCatalogSource,
        trustedKeys: [String: String]
    ) -> SearchCatalogAcceptance {
        func keep(_ reason: String) -> SearchCatalogAcceptance {
            SearchCatalogAcceptance(accepted: false, reason: reason, source: nil,
                                    maxSeenRevision: state.maxSeenRevision, current: state.current, skipped: nil)
        }
        guard incoming?["schema"]?.stringValue == schema else { return keep("schema_mismatch") }
        guard let revision = incoming?["revision"]?.safeIntegerValue, revision >= 1 else { return keep("revision_invalid") }
        let signature = verifyCatalogSignature(incoming, trustedKeys: trustedKeys)
        guard signature.ok else { return keep(signature.reason ?? "signature_invalid") }
        if revision < state.maxSeenRevision { return keep("revision_rollback") }
        if let current = state.current, revision == current.revision { return keep("unchanged") }
        var services: [SearchCatalogServiceStatus] = []
        var skipped: [SearchCatalogSkip] = []
        for entry in incoming?["services"]?.arrayValue ?? [] {
            if let reason = validateCatalogEntry(entry) {
                skipped.append(SearchCatalogSkip(id: entry["id"]?.stringValue, reason: reason))
                continue
            }
            let id = entry["id"]?.stringValue ?? ""
            if entry["tombstone"]?.isTruthy == true {
                services.append(SearchCatalogServiceStatus(id: id, status: .withdrawn, limits: nil))
            } else {
                services.append(SearchCatalogServiceStatus(id: id, status: .active, limits: clampedLimits(entry)))
            }
        }
        return SearchCatalogAcceptance(
            accepted: true,
            reason: nil,
            source: source,
            maxSeenRevision: max(state.maxSeenRevision, revision),
            current: SearchCatalogCurrent(revision: revision, services: services),
            skipped: skipped
        )
    }

        // MARK: Sites, hosts, links

        /// When reusing a model connection, pick the site by the connection address (Kimi .cn / .ai); an address not in the table = not reusable.
    static func regionForConnection(_ entry: SearchJSON?, connectionBaseUrl: String?) -> String? {
        var text = connectionBaseUrl ?? ""
        let lowered = text.lowercased()
        if lowered.hasPrefix("https://") {
            text = String(text.unicodeScalars.dropFirst(8))
        } else if lowered.hasPrefix("http://") {
            text = String(text.unicodeScalars.dropFirst(7))
        }
        let host = String(text.unicodeScalars.prefix { !["/", ":", "?", "#"].contains($0) }).lowercased()
        return entry?["reuse"]?["regionByConnectionHost"]?[host]?.stringValue
    }

        /// Host check before sending a key: the host a saved service is bound to differs from the current catalog's host for that site -> host_changed (no key sent, re-confirmation required);
        /// entry withdrawn -> service_withdrawn (stop sending keys).
    static func presetHostCheck(
        boundHost: String?,
        entry: SearchJSON?,
        regionId: String?,
        withdrawn: Bool = false
    ) -> PresetHostVerdict {
        if withdrawn || entry?["tombstone"]?.isTruthy == true { return .serviceWithdrawn }
        guard let region = (entry?["regions"]?.arrayValue ?? []).first(where: { regionMatches($0, regionId) }) else {
            return .serviceWithdrawn
        }
        return region["host"]?.stringValue == boundHost ? .ok : .hostChanged
    }

        /// The official links to show for a site: docs / pricing / keyHelp take the site's `regions[].urls` first, falling back key by key to the entry level
        /// (`urls.docs` / `pricing.sourceUrl` / `urls.keyHelp`); homepage / terms exist only at entry level. Site not found = use entry level throughout.
        /// Call only for entries that passed validation.
    static func regionLinks(_ entry: SearchJSON, regionId: String?) -> SearchRegionLinks {
        let own = (entry["regions"]?.arrayValue ?? []).first(where: { regionMatches($0, regionId) })?["urls"]
        func pick(_ key: String, fallback: SearchJSON?) -> String? {
            if let value = own?[key], !value.isNull { return value.stringValue }
            return fallback?.stringValue
        }
        return SearchRegionLinks(
            homepage: entry["urls"]?["homepage"]?.stringValue,
            docs: pick("docs", fallback: entry["urls"]?["docs"]),
            terms: entry["urls"]?["terms"]?.stringValue,
            keyHelp: pick("keyHelp", fallback: entry["urls"]?["keyHelp"]),
            pricing: pick("pricing", fallback: entry["pricing"]?["sourceUrl"])
        )
    }

        /// 200 -> adopt; 404 -> withdraw_presets (a local flag is recorded, so the cache / built-in snapshot stay unused even after restart until a 200 is received and adopted successfully;
        /// custom services are unaffected); 304, any other status (including an old Server's 400), network error -> keep.
    static func catalogFetchAction(status: Int?, transportFailure: SearchTransportFailure?) -> SearchCatalogFetchAction {
        if transportFailure != nil { return .keep }
        if status == 200 { return .adopt }
        if status == 404 { return .withdrawPresets }
        return .keep
    }

    static func region(of entry: SearchJSON?, id regionId: String?) -> SearchJSON? {
        (entry?["regions"]?.arrayValue ?? []).first(where: { regionMatches($0, regionId) })
    }

    private static func regionMatches(_ region: SearchJSON, _ regionId: String?) -> Bool {
        guard let regionId else { return region["id"] == nil }
        return region["id"]?.stringValue == regionId
    }
}
