import Foundation

// Pure context budget functions. The spec is the rules in `shared/context-contracts/budget.v1.json`;
// every platform implements it under the same name and aligns case by case. This only does arithmetic: no persistence, no app wiring.

public enum ContextWindowKind: String, Codable, Hashable, Sendable {
    /// W includes output: answer space R must be reserved out of the window.
    case total
    /// W counts input only: R = 0, oWire = O.
    case inputOnly
}

/// User-selected budget cap: auto (min of U, autoCapDefault and the price line), unlimited (B = U),
/// or a custom token count in [customCapMin, customCapMax].
public enum ContextBudgetCap: Hashable, Sendable {
    case auto
    case unlimited
    case custom(Int)

    public static let `default`: ContextBudgetCap = .auto

    /// Parses a raw JSON / preference value. Accepts exactly "auto", "unlimited" and integral numbers
    /// (including integral-valued doubles such as 64000.0) in [customCapMin, customCapMax]; anything
    /// else (booleans, null, fractions, numeric strings, legacy "64k"-style keys, other case) returns
    /// nil and the caller treats the value as absent.
    public static func parse(_ raw: Any?) -> ContextBudgetCap? {
        guard let raw else { return nil }
        if let text = raw as? String {
            switch text {
            case "auto": return .auto
            case "unlimited": return .unlimited
            default: return nil
            }
        }
        // Booleans first: NSNumber(true) would otherwise read as the integer 1.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let type = String(cString: number.objCType)
        if type == "f" || type == "d" {
            // A JSON decoder may hand back an integral number as a double; accept only exact integers.
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value,
                  Double(ContextBudget.customCapMin) <= value, value <= Double(ContextBudget.customCapMax)
            else { return nil }
            return .custom(Int(value))
        }
        let value = number.int64Value
        guard Int64(ContextBudget.customCapMin) <= value, value <= Int64(ContextBudget.customCapMax) else {
            return nil
        }
        return .custom(Int(value))
    }

    /// Wire / storage form: "auto", "unlimited" or the integer token count; parse(wire) == self.
    public var wire: Any {
        switch self {
        case .auto: "auto"
        case .unlimited: "unlimited"
        case .custom(let tokens): tokens
        }
    }
}

extension ContextBudgetCap: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw: Any
        if let text = try? container.decode(String.self) {
            raw = text
        } else if (try? container.decode(Bool.self)) != nil {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported budget cap")
        } else if let integer = try? container.decode(Int.self) {
            raw = integer
        } else {
            raw = try container.decode(Double.self)
        }
        guard let cap = ContextBudgetCap.parse(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported budget cap")
        }
        self = cap
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .unlimited: try container.encode("unlimited")
        case .custom(let tokens): try container.encode(tokens)
        }
    }
}

/// The bound that set B; ties prefer the user-facing bound (custom over window;
/// priceLine over autoDefault over window).
public enum ContextBudgetLimit: String, Codable, Hashable, Sendable {
    case custom
    case priceLine
    case autoDefault
    case window
}

/// Candidate sources for O; the first positive number in the order user -> recipe -> model wins.
public struct ContextMaxOutputSources: Codable, Hashable, Sendable {
    public var user: Int?
    public var recipe: Int?
    public var model: Int?

    public init(user: Int? = nil, recipe: Int? = nil, model: Int? = nil) {
        self.user = user
        self.recipe = recipe
        self.model = model
    }
}

public struct ContextWindowInput: Codable, Hashable, Sendable {
    /// Model window; missing or < minKnownWindow is treated as unknown.
    public var W: Int?
    public var windowKind: ContextWindowKind
    public var maxOutput: ContextMaxOutputSources
    public var budgetCap: ContextBudgetCap
    /// Provider price line (tokens above which input is billed at a higher rate); only caps auto
    /// when >= priceLineCapMin. nil when the provider has none (for example a hosted route without price data).
    public var priceLineTokens: Int?

    public init(
        W: Int?,
        windowKind: ContextWindowKind,
        maxOutput: ContextMaxOutputSources,
        budgetCap: ContextBudgetCap = .default,
        priceLineTokens: Int? = nil
    ) {
        self.W = W
        self.windowKind = windowKind
        self.maxOutput = maxOutput
        self.budgetCap = budgetCap
        self.priceLineTokens = priceLineTokens
    }
}

/// Thresholds and segment caps derived from B.
public struct ContextBudgetDerived: Codable, Hashable, Sendable {
    public var preCompactAt: Int
    public var sendCompactAt: Int
    public var compactTargetMax: Int
    public var reminderAt: Int
    public var tail: Int
    public var userMessagesMax: Int
    public var summaryMax: Int
    public var systemMax: Int
    public var recallMax: Int

