import Foundation

/// Runs synchronously on the main thread; from other threads, dispatches to the main thread.
nonisolated func runOnMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        Task { @MainActor in work() }
    }
}

/// Accumulates a sum of squares per window to compute dBFS: add returns true once windowFrames samples are in,
/// and the caller then takes the window level (which also resets it).
/// An all-zero (digital silence) or empty window yields nil; there is no floor here (the floor lives only in ConversationAudioMath.dbfs).
nonisolated struct DbfsWindowAccumulator {

    let windowFrames: Int
    private(set) var count = 0
    private var sumSquares = 0.0

    init(windowFrames: Int) {
        self.windowFrames = windowFrames
    }

    /// Adds one sample; returns true when the window is full.
    @inline(__always)
    mutating func add(_ sample: Double) -> Bool {
        sumSquares += sample * sample
        count += 1
        return count == windowFrames
    }

    /// Takes the dBFS of the current window and resets it.
    mutating func take() -> Double? {
        let value: Double? = sumSquares > 0 && count > 0
            ? 20 * log10((sumSquares / Double(count)).squareRoot())
            : nil
        reset()
        return value
    }

    mutating func reset() {
        sumSquares = 0
        count = 0
    }
}
