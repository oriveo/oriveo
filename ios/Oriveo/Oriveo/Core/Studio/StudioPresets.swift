import Foundation

/// Style / effect presets: envelope decoding, locale resolution, the bundled offline
/// snapshot and the refresh decision. Pure functions; the store that fetches and persists
/// comes later. Cases: `shared/studio-contracts/studio_presets.v1.json` clientCases;
/// executable reference: `scripts/lib/studio-image-reference.mjs` decodePresets /
/// resolvePresetLocale / localizePresets / planPresetRefresh / applyPresetResponse.
nonisolated enum StudioPresets {
    static let contractId = "studio_presets.v1"
    static let refreshIntervalMs: Int64 = 6 * 3600 * 1000
    static let defaultFragmentMaxChars = 160
    static let snapshotResource = "studio_presets_snapshot.v1"

    nonisolated struct Group: Equatable, Sendable {
        var id: String
        var order: Int
        var displayName: String
    }

    nonisolated struct Sample: Equatable, Sendable {
        var url: String
        var width: Int
        var height: Int
        var sha256: String
    }

    nonisolated struct Style: Equatable, Sendable {
        var id: String
        var group: String
        var order: Int
        var featured: Bool
        var displayName: String
        var description: String
        var promptFragment: String
        /// `#RRGGBB`, or `nil` when missing or malformed.
        var placeholderColor: String?
        /// `nil` when missing or malformed (the offline snapshot never has one).
        var sample: Sample?
    }

    nonisolated struct Effect: Equatable, Sendable {
        var id: String
        var group: String
        var order: Int
        var displayName: String
        var promptFragment: String
        var swatch: [String]
    }

    nonisolated enum EntryKind: String, Sendable {
        case style, effect
    }

    nonisolated enum DropReason: String, Sendable {
        case invalidField = "invalid_field"
        case fragmentTooLong = "fragment_too_long"
        case unknownGroup = "unknown_group"
        case duplicateId = "duplicate_id"
    }

    nonisolated struct Dropped: Equatable, Sendable {
        var kind: EntryKind
        var id: String?
        var reason: DropReason
    }

    nonisolated struct Catalog: Equatable, Sendable {
        var revision: String
        var locale: String
        var styleGroups: [Group]
        var effectGroups: [Group]
        var styles: [Style]
        var effects: [Effect]
        var dropped: [Dropped]
    }

    nonisolated enum DecodeError: String, Error, Sendable {
        case invalidEnvelope = "invalid_envelope"
        case unsupportedContract = "unsupported_contract"
    }

    /// Persisted next to the raw body of the last accepted response.
    nonisolated struct Cache: Codable, Equatable, Sendable {
        var locale: String
        var revision: String
        var etag: String?
        var checkedAtMs: Int64
    }

    nonisolated struct RefreshPlan: Equatable, Sendable {
        var fetch: Bool
        var ifNoneMatch: String?
    }

    /// One HTTP response; `status == 0` means the transport failed.
    nonisolated struct Response: Equatable, Sendable {
        var status: Int
        var etag: String?
        var body: Data?
    }

    nonisolated enum Outcome: String, Sendable {
        case notModified = "not_modified"
        case failed, invalid, unchanged, replaced
        /// Returned by the store only: the 6-hour window said not to fetch.
        case throttled
    }

    nonisolated struct Applied: Equatable, Sendable {
        var outcome: Outcome
        var cache: Cache?
        var bodyReplaced: Bool
    }

    // MARK: Decoding

    /// Raw response body → presets. Anything that is not a JSON envelope is `invalid_envelope`.
    static func decode(_ data: Data) -> Result<Catalog, DecodeError> {
        guard let envelope = try? JSONValue(data: data) else { return .failure(.invalidEnvelope) }
        return decode(envelope)
    }

    /// `{code,data,message}` envelope → presets; bad entries are dropped one by one and
    /// reported, unknown fields are ignored.
    static func decode(_ envelope: JSONValue?) -> Result<Catalog, DecodeError> {
        guard case .object(let env)? = envelope,
              case .number(let code)? = env["code"], code == 0,
              case .object(let data)? = env["data"]
        else { return .failure(.invalidEnvelope) }
        guard case .string(let contract)? = data["contractId"], same(contract, contractId) else {
            return .failure(.unsupportedContract)
        }
        guard let revision = nonEmptyString(data["revision"]),
              let locale = nonEmptyString(data["locale"]),
              case .array(let rawStyles)? = data["styles"],
              case .array(let rawEffects)? = data["effects"]
        else { return .failure(.invalidEnvelope) }
        let maxFragment = positiveInt(data["limits"]?["promptFragmentMaxChars"]) ?? defaultFragmentMaxChars
        let styleGroups = decodeGroups(data["styleGroups"])
        let effectGroups = decodeGroups(data["effectGroups"])
        let styles = decodeEntries(.style, rawStyles, styleGroups, maxFragment) { object, fields in
            let description = object["description"]?.stringValue ?? ""
            let placeholder = object["sample"]?["placeholderColor"]?.stringValue
            return Style(
                id: fields.id,
                group: fields.group,
                order: fields.order,
                featured: object["featured"] == .bool(true),
                displayName: fields.displayName,
                description: description,
                promptFragment: fields.promptFragment,
                placeholderColor: placeholder.flatMap { isHexColor($0) ? $0 : nil },
                sample: decodeSample(object["sample"])
            )
        }
        let effects = decodeEntries(.effect, rawEffects, effectGroups, maxFragment) { object, fields in
            let swatch = object["swatch"]?.arrayValue?.compactMap { value -> String? in
                guard let color = value.stringValue, isHexColor(color) else { return nil }
                return color
            } ?? []
            return Effect(
                id: fields.id,
                group: fields.group,
                order: fields.order,
                displayName: fields.displayName,
                promptFragment: fields.promptFragment,
                swatch: swatch
            )
        }
        return .success(Catalog(
            revision: revision,
            locale: locale,
            styleGroups: styleGroups,
            effectGroups: effectGroups,
            styles: styles.entries,
            effects: effects.entries,
            dropped: styles.dropped + effects.dropped
        ))
    }

    private struct EntryFields {
        var id: String
        var group: String
        var order: Int
        var displayName: String
        var promptFragment: String
    }

    /// A group without a non-empty id / integer order / non-empty name is skipped; the first
    /// valid group of an id wins. Sorted by order, then input position.
    private static func decodeGroups(_ list: JSONValue?) -> [Group] {
        var seen = Set<[UInt32]>()
        var out: [Group] = []
        for item in list?.arrayValue ?? [] {
            guard case .object(let group) = item,
                  let id = nonEmptyString(group["id"]),
                  let order = safeInt(group["order"]),
                  let displayName = nonEmptyString(group["displayName"])
            else { continue }
            guard seen.insert(scalarKey(id)).inserted else { continue }
            out.append(Group(id: id, order: order, displayName: displayName))
        }
        return out.enumerated()
            .sorted { $0.element.order != $1.element.order ? $0.element.order < $1.element.order : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Checks in order: invalid_field → fragment_too_long → unknown_group → duplicate_id (the
    /// first kept entry of an id wins). Kept entries sort by (group order, order, input position).
    private static func decodeEntries<Entry>(
        _ kind: EntryKind,
        _ list: [JSONValue],
        _ groups: [Group],
        _ maxFragment: Int,
        build: (JSONObject, EntryFields) -> Entry
    ) -> (entries: [Entry], dropped: [Dropped]) {
        var groupOrder: [[UInt32]: Int] = [:]
        for group in groups { groupOrder[scalarKey(group.id)] = group.order }
        var seen = Set<[UInt32]>()
        var kept: [(entry: Entry, groupOrder: Int, order: Int, index: Int)] = []
        var dropped: [Dropped] = []
        for (index, item) in list.enumerated() {
            let object = item.objectValue
            let id = nonEmptyString(object?["id"])
            let descriptionValue = object?["description"]
            let badDescription = kind == .style && descriptionValue != nil && descriptionValue?.stringValue == nil
            guard let object, let id,
                  let order = safeInt(object["order"]),
                  let displayName = nonEmptyString(object["displayName"]),
                  let promptFragment = nonEmptyString(object["promptFragment"]),
                  !badDescription
            else {
                dropped.append(Dropped(kind: kind, id: id, reason: .invalidField))
                continue
            }
            if promptFragment.unicodeScalars.count > maxFragment {
                dropped.append(Dropped(kind: kind, id: id, reason: .fragmentTooLong))
                continue
            }
            guard let group = object["group"]?.stringValue, let order0 = groupOrder[scalarKey(group)] else {
                dropped.append(Dropped(kind: kind, id: id, reason: .unknownGroup))
                continue
            }
            guard seen.insert(scalarKey(id)).inserted else {
                dropped.append(Dropped(kind: kind, id: id, reason: .duplicateId))
                continue
            }
            let fields = EntryFields(id: id, group: group, order: order, displayName: displayName, promptFragment: promptFragment)
            kept.append((build(object, fields), order0, order, index))
        }
        kept.sort { a, b in
            if a.groupOrder != b.groupOrder { return a.groupOrder < b.groupOrder }
            if a.order != b.order { return a.order < b.order }
            return a.index < b.index
        }
        return (kept.map(\.entry), dropped)
    }

    /// The whole sample is dropped when any of url / width / height / sha256 is unusable.
    private static func decodeSample(_ raw: JSONValue?) -> Sample? {
        guard case .object(let sample)? = raw,
              let url = nonEmptyString(sample["url"]),
              let width = positiveInt(sample["width"]),
              let height = positiveInt(sample["height"]),
              let sha256 = sample["sha256"]?.stringValue, isSHA256Hex(sha256)
        else { return nil }
        return Sample(url: url, width: width, height: height, sha256: sha256)
    }

    // MARK: Locale and offline snapshot

    /// Same order as the Server: exact (case-insensitive, `_` = `-`) → zh by script, then
    /// region → language subtag → en.
    static func resolveLocale(_ locales: [String], _ tag: String?) -> String {
        // Only ASCII whitespace is trimmed: each platform's trim strips a different Unicode set.
        let trimmed = trimmingASCIIWhitespace(tag ?? "")
        let normalized = String(String.UnicodeScalarView(trimmed.unicodeScalars.map { $0 == "_" ? "-" : $0 }))
        if normalized.isEmpty { return "en" }
        let lower = normalized.lowercased()
        if let exact = locales.first(where: { same($0.lowercased(), lower) }) { return exact }
        let parts = subtags(lower)
        if parts[0] == "zh" {
            let rest = parts.dropFirst()
            if rest.contains("hant") { return "zh-Hant" }
            if rest.contains("hans") { return "zh-Hans" }
            return rest.contains { $0 == "tw" || $0 == "hk" || $0 == "mo" } ? "zh-Hant" : "zh-Hans"
        }
        return locales.first { same(subtags($0.lowercased())[0], parts[0]) } ?? "en"
    }

    /// Offline snapshot → the same envelope the Server would send for `tag`, minus sample
    /// images (placeholder colour only). Feed the result to `decode(_:)`.
    static func localize(_ snapshot: JSONValue, _ tag: String?) -> JSONValue {
        let locales = snapshot["locales"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let locale = resolveLocale(locales, tag)
        func pick(_ map: JSONValue?) -> JSONValue? {
            if case .string(let text)? = map?[locale] { return .string(text) }
            return map?["en"]
        }
        func named(_ item: JSONValue) -> JSONObject {
            setting(item.objectValue ?? JSONObject(), [("displayName", pick(item["displayName"]))])
        }
        let styles = (snapshot["styles"]?.arrayValue ?? []).map { style -> JSONValue in
            let sample = JSONObject([("placeholderColor", style["sample"]?["placeholderColor"])].compactMap { key, value in
                value.map { (key, $0) }
            })
            return .object(setting(named(style), [("description", pick(style["description"])), ("sample", .object(sample))]))
        }
        let data: [(String, JSONValue?)] = [
            ("contractId", snapshot["contractId"]),
            ("revision", snapshot["revision"]),
            ("locale", .string(locale)),
            ("limits", snapshot["limits"]),
            ("styleGroups", .array((snapshot["styleGroups"]?.arrayValue ?? []).map { .object(named($0)) })),
            ("effectGroups", .array((snapshot["effectGroups"]?.arrayValue ?? []).map { .object(named($0)) })),
            ("styles", .array(styles)),
            ("effects", .array((snapshot["effects"]?.arrayValue ?? []).map { .object(named($0)) })),
        ]
        return .object(JSONObject([
            ("code", .number(0)),
            ("message", .string("ok")),
            ("data", .object(JSONObject(data.compactMap { key, value in value.map { (key, $0) } }))),
        ]))
    }

    /// The bundled text-only snapshot (a byte copy of the shared presets file without
    /// clientCases). Offline catalog = `decode(localize(snapshot, tag))`.
    static func bundledSnapshot(bundle: Bundle = .main) -> JSONValue? {
        let url = bundle.url(forResource: snapshotResource, withExtension: "json")
            ?? bundle.url(forResource: snapshotResource, withExtension: "json", subdirectory: "Core/Studio")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue(data: data)
    }

    // MARK: Refresh

    /// At most one request per locale every 6 hours; a clock that went back refetches.
    static func planRefresh(cache: Cache?, locale: String, nowMs: Int64) -> RefreshPlan {
        guard let cache, same(cache.locale, locale) else { return RefreshPlan(fetch: true, ifNoneMatch: nil) }
        let (age, overflow) = nowMs.subtractingReportingOverflow(cache.checkedAtMs)
        if !overflow, age >= 0, age < refreshIntervalMs { return RefreshPlan(fetch: false, ifNoneMatch: nil) }
        return RefreshPlan(fetch: true, ifNoneMatch: cache.etag)
    }

    /// Applies one response. Failures never touch the cache nor `checkedAtMs`; the body is
    /// replaced only when the revision or the locale changes.
    static func applyResponse(cache: Cache?, locale: String, nowMs: Int64, response: Response) -> Applied {
        let sameLocale = cache.map { same($0.locale, locale) } ?? false
        if response.status == 304, sameLocale, var touched = cache {
            touched.checkedAtMs = nowMs
            return Applied(outcome: .notModified, cache: touched, bodyReplaced: false)
        }
        if response.status != 200 { return Applied(outcome: .failed, cache: cache, bodyReplaced: false) }
        guard let body = response.body, case .success(let catalog) = decode(body) else {
            return Applied(outcome: .invalid, cache: cache, bodyReplaced: false)
        }
        if sameLocale, var touched = cache, same(touched.revision, catalog.revision) {
            touched.checkedAtMs = nowMs
            return Applied(outcome: .unchanged, cache: touched, bodyReplaced: false)
        }
        let replaced = Cache(locale: locale, revision: catalog.revision, etag: response.etag, checkedAtMs: nowMs)
        return Applied(outcome: .replaced, cache: replaced, bodyReplaced: true)
    }

    // MARK: Helpers

    /// Strict scalar equality (String == would treat canonically equivalent text as equal).
    private static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    private static func scalarKey(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    private static func subtags(_ tag: String) -> [String] {
        tag.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.isEmpty else { return nil }
        return text
    }

    /// Largest integer a JSON number carries exactly on every platform (2^53 - 1).
    private static let maxSafeInteger: Int = (1 << 53) - 1

    /// An integral JSON number within ±(2^53 - 1), like JavaScript `Number.isSafeInteger`.
    private static func safeInt(_ value: JSONValue?) -> Int? {
        guard let number = value?.intValue, number >= -maxSafeInteger, number <= maxSafeInteger else { return nil }
        return number
    }

    private static func positiveInt(_ value: JSONValue?) -> Int? {
        guard let number = safeInt(value), number > 0 else { return nil }
        return number
    }

    /// Strips leading / trailing TAB, LF, VT, FF, CR and SPACE only.
    private static func trimmingASCIIWhitespace(_ text: String) -> String {
        func isASCIISpace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09...0x0D, 0x20: return true
            default: return false
            }
        }
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isASCIISpace($0) }),
              let last = scalars.lastIndex(where: { !isASCIISpace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
        default: return false
        }
    }

    /// `#RRGGBB`, ASCII hex in either case.
    private static func isHexColor(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 7 && scalars[0] == "#" && scalars.dropFirst().allSatisfy(isHexDigit)
    }

    /// 64 lowercase ASCII hex digits.
    private static func isSHA256Hex(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 64 && scalars.allSatisfy { (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value) }
    }

    /// Copy of `object` with each key set to the new value, or removed when the value is nil.
    private static func setting(_ object: JSONObject, _ updates: [(String, JSONValue?)]) -> JSONObject {
        var pairs = object.keys.compactMap { key in object[key].map { (key, $0) } }
        for (key, value) in updates {
            pairs.removeAll { $0.0 == key }
            if let value { pairs.append((key, value)) }
        }
        return JSONObject(pairs)
    }
}
