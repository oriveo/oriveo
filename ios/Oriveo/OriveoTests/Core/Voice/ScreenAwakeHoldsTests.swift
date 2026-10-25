import Testing
@testable import Oriveo

/// Dictation recording and read-aloud share a single screen-awake hold count.
@Suite("Screen awake holds")
@MainActor
struct ScreenAwakeHoldsTests {

    private let timer = FakeIdleTimer()

    @Test("Start read-aloud while recording, end the recording and the screen stays awake, end read-aloud and the original value is restored", arguments: [false, true])
    func keep_awake_survives_dictation_end_during_read_aloud(prior: Bool) {
        timer.isIdleTimerDisabled = prior
        let holds = ScreenAwakeHolds(timer: timer)

        holds.acquire(.dictation)
        #expect(timer.isIdleTimerDisabled)
        holds.acquire(.readAloud)
        holds.release(.dictation)
        #expect(timer.isIdleTimerDisabled)
        holds.release(.readAloud)
        #expect(timer.isIdleTimerDisabled == prior)
    }

    @Test("After both holders end, the value from before the first acquire is restored (release order does not matter)", arguments: [false, true])
    func keep_awake_restores_original_after_both_end(prior: Bool) {
        timer.isIdleTimerDisabled = prior
        let holds = ScreenAwakeHolds(timer: timer)

        holds.acquire(.readAloud)
        holds.acquire(.dictation)
        holds.release(.readAloud)
        #expect(timer.isIdleTimerDisabled)
        holds.release(.dictation)
        #expect(timer.isIdleTimerDisabled == prior)

        // Another round: the original value is captured again, not carried over from the last round.
        timer.isIdleTimerDisabled = !prior
        holds.acquire(.dictation)
        holds.release(.dictation)
        #expect(timer.isIdleTimerDisabled == !prior)
    }

    @Test("Repeated acquire / release by the same holder is idempotent; releasing without acquiring leaves the switch alone")
    func repeatedAcquireAndReleaseAreIdempotent() {
        timer.isIdleTimerDisabled = false
        let holds = ScreenAwakeHolds(timer: timer)

        holds.release(.dictation)
        #expect(!timer.isIdleTimerDisabled)

        holds.acquire(.dictation)
        holds.acquire(.dictation)
        holds.acquire(.readAloud)
        holds.release(.dictation)
        holds.release(.dictation)
        #expect(timer.isIdleTimerDisabled)
        holds.release(.readAloud)
        #expect(!timer.isIdleTimerDisabled)
        holds.release(.readAloud)
        #expect(!timer.isIdleTimerDisabled)
    }
}
