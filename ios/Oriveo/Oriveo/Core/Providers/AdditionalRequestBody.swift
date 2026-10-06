import Foundation

/// Why the additional request body was rejected locally, and where.
///
/// `field` is only ever a name from the two closed lists (protected fields, blocked segments), so
/// it may appear on the error card and be persisted. Other key names the user wrote, and any
/// values, never appear here.
nonisolated struct AdditionalRequestBodyRejection: Error, Equatable, Hashable, Sendable {
    enum Reason: String, CaseIterable, Sendable {
        case invalidJSON = "invalid_json"
        case notObject = "not_object"
        case protectedField = "protected_field"
        case blockedSegment = "blocked_segment"
        case tooLarge = "too_large"
        case tooDeep = "too_deep"
    }

    let reason: Reason
    /// Set only for `protectedField` / `blockedSegment`.
    let field: String?
    /// 1-based line where `field` first appears as a key in the raw text. Nil when the key was
    /// written with escapes and cannot be located.
    let line: Int?

    init(reason: Reason, field: String? = nil, line: Int? = nil) {
        self.reason = reason
        self.field = field
        self.line = line
    }

    /// Stable safe code: only the reason and a closed-list field name, so it may be persisted and
    /// shown in the technical detail.
    var safeCode: String {
        var code = "additional_request_body_rejected:\(reason.rawValue)"
        if let field { code += ":\(field)" }
        if let line { code += "@\(line)" }
        return code
    }
}

/// Raw additional request body travelling with one request. It is passed in memory only and is
/// never encoded into messages or sync records.
nonisolated struct AdditionalRequestBodyPayload: Hashable, Sendable {
    let raw: String
}

/// Additional request body (`additionalBodyRules` in the shared contract
/// `generation_parameter_contract.v1.json`).
///
/// A JSON object written by the user, merged into the final request body after the panel
/// parameters and the capability writers are done: objects merge level by level, arrays and
/// scalars replace, and the additional request body wins for the same field. Fields of the request
/// skeleton cannot be written.
enum AdditionalRequestBody {
    static let maxBytes = 64 * 1024
    static let maxDepth = 32
    /// The same lists wire hardening uses: the skeleton is owned by the builder and no channel may
    /// overwrite it.
    nonisolated static var protectedRootFields: Set<String> { ProfileParamsResolver.builderOwnedRootFields }
    nonisolated static var blockedSegments: Set<String> { ProfileParamsResolver.blockedWireSegments }

    /// Error-card title key (Chat table) for an upstream 400 on a request that carried the
    /// additional request body. It doubles as the marker on the failed message that enables
    /// "retry without the additional request body", so it is defined only here.
    static let upstreamRejectionTitleKey = "Request with additional request body was rejected"
    static let localRejectionTitleKey = "Check the additional request body"

