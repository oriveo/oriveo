import Foundation

/// Model-level `pricingV2` (metadata payload v2 schema `$defs/pricingV2`).
///
/// Decoding is strict about shape: any malformed sub-field throws, and the caller
/// (`ModelMetadataEntry`) drops only this key so the model itself stays usable.
nonisolated struct PricingV2: Codable, Sendable, Equatable {
    nonisolated struct Base: Codable, Sendable, Equatable {
        let inputPerMToken: Double?
        let outputPerMToken: Double?
    }

    nonisolated struct CacheWrite: Codable, Sendable, Equatable {
        let ttl: TTL
        let perMToken: Double

        nonisolated enum TTL: String, Codable, Sendable, Equatable {
            case fiveMinutes = "5m"
            case oneHour = "1h"
        }
    }

    nonisolated struct Cache: Codable, Sendable, Equatable {
        let readPerMToken: Double?
        let writes: [CacheWrite]?
    }

    nonisolated struct ContextTier: Codable, Sendable, Equatable {
        let aboveInputTokens: Int
        let semantics: Semantics
        let inputPerMToken: Double?
        let outputPerMToken: Double?
        let cacheReadPerMToken: Double?
        let cacheWritePerMToken: Double?

        nonisolated enum Semantics: String, Codable, Sendable, Equatable {
            case wholeRequest = "whole_request"
            case incremental
        }
    }

    nonisolated struct TimeWindow: Codable, Sendable, Equatable {
        let timezone: String
        let days: [Day]?
        let start: String
        let end: String
        let inputPerMToken: Double?
        let outputPerMToken: Double?
        let cacheReadPerMToken: Double?
        let multiplier: Double?
        /// Recognised by the schema but ignored by every client estimator.
        let holidayCalendar: String?

        nonisolated enum Day: String, Codable, Sendable, Equatable {
            case monday, tuesday, wednesday, thursday, friday, saturday, sunday

            /// Gregorian weekday number (Sunday = 1 ... Saturday = 7).
            var gregorianWeekday: Int {
                switch self {
                case .sunday: return 1
                case .monday: return 2
                case .tuesday: return 3
                case .wednesday: return 4
                case .thursday: return 5
                case .friday: return 6
                case .saturday: return 7
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case timezone, days, start, end, inputPerMToken, outputPerMToken
            case cacheReadPerMToken, multiplier, holidayCalendar
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timezone = try container.decode(String.self, forKey: .timezone)
            days = try container.decodeIfPresent([Day].self, forKey: .days)
            start = try container.decode(String.self, forKey: .start)
            end = try container.decode(String.self, forKey: .end)
            inputPerMToken = try container.decodeIfPresent(Double.self, forKey: .inputPerMToken)
            outputPerMToken = try container.decodeIfPresent(Double.self, forKey: .outputPerMToken)
            cacheReadPerMToken = try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMToken)
            multiplier = try container.decodeIfPresent(Double.self, forKey: .multiplier)
            holidayCalendar = try container.decodeIfPresent(String.self, forKey: .holidayCalendar)
            // start allows only 00:00-23:59 and end additionally allows 24:00; a bad format means the whole pricingV2 shape is bad.
            guard Self.minutes(start, allowEndOfDay: false) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .start, in: container, debugDescription: "start must be HH:MM"
                )
            }
            guard Self.minutes(end, allowEndOfDay: true) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .end, in: container, debugDescription: "end must be HH:MM or 24:00"
                )
            }
        }

        var startMinute: Int { Self.minutes(start, allowEndOfDay: false) ?? 0 }
        var endMinute: Int { Self.minutes(end, allowEndOfDay: true) ?? 0 }

        static func minutes(_ text: String, allowEndOfDay: Bool) -> Int? {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            if allowEndOfDay, hour == 24, minute == 0 { return 1440 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return hour * 60 + minute
        }
    }

    nonisolated struct RegionSurcharge: Codable, Sendable, Equatable {
        let regionScope: String
        let multiplier: Double
    }

    let currencyCode: String?
    let unit: String
    let base: Base?
    let cache: Cache?
    let contextTiers: [ContextTier]?
    let timeWindows: [TimeWindow]?
    /// Ignored by the estimator: the client does not know the routed region.
    let regionSurcharges: [RegionSurcharge]?
    let perUnit: Double?
}

