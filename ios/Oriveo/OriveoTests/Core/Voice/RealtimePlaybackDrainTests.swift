import AVFoundation
import Testing
@testable import Oriveo

/// Counting and generation checks for the realtime downlink `.dataPlayedBack` callback → onPlaybackDrained.
@Suite("Realtime playback drain")
struct RealtimePlaybackDrainTests {

    @Test("played-back callbacks count down the queue and report drained once, on the last block")
    func played_back_callback_maps_to_drained_once() {
        var drain = RealtimePlaybackDrain()
        drain.scheduled(frames: 480)
        drain.scheduled(frames: 960)
        #expect(drain.queuedFrames == 1_440)

        #expect(drain.playedBack(frames: 480, generation: 3, currentGeneration: 3, pendingEmpty: true)
            == .counted(drained: false))
        #expect(drain.queuedFrames == 960)
        #expect(drain.playedBack(frames: 960, generation: 3, currentGeneration: 3, pendingEmpty: true)
            == .counted(drained: true))
        #expect(drain.queuedFrames == 0)
        // Another callback when the queue is already empty: playback-finished is not reported twice.
        #expect(drain.playedBack(frames: 480, generation: 3, currentGeneration: 3, pendingEmpty: true)
            == .counted(drained: false))
        #expect(drain.queuedFrames == 0)
    }

    @Test("last block played back while new audio is still pending does not report drained")
    func pending_blocks_hold_drained() {
        var drain = RealtimePlaybackDrain()
        drain.scheduled(frames: 480)
        #expect(drain.playedBack(frames: 480, generation: 0, currentGeneration: 0, pendingEmpty: false)
            == .counted(drained: false))
        drain.scheduled(frames: 480)
        #expect(drain.playedBack(frames: 480, generation: 0, currentGeneration: 0, pendingEmpty: true)
            == .counted(drained: true))
    }

    @Test("a callback from before stop is ignored and does not touch the new queue")
    func stale_callback_after_stop_ignored() {
        var drain = RealtimePlaybackDrain()
        drain.scheduled(frames: 480)
        // Playback stopped: the count resets and the engine advances the generation 1 → 2.
        drain.reset()
        #expect(drain.queuedFrames == 0)
        drain.scheduled(frames: 960)

        #expect(drain.playedBack(frames: 480, generation: 1, currentGeneration: 2, pendingEmpty: true) == .stale)
        #expect(drain.queuedFrames == 960)
        #expect(drain.playedBack(frames: 960, generation: 2, currentGeneration: 2, pendingEmpty: true)
            == .counted(drained: true))
    }
}