    /// Parses and validates the raw text. Order of checks: size, valid JSON, root is an object,
    /// depth, blocked segments, protected fields.
    nonisolated static func parse(_ raw: String) -> Result<[String: Any], AdditionalRequestBodyRejection> {
        guard raw.utf8.count <= maxBytes else { return .failure(.init(reason: .tooLarge)) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else {
            return .failure(.init(reason: .invalidJSON))
        }
        guard let object = value as? [String: Any] else { return .failure(.init(reason: .notObject)) }
        guard depth(of: object) <= maxDepth else { return .failure(.init(reason: .tooDeep)) }
        if let blocked = firstBlockedSegment(in: object) {
            return .failure(.init(
                reason: .blockedSegment, field: blocked, line: line(ofKey: blocked, in: raw, rootOnly: false)
            ))
        }
        // With several protected fields present, report the smallest by code-point order so every
        // client gives the same result.
        if let protected = object.keys.filter(protectedRootFields.contains).min() {
            return .failure(.init(
                reason: .protectedField, field: protected, line: line(ofKey: protected, in: raw, rootOnly: true)
            ))
        }
        return .success(object)
    }

    /// Objects merge level by level; arrays and scalars (including null) replace.
    nonisolated static func merge(_ addition: [String: Any], into body: inout [String: Any]) {
        for (key, incoming) in addition {
            if var existing = body[key] as? [String: Any], let nested = incoming as? [String: Any] {
                merge(nested, into: &existing)
                body[key] = existing
            } else {
                body[key] = incoming
            }
        }
    }

    /// The single entry point at the final request-body boundary: it has to run after the panel
    /// parameters and capability writers and before JSON encoding. Failed validation throws, so
    /// the caller sends nothing; there is no silent fallback that drops the body and sends anyway.
    static func apply(_ payload: AdditionalRequestBodyPayload?, to body: inout [String: Any]) throws {
        guard let payload else { return }
        switch parse(payload.raw) {
        case let .success(addition):
            guard !addition.isEmpty else { return }
            merge(addition, into: &body)
            CapabilityExecutionRuntime.recordAdditionalBodyApplied()
        case let .failure(rejection):
            throw ProviderServiceError.additionalRequestBodyRejected(rejection)
        }
    }

    // MARK: - Structural checks

    /// Container nesting depth; the root object counts as 1.
    private nonisolated static func depth(of value: Any) -> Int {
        if let object = value as? [String: Any] {
            return 1 + (object.values.map(depth(of:)).max() ?? 0)
        }
        if let array = value as? [Any] {
            return 1 + (array.map(depth(of:)).max() ?? 0)
        }
        return 0
    }

    private nonisolated static func firstBlockedSegment(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let hit = object.keys.filter(blockedSegments.contains).min() { return hit }
            // Descend in sorted key order so the hit does not depend on dictionary iteration order.
            for key in object.keys.sorted() {
                if let child = object[key], let hit = firstBlockedSegment(in: child) { return hit }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let hit = firstBlockedSegment(in: item) { return hit }
            }
        }
        return nil
    }

    /// Finds the line where a key first appears in raw text already known to be valid JSON. Only
    /// literally written key names match; with `rootOnly` only direct children of the root object
    /// are considered (protected fields count at the root only).
    private nonisolated static func line(ofKey key: String, in raw: String, rootOnly: Bool) -> Int? {
        let bytes = Array(raw.utf8)
        let needle = Array(key.utf8)
        var line = 1
        var depth = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 10: line += 1
            case 123, 91: depth += 1
            case 125, 93: depth -= 1
            case 34:
                let startLine = line
                var cursor = index + 1
                var hasEscape = false
                while cursor < bytes.count, bytes[cursor] != 34 {
                    if bytes[cursor] == 92 { hasEscape = true; cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == 10 { line += 1 }
                    cursor += 1
                }
                let content = bytes[(index + 1)..<min(cursor, bytes.count)]
                var after = cursor + 1
                while after < bytes.count, [9, 10, 13, 32].contains(bytes[after]) { after += 1 }
                let isKey = after < bytes.count && bytes[after] == 58
                if isKey, !hasEscape, content.elementsEqual(needle), !rootOnly || depth == 1 {
                    return startLine
                }
                index = cursor
            default: break
            }
            index += 1
        }
        return nil
    }
}

extension AdditionalRequestBodyRejection {
    /// One-sentence explanation shared by the editor and the error card. The field name comes
    /// from a closed list and is inserted verbatim.
    var localizedMessage: String {
        let sentence: String
        switch reason {
        case .invalidJSON:
            sentence = L10n.tr("The additional request body isn’t valid JSON.", table: .chat)
        case .notObject:
            sentence = L10n.tr("The additional request body must be a JSON object wrapped in { }.", table: .chat)
        case .protectedField:
            sentence = String(
                format: L10n.tr(
                    "“%@” is filled in by Oriveo and can’t be set in the additional request body.", table: .chat
                ),
                field ?? ""
            )
        case .blockedSegment:
            sentence = String(
                format: L10n.tr("“%@” can’t be used as a field name in the additional request body.", table: .chat),
                field ?? ""
            )
        case .tooLarge:
            sentence = L10n.tr("The additional request body is larger than 64 KB.", table: .chat)
        case .tooDeep:
            sentence = L10n.tr("The additional request body is nested more than 32 levels deep.", table: .chat)
        }
        guard let line else { return sentence }
        return String(format: L10n.tr("Line %lld: %@", table: .chat), line, sentence)
    }
}
