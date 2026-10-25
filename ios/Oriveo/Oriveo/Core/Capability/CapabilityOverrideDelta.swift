import Foundation

/// User overrides of input capabilities on a Relay connection, stored as per-key deltas.
///
/// Only the three input keys can be overridden; a key the user never touched follows the capability verdict
/// (its effective value is nil).
nonisolated enum CapabilityOverrideKey: String, CaseIterable, Codable, Hashable, Sendable, CodingKey {
    case visionInput = "vision_input"
    case fileInput = "file_input"
    case videoInput = "video_input"
}

nonisolated enum CapabilityOverrideOp: String, Codable, Hashable, Sendable {
    case add
    case remove
}

/// Per-key delta: when the user added or removed a capability, and against which verdict.
nonisolated struct CapabilityOverrideDelta: Hashable, Sendable, Codable {
    var op: CapabilityOverrideOp
    /// ISO8601 UTC, second precision (e.g. `2026-10-19T08:00:00Z`).
    var setAt: String
    /// The verbatim verdict state for this key at the time of the change (e.g. `unknown` / `auto_available`).
    var baseVerdict: String

    init(op: CapabilityOverrideOp, setAt: String, baseVerdict: String) {
        self.op = op
        self.setAt = setAt
        self.baseVerdict = baseVerdict
    }

    /// Entry-level validation: an unknown op, a setAt that is not ISO8601, or an empty baseVerdict makes a bad entry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(CapabilityOverrideOp.self, forKey: .op)
        setAt = try c.decode(String.self, forKey: .setAt)
        baseVerdict = try c.decode(String.self, forKey: .baseVerdict)
        guard CapabilityOverrideClock.parse(setAt) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .setAt, in: c, debugDescription: "setAt is not ISO8601")
        }
        guard !baseVerdict.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .baseVerdict, in: c, debugDescription: "empty baseVerdict")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op, setAt, baseVerdict
    }
}

/// Stored field `capabilityOverrides`: key -> delta. Decoding is tolerant per entry: keys outside the three
/// input keys and malformed entries are dropped individually without failing the whole table.
nonisolated struct CapabilityOverrides: Hashable, Sendable, Codable {
    var entries: [CapabilityOverrideKey: CapabilityOverrideDelta]

    init(_ entries: [CapabilityOverrideKey: CapabilityOverrideDelta] = [:]) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    subscript(key: CapabilityOverrideKey) -> CapabilityOverrideDelta? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CapabilityOverrideKey.self)
        var entries: [CapabilityOverrideKey: CapabilityOverrideDelta] = [:]
        for key in c.allKeys {
            if let delta = try? c.decode(CapabilityOverrideDelta.self, forKey: key) {
                entries[key] = delta
            }
        }
        self.entries = entries
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CapabilityOverrideKey.self)
        for key in CapabilityOverrideKey.allCases {
            if let delta = entries[key] {
                try c.encode(delta, forKey: key)
            }
        }
    }
}

/// Normalization result: the new deltas, overrides still left in the legacy field after migration, and the effective op per input key.
nonisolated struct CapabilityOverrideNormalization: Hashable, Sendable {
    var capabilityOverrides: CapabilityOverrides
    /// What remains of the legacy `relayCapabilityOverrides` after migration; nil when empty.
    var legacyKept: RelayCapabilityOverrides?

    /// The effective op for this key; nil = the user never touched it, follow the verdict.
    func effective(_ key: CapabilityOverrideKey) -> CapabilityOverrideOp? {
        capabilityOverrides[key]?.op
    }
}

nonisolated enum CapabilityOverrideNormalizer {
    /// Legacy override keys that migrate to deltas (only `source == .user`; `tested` is a probe result, not a user choice).
    private static let legacyMigration: [(RelayCapabilityOverrides.Key, CapabilityOverrideKey)] = [
        (.image, .visionInput),
        (.file, .fileInput),
    ]

    /// (connection form, legacy overrides, stored deltas, verdicts, now) -> new deltas and effective values.
    ///
    /// - Only Relay connections carry overrides; for every other form both fields are cleared.
    /// - Stored deltas win over legacy overrides; user-sourced image / file entries in the legacy overrides are
    ///   consumed (whether or not they become a delta), the other keys stay in the legacy field untouched.
    /// - A migrated delta uses `now` as setAt and the verdict state for that key as baseVerdict, defaulting to `unknown`.
    static func normalize(
        connection: ProviderForm,
        legacy: RelayCapabilityOverrides?,
        stored: CapabilityOverrides?,
        serverVerdict: [CapabilityOverrideKey: String],
        now: Date
    ) -> CapabilityOverrideNormalization {
        guard connection == .relay else {
            return CapabilityOverrideNormalization(capabilityOverrides: CapabilityOverrides(), legacyKept: nil)
        }

        var overrides = stored ?? CapabilityOverrides()
        var kept = legacy
        let setAt = CapabilityOverrideClock.format(now)

        if var remaining = kept {
            for (legacyKey, key) in legacyMigration {
                guard remaining.sources[legacyKey] == .user,
                      let value = remaining.value(for: legacyKey) else { continue }
                if overrides[key] == nil {
                    overrides[key] = CapabilityOverrideDelta(
                        op: value ? .add : .remove,
                        setAt: setAt,
                        baseVerdict: serverVerdict[key] ?? "unknown"
                    )
                }
                remaining.setValue(nil, for: legacyKey, source: .user)
            }
            kept = remaining.isEmpty ? nil : remaining
        }

        return CapabilityOverrideNormalization(capabilityOverrides: overrides, legacyKept: kept)
    }
}

/// Reading and writing setAt: ISO8601 UTC, second precision.
nonisolated enum CapabilityOverrideClock {
    static func format(_ date: Date) -> String {
        formatter().string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        formatter().date(from: text)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