    public init(
        preCompactAt: Int,
        sendCompactAt: Int,
        compactTargetMax: Int,
        reminderAt: Int,
        tail: Int,
        userMessagesMax: Int,
        summaryMax: Int,
        systemMax: Int,
        recallMax: Int
    ) {
        self.preCompactAt = preCompactAt
        self.sendCompactAt = sendCompactAt
        self.compactTargetMax = compactTargetMax
        self.reminderAt = reminderAt
        self.tail = tail
        self.userMessagesMax = userMessagesMax
        self.summaryMax = summaryMax
        self.systemMax = systemMax
        self.recallMax = recallMax
    }
}

/// Window budget. Unknown window: W/R/U are nil and oWire = O; with auto / unlimited B and derived
/// are nil too (reactive compaction only), with a custom cap B = c clamped to [customCapMin, customCapMax]
/// and derived apply.
public struct ContextWindowBudget: Codable, Hashable, Sendable {
    public var known: Bool
    public var W: Int?
    public var O: Int
    public var R: Int?
    public var U: Int?
    public var B: Int?
    /// The bound that set B; nil when B is nil.
    public var limitedBy: ContextBudgetLimit?
    public var oWire: Int
    public var derived: ContextBudgetDerived?
    public var proactiveCompaction: Bool

    public init(
        known: Bool,
        W: Int?,
        O: Int,
        R: Int?,
        U: Int?,
        B: Int?,
        limitedBy: ContextBudgetLimit?,
        oWire: Int,
        derived: ContextBudgetDerived?,
        proactiveCompaction: Bool
    ) {
        self.known = known
        self.W = W
        self.O = O
        self.R = R
        self.U = U
        self.B = B
        self.limitedBy = limitedBy
        self.oWire = oWire
        self.derived = derived
        self.proactiveCompaction = proactiveCompaction
    }
}

/// Source of the input amount: measured (derived from the previous turn's usage) / estimated / unknown.
public enum ContextEstimateBasis: String, Codable, Hashable, Sendable {
    case observed, estimated, unknown
}

public struct ContextPHat: Codable, Hashable, Sendable {
    public var pHat: Int
    public var basis: ContextEstimateBasis

    public init(pHat: Int, basis: ContextEstimateBasis) {
        self.pHat = pHat
        self.basis = basis
    }
}

public enum ContextRingDisplayKind: String, Codable, Hashable, Sendable {
    case percent, unavailable
}

public enum ContextRingTone: String, Codable, Hashable, Sendable {
    case neutral, warm, error
}

/// Display result of the context ring; unavailable when it cannot be measured, never shown as 0%.
public struct ContextRingDisplay: Codable, Hashable, Sendable {
    public var display: ContextRingDisplayKind
    public var percent: Int?
    public var tone: ContextRingTone?
    /// Estimated percentage shown only in the panel when nothing has ever been measured.
    public var estimatedPercent: Int?

    public init(
        display: ContextRingDisplayKind,
        percent: Int?,
        tone: ContextRingTone?,
        estimatedPercent: Int? = nil
    ) {
        self.display = display
        self.percent = percent
        self.tone = tone
        self.estimatedPercent = estimatedPercent
    }
}

public enum ContextBudget {
    public static let minKnownWindow = 1024
    public static let defaultMaxOutput = 8192
    public static let messageOverheadTokens = 4
    public static let warmPercent = 70
    public static let budgetCapOptions: [ContextBudgetCap] = [.auto, .unlimited]
    public static let budgetCapDefault: ContextBudgetCap = .default
    public static let customCapMin = 32_000
    /// 2^31 - 1 keeps Kotlin Int and Swift Int identical.
    public static let customCapMax = 2_147_483_647
    public static let autoCapDefault = 256_000
    public static let priceLineCapMin = 64_000
    public static let capTickLadder = [
        32_000, 64_000, 128_000, 256_000, 384_000, 512_000, 768_000, 1_000_000, 1_500_000, 2_000_000,
    ]

    // MARK: Window

    public static func window(_ input: ContextWindowInput) -> ContextWindowBudget {
        let maxOutput = input.maxOutput
        let O = [maxOutput.user, maxOutput.recipe, maxOutput.model]
            .compactMap { $0 }
            .first { $0 > 0 } ?? defaultMaxOutput

        guard let W = input.W, W >= minKnownWindow else {
            if case .custom(let cap) = input.budgetCap {
                let B = clampedCustom(cap)
                return ContextWindowBudget(
                    known: false, W: nil, O: O, R: nil, U: nil, B: B, limitedBy: .custom,
                    oWire: O, derived: derived(B: B), proactiveCompaction: true
                )
            }
            return ContextWindowBudget(
                known: false, W: nil, O: O, R: nil, U: nil, B: nil, limitedBy: nil,
                oWire: O, derived: nil, proactiveCompaction: false
            )
        }

        let R: Int
        let oWire: Int
        switch input.windowKind {
        case .total:
            // ceil(0.10W) / floor(0.5W) use integer arithmetic, so floating-point multiplication cannot be off by one at round numbers.
            R = min(max(O, ceilDiv(W, 10)), W / 2)
            oWire = min(O, R)
        case .inputOnly:
            R = 0
            oWire = O
        }
        let U = W - R
        let (B, limitedBy) = cappedBudget(U: U, cap: input.budgetCap, priceLineTokens: input.priceLineTokens)

        return ContextWindowBudget(
            known: true, W: W, O: O, R: R, U: U, B: B, limitedBy: limitedBy,
            oWire: oWire, derived: derived(B: B), proactiveCompaction: true
        )
    }

