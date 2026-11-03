import Foundation

/// Echo-reference decision for the realtime uplink gate. Contract: shared/voice-contracts/realtime-conversation.v1.json,
/// uplinkGateCases rt_gate_echo_ref_*; reference implementation: scripts/lib/realtime-conversation.mjs:echoRefIsEcho.
///
/// Each frame stores the near-end dB and the downlink reference dB (both clamped to [echoRefFloorDb, 0]; nil counts as the floor).
/// To decide the current frame: over delays 0...maxDelay, find the maximum Pearson correlation over a delayWindow-frame window
/// ending at this frame (ties take the smaller delay; it must be >= echoRefMinDelayCorrelation). At that delay, the short-window
/// correlation over `window` frames must be >= echoRefMinCorrelation, and the near-end level of this frame must be
/// <= the aligned reference + gain (lower median) + echoRefBargeInMarginDb to count as echo.
/// The ring buffers and sort scratch are allocated once in init; append / isEchoAtLatest do not allocate on the audio thread.
nonisolated struct RealtimeEchoReference: Sendable, Equatable {

    private typealias Gate = RealtimeUplinkGate

    static let window = Gate.echoRefWindowMs / VoiceConversationLogic.Constants.frameMs
    static let delayWindow = Gate.echoRefDelayWindowMs / VoiceConversationLogic.Constants.frameMs
    static let maxDelay = Gate.echoRefMaxDelayMs / VoiceConversationLogic.Constants.frameMs
    /// The earliest frame needed for a decision is i - maxDelay - delayWindow + 1; delayWindow + maxDelay frames in total.
    static let capacity = delayWindow + maxDelay

    private var near: [Double]
    private var far: [Double]
    private var scratch: [Double]
    /// Number of frames stored so far (frame numbers start at 0; latest frame number = seen - 1).
    private(set) var seen = 0

    init() {
        near = Array(repeating: Gate.echoRefFloorDb, count: Self.capacity)
        far = Array(repeating: Gate.echoRefFloorDb, count: Self.capacity)
        scratch = Array(repeating: 0, count: Self.window)
    }

    mutating func append(db: Double, ref: Double?) {
        let slot = seen % Self.capacity
        near[slot] = Self.clamp(db)
        far[slot] = Self.clamp(ref)
        seen += 1
    }

    /// Whether the latest frame is echo; insufficient window, weak correlation or no computable gain all mean not echo.
    mutating func isEchoAtLatest() -> Bool {
        let i = seen - 1
        let L = Self.delayWindow
        let W = Self.window
        guard i - L + 1 >= 0 else { return false }
        var bestDelay = -1
        var bestRho = -Double.infinity
        var d = 0
        while d <= Self.maxDelay, i - d - L + 1 >= 0 {
            if let rho = pearson(nearFrom: i - L + 1, farFrom: i - d - L + 1, length: L), bestDelay < 0 || rho > bestRho {
                bestDelay = d
                bestRho = rho
            }
            d += 1
        }
        // The long window must also reach echoRefMinDelayCorrelation at d*. During barge-in the near-end window is all speech,
        // and a short window can correlate with the downlink by chance; the long window includes the silence before barge-in.
        guard bestDelay >= 0, bestRho >= Gate.echoRefMinDelayCorrelation else { return false }
        let nearFrom = i - W + 1
        let farFrom = i - bestDelay - W + 1
        guard let rho = pearson(nearFrom: nearFrom, farFrom: farFrom, length: W),
              rho >= Gate.echoRefMinCorrelation else { return false }
        // Gain: lower median of (near - ref) over frames in the short window where ref is above the floor; insertion-sorted into the preallocated scratch.
        var m = 0
        for k in 0..<W {
            let f = far[slot(farFrom + k)]
            guard f > Gate.echoRefFloorDb else { continue }
            let diff = near[slot(nearFrom + k)] - f
            var j = m
            while j > 0, scratch[j - 1] > diff {
                scratch[j] = scratch[j - 1]
                j -= 1
            }
            scratch[j] = diff
            m += 1
        }
        guard m > 0 else { return false }
        let gain = scratch[(m - 1) / 2]
        return near[slot(i)] <= far[slot(farFrom + W - 1)] + gain + Gate.echoRefBargeInMarginDb
    }

    private func slot(_ frame: Int) -> Int { frame % Self.capacity }

    /// Same operation order as the reference pearson; zero variance in either window = nil.
    private func pearson(nearFrom: Int, farFrom: Int, length n: Int) -> Double? {
        var ma = 0.0
        var mb = 0.0
        for k in 0..<n {
            ma += near[slot(nearFrom + k)]
            mb += far[slot(farFrom + k)]
        }
        ma /= Double(n)
        mb /= Double(n)
        var sab = 0.0
        var saa = 0.0
        var sbb = 0.0
        for k in 0..<n {
            let a = near[slot(nearFrom + k)] - ma
            let b = far[slot(farFrom + k)] - mb
            sab += a * b
            saa += a * a
            sbb += b * b
        }
        if saa == 0 || sbb == 0 { return nil }
        return sab / (saa * sbb).squareRoot()
    }

    /// Clamp to [echoRefFloorDb, 0]; nil / NaN count as the floor.
    private static func clamp(_ value: Double?) -> Double {
        guard let value, value >= Gate.echoRefFloorDb else { return Gate.echoRefFloorDb }
        return min(value, 0)
    }
}