/// Five usage buckets the v2 estimator prices.
nonisolated struct PricingV2Usage: Sendable, Equatable {
    var uncachedInputTokens: Int
    var cacheReadTokens: Int
    var cacheWrite5mTokens: Int
    var cacheWrite1hTokens: Int
    var outputTokens: Int

    init(
        uncachedInputTokens: Int,
        cacheReadTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int,
        outputTokens: Int
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.outputTokens = outputTokens
    }

    /// `UsageBreakdown.promptTokens` already excludes cached input (see its field contract),
    /// so the buckets map one-to-one without subtraction.
    init(breakdown: UsageBreakdown) {
        self.init(
            uncachedInputTokens: max(0, breakdown.promptTokens),
            cacheReadTokens: max(0, breakdown.cachedInputTokens),
            cacheWrite5mTokens: max(0, breakdown.cacheCreation5mTokens),
            cacheWrite1hTokens: max(0, breakdown.cacheCreation1hTokens),
            outputTokens: max(0, breakdown.completionTokens)
        )
    }

    var totalInputTokens: Int {
        uncachedInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }
}

nonisolated enum PricingV2Estimate: Sendable, Equatable {
    case estimated(amount: Double, currencyCode: String?)
    /// Price unknown: shown with the existing "price unknown" presentation, never as 0.
    case unavailable
    /// Not a per-token price; callers keep their legacy path.
    case notApplicable
}