    /// B for a known window; candidates are listed in tie-break order and the first one equal to the
    /// minimum names the limit.
    private static func cappedBudget(
        U: Int,
        cap: ContextBudgetCap,
        priceLineTokens: Int?
    ) -> (Int, ContextBudgetLimit) {
        var candidates: [(Int, ContextBudgetLimit)]
        switch cap {
        case .unlimited:
            candidates = []
        case .custom(let tokens):
            candidates = [(clampedCustom(tokens), .custom)]
        case .auto:
            candidates = []
            if let line = priceLineTokens, line >= priceLineCapMin {
                candidates.append((line, .priceLine))
            }
            candidates.append((autoCapDefault, .autoDefault))
        }
        candidates.append((U, .window))
        let B = candidates.map(\.0).min() ?? U
        let limit = candidates.first { $0.0 == B }?.1 ?? .window
        return (B, limit)
    }

    /// A custom cap built directly in code can fall outside what parse accepts; clamp it to the valid range.
    private static func clampedCustom(_ tokens: Int) -> Int {
        min(max(tokens, customCapMin), customCapMax)
    }

    /// Slider stops: sorted unique (capTickLadder ∪ {priceLineTokens when >= customCapMin}) within
    /// [customCapMin, U], plus U; unknown U has no upper bound and adds nothing; U < customCapMin -> [U].
    public static func capTicks(U: Int?, priceLineTokens: Int?) -> [Int] {
        if let U, U < customCapMin { return [U] }
        var stops = Set(capTickLadder)
        if let line = priceLineTokens, line >= customCapMin { stops.insert(line) }
        if let U {
            stops = stops.filter { $0 <= U }
            stops.insert(U)
        }
        return stops.filter { $0 >= customCapMin }.sorted()
    }

    public static func derived(B: Int) -> ContextBudgetDerived {
        ContextBudgetDerived(
            preCompactAt: B * 75 / 100,
            sendCompactAt: B * 90 / 100,
            compactTargetMax: B * 50 / 100,
            reminderAt: B * 30 / 100,
            tail: min(max(B * 25 / 100, 4000), 48000),
            userMessagesMax: min(16000, B * 10 / 100),
            summaryMax: min(4000, max(1000, B * 5 / 100)),
            systemMax: min(B * 25 / 100, 32000),
            recallMax: B * 7 / 100
        )
    }

    // MARK: Estimation

    public static func utf8Bytes(_ text: String) -> Int {
        text.utf8.count
    }

    /// ceil(utf8Bytes * rhoHi), IEEE double.
    public static func estimateText(_ text: String, rhoHi: Double) -> Int {
        Int((Double(utf8Bytes(text)) * rhoHi).rounded(.up))
    }

    public static func estimateMessage(_ text: String, rhoHi: Double) -> Int {
        estimateText(text, rhoHi: rhoHi) + messageOverheadTokens
    }

    /// With a previous measurement and no compaction since: reuse the measured input, swap out the old dynamic section, and add the answer and new messages; otherwise use the full estimate.
    public static func pHat(
        observedPrevious: Int?,
        estDynamicPrevious: Int,
        estAnswerPrevious: Int,
        estNewMessages: [Int],
        estDynamicNow: Int,
        compactedSincePrevious: Bool,
        estimatedFull: Int
    ) -> ContextPHat {
        guard let observedPrevious, !compactedSincePrevious else {
            return ContextPHat(pHat: estimatedFull, basis: .estimated)
        }
        let value = observedPrevious - estDynamicPrevious + estAnswerPrevious
            + estNewMessages.reduce(0, +) + estDynamicNow
        return ContextPHat(pHat: value, basis: .observed)
    }

    // MARK: Display

    public static func display(
        windowKnown: Bool,
        pHat: Int,
        B: Int?,
        basis: ContextEstimateBasis,
        observedEver: Bool,
        overflowed: Bool
    ) -> ContextRingDisplay {
        guard windowKnown, let B, B > 0 else {
            return ContextRingDisplay(display: .unavailable, percent: nil, tone: nil)
        }
        let percent = ceilDiv(100 * pHat, B)
        guard observedEver else {
            return ContextRingDisplay(display: .unavailable, percent: nil, tone: nil, estimatedPercent: percent)
        }
        let tone: ContextRingTone = overflowed ? .error : (percent >= warmPercent ? .warm : .neutral)
        return ContextRingDisplay(display: .percent, percent: percent, tone: tone)
    }

    private static func ceilDiv(_ numerator: Int, _ denominator: Int) -> Int {
        let quotient = numerator / denominator
        return numerator % denominator > 0 ? quotient + 1 : quotient
    }
}
