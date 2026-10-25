import Foundation

/// Capability negative cache (v2).
///
/// Entry key = connection x model x wire family x capability key (`vision_input`, `param:temperature`, ...).
/// Value = recorded time / signature ID / verdict revision at the time of recording; an entry is valid for 7 days.
/// A read whose revision differs from the current verdict is a miss, but the entry is kept (it can hit again
/// if the verdict flips back).
/// Stored in UserDefaults `capability_negative_cache.v2`; not part of backups.
nonisolated final class CapabilityNegativeCache: @unchecked Sendable {
    static let storageKey = "capability_negative_cache.v2"
    static let ttl: TimeInterval = 604_800
    static let shared = CapabilityNegativeCache()

    /// Verdict fields that take part in the revision; every other field stays out of the canonical form.
    struct Verdict: Sendable, Equatable {
        var state: String?
        var reasonCode: String?
        var wireFamily: String?
        var sourceRefs: [String]?

        init(state: String?, reasonCode: String? = nil, wireFamily: String? = nil, sourceRefs: [String]? = nil) {
            self.state = state
            self.reasonCode = reasonCode
            self.wireFamily = wireFamily
            self.sourceRefs = sourceRefs
        }

        /// A missing verdict counts as `{"state":"unknown"}`.
        static let missing = Verdict(state: "unknown")
    }

    struct Entry: Codable, Equatable, Sendable {
        let connectionId: String
        let modelId: String
        let wireFamily: String
        let capabilityKey: String
        let recordedAt: TimeInterval
        let signatureId: String
        let verdictRevision: String
    }

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// In-process decoded copy: the chat screen asks about capabilities on every render, so the whole list
    /// is not decoded from UserDefaults each time. Any write (including clearing) invalidates it; it is not
    /// shared across processes.
    private var cachedEntries: [Entry]?

    init(defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    // MARK: - verdictRevision

    /// Canonical JSON: only state / reasonCode / wireFamily / sourceRefs, keys in lexicographic order,
    /// nil omitted, sourceRefs ascending, no whitespace. A nil verdict is `{"state":"unknown"}`.
    static func canonical(_ verdict: Verdict?) -> String {
        let verdict = verdict ?? .missing
        var parts: [String] = []
        if let reasonCode = verdict.reasonCode { parts.append("\"reasonCode\":\(jsonString(reasonCode))") }
        if let refs = verdict.sourceRefs {
            // Same ordering as the JS default sort: compare by UTF-16 code units.
            let sorted = refs.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            parts.append("\"sourceRefs\":[\(sorted.map(jsonString).joined(separator: ","))]")
        }
        if let state = verdict.state { parts.append("\"state\":\(jsonString(state))") }
        if let wireFamily = verdict.wireFamily { parts.append("\"wireFamily\":\(jsonString(wireFamily))") }
        return "{\(parts.joined(separator: ","))}"
    }

    /// 32-bit FNV-1a over the UTF-8 bytes of the canonical form, as lowercase hex zero-padded to 8 digits.
    static func verdictRevision(_ verdict: Verdict?) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in canonical(verdict).utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// String escaping identical to JSON.stringify: only `"`, `\` and U+0000-U+001F are escaped.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Storage

    func record(
        connectionId: String, modelId: String, wireFamily: String, capabilityKey: String,
        signatureId: String, verdictRevision: String, at date: Date? = nil
    ) {
        let recordedAt = (date ?? clock()).timeIntervalSince1970
        mutate { entries in
            // Keep only the newest entry per key: a fresh rejection restarts the 7 days.
            entries.removeAll {
                Self.sameKey($0, connectionId, modelId, wireFamily, capabilityKey)
            }
            entries.append(Entry(
                connectionId: connectionId, modelId: modelId, wireFamily: wireFamily,
                capabilityKey: capabilityKey, recordedAt: recordedAt,
                signatureId: signatureId, verdictRevision: verdictRevision
            ))
            // Drop expired entries on the way so storage does not grow forever.
            entries.removeAll { recordedAt - $0.recordedAt >= Self.ttl }
        }
    }

    /// A hit = same key, within 7 days, and the revision matches the current verdict. A revision mismatch
    /// is only a miss; the entry stays.
    func isRejected(
        connectionId: String, modelId: String, wireFamily: String, capabilityKey: String,
        verdictRevision: String, now: Date? = nil
    ) -> Bool {
        guard let entry = entry(
            connectionId: connectionId, modelId: modelId, wireFamily: wireFamily, capabilityKey: capabilityKey
        ) else { return false }
        let current = (now ?? clock()).timeIntervalSince1970
        return entry.verdictRevision == verdictRevision && current - entry.recordedAt < Self.ttl
    }

    /// The stored entry as is (ignores TTL and revision).
    func entry(connectionId: String, modelId: String, wireFamily: String, capabilityKey: String) -> Entry? {
        load().first { Self.sameKey($0, connectionId, modelId, wireFamily, capabilityKey) }
    }

    func clear(connectionId: String, modelId: String, wireFamily: String, capabilityKeys: Set<String>) {
        mutate { entries in
            entries.removeAll {
                $0.connectionId == connectionId && $0.modelId == modelId
                    && $0.wireFamily == wireFamily && capabilityKeys.contains($0.capabilityKey)
            }
        }
    }

    func clearConnection(_ connectionId: String) {
        mutate { entries in entries.removeAll { $0.connectionId == connectionId } }
    }

    private static func sameKey(
        _ entry: Entry, _ connectionId: String, _ modelId: String, _ wireFamily: String, _ capabilityKey: String
    ) -> Bool {
        entry.connectionId == connectionId && entry.modelId == modelId
            && entry.wireFamily == wireFamily && entry.capabilityKey == capabilityKey
    }

    private func load() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEntries { return cachedEntries }
        let entries = decode()
        cachedEntries = entries
        return entries
    }

    private func mutate(_ body: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = decode()
        body(&entries)
        cachedEntries = nil
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Corrupt data is treated as empty: the cache only speeds up decisions, so losing it costs at most
    /// one more upstream rejection.
    private func decode() -> [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
