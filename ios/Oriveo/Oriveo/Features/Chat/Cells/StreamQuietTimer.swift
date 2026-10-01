import Foundation
import QuartzCore

/// Pause detection for the waiting status line: the stream is quiet once nothing visible has
/// changed for `threshold`.
///
/// The clock starts at the last change to **visible** content, not at the last chunk received
/// from the network. While the pacer is still catching up, every step calls
/// `noteVisibleChange()`, so the status line never shows next to text that is still appearing.
///
/// There is a single cancellable work item. A change only updates the timestamp; it does not
/// cancel or rebuild the work item. When the item fires and finds that something changed in the
/// meantime, it reschedules itself once for the remaining time. Fast text therefore costs at most
/// one dispatch per window, and no display link has to stay alive.
@MainActor
final class StreamQuietTimer {
    nonisolated static let defaultThreshold: CFTimeInterval = 1.5

    private let threshold: CFTimeInterval
    private var lastVisibleChange: CFTimeInterval = 0
    private var workItem: DispatchWorkItem?

    private(set) var isQuiet = false
    /// Called when `isQuiet` flips: false→true when the threshold elapses, true→false on the next
    /// visible change.
    var onQuietChanged: (() -> Void)?

    init(threshold: CFTimeInterval = StreamQuietTimer.defaultThreshold) {
        self.threshold = threshold
    }

    var isArmed: Bool { workItem != nil }

    /// Visible content just changed: the pacer advanced the visible body text, or non-empty
    /// reasoning text reached the screen. Also called once when the subscription is set up, as
    /// the starting point of the clock.
    func noteVisibleChange() {
        lastVisibleChange = CACurrentMediaTime()
        if isQuiet {
            isQuiet = false
            onQuietChanged?()
        }
        if workItem == nil {
            schedule(after: threshold)
        }
    }

    /// Stream end or cell reuse: stops and resets without calling back. The caller hides the
    /// status line itself.
    func cancel() {
        workItem?.cancel()
        workItem = nil
        isQuiet = false
    }

    private func schedule(after delay: CFTimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.fire()
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fire() {
        workItem = nil
        let remaining = threshold - (CACurrentMediaTime() - lastVisibleChange)
        // Leave 10 ms of slack for scheduling jitter, so being a few milliseconds early does not
        // cost another round.
        if remaining > 0.01 {
            schedule(after: remaining)
            return
        }
        isQuiet = true
        onQuietChanged?()
    }

    #if DEBUG
    /// Test seam: makes "a full threshold has passed since the last visible change" true right
    /// now, through the production firing path.
    func _testElapseThreshold() {
        workItem?.cancel()
        lastVisibleChange = CACurrentMediaTime() - threshold
        fire()
    }
    #endif
}