/// Pure v2 estimator whose behaviour is shared with the other clients.
nonisolated enum PricingV2Estimator {
    static let cacheReadFallbackRatio = 0.5
    static let cacheWrite5mFallbackRatio = 1.25
    static let cacheWrite1hFallbackRatio = 2.0

    /// A resolved set of unit prices (currency major unit per 1M tokens).
    nonisolated struct UnitPrices: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite5m: Double
        var cacheWrite1h: Double

        func price(for bucket: Bucket) -> Double {
            switch bucket {
            case .cacheRead: return cacheRead
            case .cacheWrite5m: return cacheWrite5m
            case .cacheWrite1h: return cacheWrite1h
            case .uncachedInput: return input
            }
        }
    }

    /// Line-up order for incremental tiers: cache read, write 5m, write 1h, uncached.
    nonisolated enum Bucket: CaseIterable {
        case cacheRead, cacheWrite5m, cacheWrite1h, uncachedInput
    }

    static func estimate(_ pricing: PricingV2, usage: PricingV2Usage, at: Date) -> PricingV2Estimate {
        guard pricing.unit == "per_token" else { return .notApplicable }
        guard let base = pricing.base,
              let baseInput = base.inputPerMToken,
              let baseOutput = base.outputPerMToken else { return .unavailable }

        let window = matchingWindow(pricing.timeWindows ?? [], at: at)
        let baseWrites = pricing.cache?.writes ?? []

        func prices(tier: PricingV2.ContextTier?) -> UnitPrices {
            let input = tier?.inputPerMToken ?? baseInput
            let output = tier?.outputPerMToken ?? baseOutput
            let read = tier?.cacheReadPerMToken ?? pricing.cache?.readPerMToken
            let write5m = tier?.cacheWritePerMToken
                ?? baseWrites.first(where: { $0.ttl == .fiveMinutes })?.perMToken
            let write1h = tier?.cacheWritePerMToken
                ?? baseWrites.first(where: { $0.ttl == .oneHour })?.perMToken
            var resolved = UnitPrices(
                input: input,
                output: output,
                cacheRead: read ?? input * cacheReadFallbackRatio,
                cacheWrite5m: write5m ?? input * cacheWrite5mFallbackRatio,
                cacheWrite1h: write1h ?? input * cacheWrite1hFallbackRatio
            )
            if let window {
                if let multiplier = window.multiplier {
                    resolved.input *= multiplier
                    resolved.output *= multiplier
                    resolved.cacheRead *= multiplier
                    resolved.cacheWrite5m *= multiplier
                    resolved.cacheWrite1h *= multiplier
                } else {
                    if let value = window.inputPerMToken { resolved.input = value }
                    if let value = window.outputPerMToken { resolved.output = value }
                    if let value = window.cacheReadPerMToken { resolved.cacheRead = value }
                }
            }
            return resolved
        }

        let tiers = (pricing.contextTiers ?? []).sorted { $0.aboveInputTokens < $1.aboveInputTokens }
        let totalInput = usage.totalInputTokens
        let selected = tiers.last(where: { totalInput > $0.aboveInputTokens })
        let selectedPrices = prices(tier: selected)

        var amount = Double(usage.outputTokens) * selectedPrices.output
        if selected?.semantics == .incremental {
            // Lay the input out as one token line; position p (0-based) belongs to the highest tier whose threshold is <= p, and below the first threshold it uses base.
            let tierPrices = tiers.map { (threshold: $0.aboveInputTokens, prices: prices(tier: $0)) }
            let basePrices = prices(tier: nil)
            var cursor = 0
            for bucket in Bucket.allCases {
                let count = tokens(in: bucket, usage: usage)
                guard count > 0 else { continue }
                let segmentStart = cursor
                let segmentEnd = cursor + count
                cursor = segmentEnd
                // Tier ranges are [threshold_i, threshold_{i+1}) and the base range is [0, threshold_0).
                var bounds: [(lower: Int, prices: UnitPrices)] = [(0, basePrices)]
                bounds.append(contentsOf: tierPrices.map { ($0.threshold, $0.prices) })
                for (index, bound) in bounds.enumerated() {
                    let upper = index + 1 < bounds.count ? bounds[index + 1].lower : Int.max
                    let lower = max(segmentStart, bound.lower)
                    let upperClamped = min(segmentEnd, upper)
                    guard upperClamped > lower else { continue }
                    amount += Double(upperClamped - lower) * bound.prices.price(for: bucket)
                }
            }
        } else {
            for bucket in Bucket.allCases {
                amount += Double(tokens(in: bucket, usage: usage)) * selectedPrices.price(for: bucket)
            }
        }
        return .estimated(amount: amount / 1_000_000, currencyCode: pricing.currencyCode)
    }

    private static func tokens(in bucket: Bucket, usage: PricingV2Usage) -> Int {
        switch bucket {
        case .cacheRead: return usage.cacheReadTokens
        case .cacheWrite5m: return usage.cacheWrite5mTokens
        case .cacheWrite1h: return usage.cacheWrite1hTokens
        case .uncachedInput: return usage.uncachedInputTokens
        }
    }

    /// The first window in the array that matches; windows with an unresolvable timezone are skipped.
    static func matchingWindow(_ windows: [PricingV2.TimeWindow], at: Date) -> PricingV2.TimeWindow? {
        for window in windows {
            guard let zone = TimeZone(identifier: window.timezone) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: at)
            guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else {
                continue
            }
            let localMinute = hour * 60 + minute
            let previousWeekday = (weekday + 5) % 7 + 1
            let days = window.days.map { Set($0.map(\.gregorianWeekday)) }
            func dayAllowed(_ value: Int) -> Bool { days?.contains(value) ?? true }
            let start = window.startMinute
            let end = window.endMinute
            let hit: Bool
            if end > start {
                hit = start <= localMinute && localMinute < end && dayAllowed(weekday)
            } else {
                hit = (localMinute >= start && dayAllowed(weekday))
                    || (localMinute < end && dayAllowed(previousWeekday))
            }
            if hit { return window }
        }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// A malformed `pricingV2` drops only this key: the synthesized `Decodable` prefers this
    /// concrete-type overload, and a decoding failure returns nil instead of failing the whole model entry.
    nonisolated func decodeIfPresent(_ type: PricingV2.Type, forKey key: Key) throws -> PricingV2? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        return try? decode(PricingV2.self, forKey: key)
    }
}
