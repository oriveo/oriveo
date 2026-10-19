import Foundation

// rho (tokens / UTF-8 bytes) calibration: the first 2 samples are only collected, the 3rd seeds it with the mean of 1..3, and EWMA applies afterwards;
// a missed overflow raises it by 1.25. The operation order follows the rules in budget.v1.json (IEEE double), bit-identical on every platform.

public struct RhoCalibration: Codable, Hashable, Sendable {
    public static let rho0 = 0.5
    public static let ewmaAlpha = 0.3
    public static let rhoMin = 0.15
    public static let rhoMax = 0.7
    public static let safetyFactor = 1.15
    public static let minSamples = 3
    public static let overflowMissFactor = 1.25

    /// Number of valid samples.
    public let n: Int
    public let rho: Double
    /// The first minSamples samples; when the minSamples-th arrives, their mean seeds rho. Encoded keys: {n, rho, seeds}.
    public let seeds: [Double]

    public init(n: Int = 0, rho: Double = RhoCalibration.rho0, seeds: [Double] = []) {
        self.n = n
        self.rho = rho
        self.seeds = seeds
    }

    /// Multiplied by the safety factor once enough samples exist; otherwise just rho (possibly raised by a missed overflow).
    public var rhoHi: Double {
        n >= Self.minSamples ? rho * Self.safetyFactor : rho
    }

    /// observedInput = input_uncached + cache_read + cache_write_5m + cache_write_1h;
    /// No sample is counted when observedInput is missing, textBytes <= 0, or the ratio is <= 0.
    public func recordingSample(observedInput: Int?, mediaTokens: Int, textBytes: Int) -> RhoCalibration {
        guard let observedInput, textBytes > 0 else { return self }
        let sample = Double(observedInput - mediaTokens) / Double(textBytes)
        guard sample > 0 else { return self }

        let count = n + 1
        if count < Self.minSamples {
            return RhoCalibration(n: count, rho: rho, seeds: seeds + [sample])
        }
        if count == Self.minSamples {
            let nextSeeds = seeds + [sample]
            let sum = nextSeeds.reduce(0, +)
            return RhoCalibration(n: count, rho: Self.clamp(sum / Double(nextSeeds.count)), seeds: nextSeeds)
        }
        return RhoCalibration(
            n: count,
            rho: Self.clamp(Self.ewmaAlpha * sample + (1 - Self.ewmaAlpha) * rho),
            seeds: seeds
        )
    }

    /// The prediction did not exceed U but the provider reported an overflow: rho = min(0.70, rho * 1.25).
    public func recordingOverflowMiss() -> RhoCalibration {
        RhoCalibration(n: n, rho: min(Self.rhoMax, rho * Self.overflowMissFactor), seeds: seeds)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, rhoMin), rhoMax)
    }
}

public struct RhoCalibrationKey: Codable, Hashable, Sendable {
    public var transportInstanceId: String
    public var modelId: String

    public init(transportInstanceId: String, modelId: String) {
        self.transportInstanceId = transportInstanceId
        self.modelId = modelId
    }
}

/// In-memory calibration table keyed by (transportInstanceId, modelId), defaulting to rho0.
/// Encoded as {version: 1, entries: [{transportInstanceId, modelId, n, rho, seeds}]}, with entries sorted by key.
public struct RhoCalibrationTable: Codable, Hashable, Sendable {
    public static let version = 1

    public var entries: [RhoCalibrationKey: RhoCalibration]

    public init(entries: [RhoCalibrationKey: RhoCalibration] = [:]) {
        self.entries = entries
    }

    public func calibration(for key: RhoCalibrationKey) -> RhoCalibration {
        entries[key] ?? RhoCalibration()
    }

    public mutating func recordSample(for key: RhoCalibrationKey, observedInput: Int?, mediaTokens: Int, textBytes: Int) {
        entries[key] = calibration(for: key)
            .recordingSample(observedInput: observedInput, mediaTokens: mediaTokens, textBytes: textBytes)
    }

    public mutating func recordOverflowMiss(for key: RhoCalibrationKey) {
        entries[key] = calibration(for: key).recordingOverflowMiss()
    }

    private enum CodingKeys: String, CodingKey {
        case version, entries
    }

    private struct Entry: Codable {
        var transportInstanceId: String
        var modelId: String
        var n: Int
        var rho: Double
        var seeds: [Double]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported rho table version \(version)"
            )
        }
        var entries: [RhoCalibrationKey: RhoCalibration] = [:]
        for entry in try container.decode([Entry].self, forKey: .entries) {
            let key = RhoCalibrationKey(transportInstanceId: entry.transportInstanceId, modelId: entry.modelId)
            entries[key] = RhoCalibration(n: entry.n, rho: entry.rho, seeds: entry.seeds)
        }
        self.entries = entries
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        let sorted = entries.sorted {
            ($0.key.transportInstanceId, $0.key.modelId) < ($1.key.transportInstanceId, $1.key.modelId)
        }
        try container.encode(sorted.map { key, value in
            Entry(
                transportInstanceId: key.transportInstanceId, modelId: key.modelId,
                n: value.n, rho: value.rho, seeds: value.seeds
            )
        }, forKey: .entries)
    }
}
