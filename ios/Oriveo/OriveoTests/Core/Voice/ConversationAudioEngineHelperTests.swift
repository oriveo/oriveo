import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Pure helpers of the conversation audio pipeline: 20 ms frame accumulation, the pre-roll ring, cue tone length and level (no engine is started, no sound is played).
@Suite("Conversation audio engine helpers")
struct ConversationAudioEngineHelperTests {

    @Test("tap buffers of any size accumulate into whole 20 ms frames")
    func frameAccumulation() {
        var accumulator = ConversationFrameAccumulator(sampleRate: 48_000)
        #expect(accumulator.samplesPerFrame == 960)
        var frames = 0
        for _ in 0..<15 { frames += accumulator.append([Float](repeating: 0.1, count: 1024)).count }
        // 15 × 1024 = 15360 = 16 × 960
        #expect(frames == 16)
        #expect(accumulator.append([Float](repeating: 0, count: 959)).isEmpty)
        #expect(accumulator.append([0]).count == 1)
        #expect(ConversationFrameAccumulator(sampleRate: 22_050).samplesPerFrame == 441)
        #expect(ConversationFrameAccumulator(sampleRate: 16_000).samplesPerFrame == 320)
    }

    @Test("frames keep sample order across buffers")
    func frameOrder() {
        var accumulator = ConversationFrameAccumulator(sampleRate: 1000)  // 20 samples per frame
        let first = accumulator.append((0..<15).map(Float.init))
        let second = accumulator.append((15..<40).map(Float.init))
        #expect(first.isEmpty)
        #expect(second.count == 2)
        #expect(second[0] == (0..<20).map(Float.init))
        #expect(second[1] == (20..<40).map(Float.init))
    }

    @Test("preroll ring returns frames from the requested index, clamped to what it still holds")
    func prerollRing() {
        var ring = ConversationPrerollRing(capacityFrames: 5)
        for index in 0..<10 { ring.push([Float(index)]) }
        #expect(ring.oldestIndex == 5)
        #expect(ring.frames(from: 7).map { $0[0] } == [7, 8, 9])
        #expect(ring.frames(from: 2).map { $0[0] } == [5, 6, 7, 8, 9])
        #expect(ring.frames(from: 10).isEmpty)
    }

    @Test("default ring covers preroll plus the barge-in start threshold")
    func ringCapacity() {
        let ring = ConversationPrerollRing()
        let frameMs = VoiceConversationLogic.Constants.frameMs
        #expect(ring.capacity * frameMs >= VoiceConversationLogic.Constants.vadPrerollMs
            + VoiceConversationLogic.Constants.bargeInMinSpeechMs)
    }

    @Test("earcons are at most 250 ms with a peak near -18 dBFS and soft edges")
    func earcons() {
        for earcon in [VoiceConversationLogic.Earcon.start, .heard, .thinking, .end] {
            let sampleRate = 44_100.0
            let samples = ConversationEarconSynth.samples(earcon, sampleRate: sampleRate)
            let durationMs = Double(samples.count) / sampleRate * 1000
            #expect(durationMs <= 250, "\(earcon)")
            #expect(abs(durationMs - ConversationEarconSynth.durationMs(earcon)) < 1)
            let peak = samples.map { abs(Double($0)) }.max() ?? 0
            #expect(abs(20 * log10(peak) - (-18)) < 0.2, "\(earcon) peak \(peak)")
            #expect(abs(samples.first ?? 1) < 0.001)
            #expect(abs(samples.last ?? 1) < 0.01)
        }
    }

    @Test("earcon tones follow the contract: start 660->880, heard 880 60 ms, thinking 880 120 ms, end 660->440")
    func earconTones() {
        let tones = { (earcon: VoiceConversationLogic.Earcon) in
            ConversationEarconSynth.tones(earcon).map { [$0.hz, $0.ms] }
        }
        #expect(tones(.start) == [[660, 60], [880, 60]])
        #expect(tones(.heard) == [[880, 60]])
        #expect(tones(.thinking) == [[880, 120]])
        #expect(tones(.end) == [[660, 110], [440, 130]])
    }

    @Test("hostRules: earcon segments are phase-continuous; only the whole earcon fades in / out over 10 ms")
    func hostRules_earconPhaseContinuousWholeFade() {
        let sampleRate = 44_100.0
        let amplitude = pow(10, -18.0 / 20)
        for earcon in [VoiceConversationLogic.Earcon.start, .end] {
            let tones = ConversationEarconSynth.tones(earcon)
            let samples = ConversationEarconSynth.samples(earcon, sampleRate: sampleRate).map(Double.init)
            // Phase continuity: adjacent points differ by no more than the steepest slope of the highest-frequency sine
            let maxHz = tones.map(\.hz).max() ?? 0
            let maxStep = amplitude * 2 * .pi * maxHz / sampleRate * 1.05
            let steps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
            #expect((steps.max() ?? 0) <= maxStep, "\(earcon) jump \(steps.max() ?? 0)")
            // No fade between segments: samples within ±2 ms of a boundary are still near full scale
            let boundary = Int((sampleRate * tones[0].ms / 1000).rounded())
            let window = Int(sampleRate * 0.002)
            let near = samples[(boundary - window)..<(boundary + window)].map(abs).max() ?? 0
            #expect(near > amplitude * 0.9, "\(earcon) boundary peak \(near)")
            // 10 ms fade in and out of the whole segment: the envelope at 5 ms is about half
            let fade = Int(sampleRate * 0.010)
            let head = samples[0..<(fade / 2)].map(abs).max() ?? 1
            #expect(head <= amplitude * 0.55, "\(earcon) head \(head)")
            let tail = samples[(samples.count - fade / 2)...].map(abs).max() ?? 1
            #expect(tail <= amplitude * 0.55, "\(earcon) tail \(tail)")
        }
    }

    @Test("dBFS of silence is the floor, of a full-scale square is 0")
    func dbfs() {
        #expect(ConversationAudioMath.dbfs([Float](repeating: 0, count: 960)) == ConversationAudioMath.silenceDb)
        #expect(abs(ConversationAudioMath.dbfs([Float](repeating: 1, count: 960))) < 1e-9)
        #expect(abs(ConversationAudioMath.dbfs([Float](repeating: 0.1, count: 960)) - (-20)) < 1e-4)
    }

    // MARK: Session configuration and injected notifications

    @Test("conversation session uses playAndRecord + voiceChat + defaultToSpeaker")
    func conversationUsesVoiceChatCategory() {
        let config = VPIOConversationAudioEngine.sessionConfiguration
        #expect(config.category == .playAndRecord)
        #expect(config.mode == .voiceChat)
        #expect(config.options.contains(.defaultToSpeaker))
    }

    @Test("an interruption posted on the injected center reaches the delegate")
    @MainActor
    func postedInterruptionReachesDelegate() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let engine = VPIOConversationAudioEngine(session: session, notificationCenter: center)
        let delegate = ConversationAudioDelegateSpy()
        engine.delegate = delegate
        engine.observe()

        if #available(iOS 27, *) {
            center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
        } else {
            center.post(name: AVAudioSession.interruptionNotification, object: session,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        }
        #expect(delegate.interruptionsBegan == 1)
        // Sessions issued by other owners do not count.
        center.post(name: AVAudioSession.routeChangeNotification, object: NSObject(),
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        #expect(delegate.routeChanges.isEmpty)
    }

    @Test("prepareSession configures, activates and sets the IO buffer to 0.02 in order on the coordinator queue, not on the main thread")
    @MainActor
    func prepareSessionRunsOffMainThroughCoordinator() async throws {
        let recorder = SessionOpRecorder()
        let engine = VPIOConversationAudioEngine(
            notificationCenter: NotificationCenter(),
            coordinator: AudioSessionCoordinator(apply: recorder.apply)
        )

        #expect(Thread.isMainThread)
        try await engine.prepareSession()

        #expect(recorder.operations == [
            .configure(.init(
                category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP],
                allowHapticsDuringRecording: true
            )),
            .activate,
            .preferIOBufferDuration(0.02),
        ])
        #expect(recorder.anyOnMain == false)
    }

    @Test("a posted oldDeviceUnavailable route change reaches the delegate as unplugged")
    @MainActor
    func postedRouteChangeOldDeviceUnavailableReachesDelegate() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let engine = VPIOConversationAudioEngine(session: session, notificationCenter: center)
        let delegate = ConversationAudioDelegateSpy()
        engine.delegate = delegate
        engine.observe()

        center.post(name: AVAudioSession.routeChangeNotification, object: session,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        center.post(name: AVAudioSession.routeChangeNotification, object: session,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        #expect(delegate.routeChanges.map(\.oldDeviceUnavailable) == [false, true])
        #expect(delegate.routeChanges.last?.route == engine.route)
        #expect(delegate.interruptionsBegan == 0)
    }
}

extension ConversationAudioEngineHelperTests {
    // MARK: VPIO stays on throughout: test doubles record the VPIO toggle, input tap and engine.start call order

    @Test("vpio_enabled_before_start_and_tap_after_enable: VPIO is enabled first, the tap is installed after enabling, engine.start comes last; only the owner's own stop turns it off")
    @MainActor
    func vpio_enabled_before_start_and_tap_after_enable() async throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "a", log: log)

        try await rig.engine.prepareSession()
        try rig.engine.start()

        let events = log.events.filter { $0.hasPrefix("a:") }
        let enable = try #require(events.firstIndex(of: "a:vpio:on"))
        let tap = try #require(events.lastIndex(of: "a:tap:install"))
        let start = try #require(events.firstIndex(of: "a:engine:start"))
        #expect(enable < tap)
        #expect(tap < start)
        #expect(rig.voiceProcessing.isEnabled)

        rig.engine.stop()
        #expect(log.events.last == "a:vpio:off")
        #expect(!rig.voiceProcessing.isEnabled)
    }

    @Test("superseded_lease_teardown_keeps_vpio: a late stop / wrapper graph teardown after the lease was superseded never turns VPIO off")
    @MainActor
    func superseded_lease_teardown_keeps_vpio() async throws {
        let owner = VoiceAudioSessionOwner()
        let log = AudioCallLog()

        // The engine's own stop: the lease has already been taken over by a later owner.
        let direct = VPIOOrderRig(name: "d", log: log, owner: owner)
        direct.engine.sessionLease = owner.claim(.conversation)
        try await direct.engine.prepareSession()
        try direct.engine.start()
        _ = owner.claim(.conversation)
        direct.engine.stop()
        #expect(!log.events.contains("d:vpio:off"))
        #expect(log.events.filter { $0 == "d:tap:remove" }.count >= 2)

        // Cascade wrapper layer: the lease is superseded -> tearDownGraph.
        let cascade = VPIOOrderRig(name: "c", log: log, owner: owner)
        let wrapper = SessionLeasedConversationAudio(cascade.engine, owner: owner)
        try await wrapper.prepareSession()
        try wrapper.start()
        let fresh = owner.claim(.conversation)
        wrapper.stop()
        #expect(!log.events.contains("c:vpio:off"))
        #expect(log.events.filter { $0 == "c:engine:start" }.count == 1)
        #expect(owner.current == fresh)
        // Deactivation is queued through the coordinator: after draining, check that neither superseded teardown left the session deactivated.
        try await direct.coordinator.perform([])
        try await cascade.coordinator.perform([])
        #expect(direct.deactivations == 0)
        #expect(cascade.deactivations == 0)
    }

    @Test("home_to_chat_handoff_never_toggles_vpio: on handoff from home to the conversation page, a late teardown of the old session never turns VPIO off, and the new session keeps it on from start to end")
    @MainActor
    func home_to_chat_handoff_never_toggles_vpio() async throws {
        let owner = VoiceAudioSessionOwner()
        let log = AudioCallLog()
        let homeRig = VPIOOrderRig(name: "home", log: log, owner: owner)
        let chatRig = VPIOOrderRig(name: "chat", log: log, owner: owner)
        let home = RealtimeVoiceAudio(homeRig.engine, route: { .speaker })
        let chat = RealtimeVoiceAudio(chatRig.engine, route: { .speaker })

        home.sessionLease = owner.claim(.conversation)
        try await home.prepareSession()
        try home.startRealtime(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in }, onInterruption: {})
        chat.sessionLease = owner.claim(.conversation)
        try await chat.prepareSession()
        try chat.startRealtime(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in }, onInterruption: {})
        home.stopRealtime()
        try await homeRig.coordinator.perform([])
        #expect(homeRig.deactivations == 0)

        let vpio = log.events.filter { $0.contains(":vpio:") }
        #expect(vpio == ["home:vpio:on", "chat:vpio:on"])
        #expect(chatRig.voiceProcessing.isEnabled)

        // Only the new session's own end turns it off.
        chat.stopRealtime()
        #expect(log.events.filter { $0.contains(":vpio:") } == ["home:vpio:on", "chat:vpio:on", "chat:vpio:off"])
    }

    @Test("realtime_playback_only_skips_input_then_capture_installs: playback-only start does not enable VPIO or install the input tap; VPIO and the tap are set up only after capture is enabled")
    @MainActor
    func realtime_playback_only_skips_input_then_capture_installs() async throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "p", log: log)
        let audio = RealtimeVoiceAudio(rig.engine, route: { .speaker })
        try await audio.prepareSession()
        try audio.startRealtimePlayback(onInterruption: {})
        #expect(log.events == ["p:engine:start"])
        #expect(!rig.voiceProcessing.isEnabled)

        try audio.startRealtimeCapture(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in })
        #expect(log.events == ["p:engine:start", "p:vpio:on", "p:tap:remove", "p:tap:install", "p:engine:start"])
        #expect(rig.voiceProcessing.isEnabled)
        // Already capturing: enabling again does not reconfigure.
        try audio.startRealtimeCapture(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in })
        #expect(log.events.filter { $0 == "p:engine:start" }.count == 2)

        audio.stopRealtime()
        #expect(log.events.suffix(2) == ["p:tap:remove", "p:vpio:off"])
    }

    @Test("realtime_playback_only_stop_touches_no_input: after a playback-only start, stopping right away does not remove the input tap")
    @MainActor
    func realtime_playback_only_stop_touches_no_input() async throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "q", log: log)
        try await rig.engine.prepareSession()
        try rig.engine.startRealtimePlayback(onInterruption: {})
        rig.engine.stopRealtime()
        #expect(!log.events.contains("q:tap:install"))
        #expect(!log.events.contains("q:tap:remove"))
    }

    @Test("start_without_prepared_session_throws: calling start without prepareSession throws; VPIO is not enabled and the engine does not start")
    @MainActor
    func start_without_prepared_session_throws() {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "u", log: log)

        #expect(throws: VPIOConversationAudioEngine.SessionNotPrepared.self) { try rig.engine.start() }

        #expect(!log.events.contains("u:engine:start"))
        #expect(!log.events.contains("u:vpio:on"))
        #expect(rig.recorder.operations.isEmpty)
    }

    @Test("own_teardown_deactivates_via_coordinator: the owner's teardown queues deactivation through the coordinator and notifies others, not on the main thread; after teardown it must be prepared again")
    @MainActor
    func own_teardown_deactivates_via_coordinator() async throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "t", log: log)
        try await rig.engine.prepareSession()
        try rig.engine.start()

        rig.engine.stop()
        try await rig.coordinator.perform([])

        #expect(rig.recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(rig.deactivations == 1)
        #expect(rig.recorder.anyOnMain == false)
        // The prepared flag is cleared by teardown: it cannot start again without preparing again.
        #expect(throws: VPIOConversationAudioEngine.SessionNotPrepared.self) { try rig.engine.start() }
    }

    @Test("interruption_generation_drops_stale_resume: began / ended / began in quick succession; a stale resume arriving late does not start the engine, does not re-send ended, and does not deactivate the session")
    @MainActor
    func interruption_generation_drops_stale_resume() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let rig = VPIOOrderRig(name: "g", log: AudioCallLog(), center: center)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()

        postInterruptionBegan(center, session)
        let resume = rig.engine.interruptionEndedForTesting()
        postInterruptionBegan(center, session)
        await resume?.value
        // Drain the coordinator: if the stale resume queued a deactivation, it runs here.
        try await rig.coordinator.perform([])

        #expect(resume != nil)
        #expect(delegate.interruptionEvents == ["began", "began"])
        #expect(!rig.engine.isEngineRunningForTesting)
        #expect(rig.recorder.operations.filter { $0 == .activate }.count == 2)
        #expect(rig.deactivations == 0)
        rig.engine.stop()
    }

    @Test("interruption_reactivate_failure_reports_without_resume: when reactivation fails during interruption recovery, it reports not-resumed rather than resumed, and does not start the engine")
    @MainActor
    func interruption_reactivate_failure_reports_without_resume() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        // The second activation (the first resume after prepareSession) throws.
        let rig = VPIOOrderRig(name: "f", log: AudioCallLog(), center: center, failActivationOn: 2)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()

        postInterruptionBegan(center, session)
        let resume = rig.engine.interruptionEndedForTesting()
        await resume?.value

        #expect(resume != nil)
        #expect(delegate.interruptionEvents == ["began", "endedWithoutResume"])
        #expect(delegate.interruptionsEnded == 0)
        #expect(delegate.captureFailures == 0)
        #expect(!rig.engine.isEngineRunningForTesting)
        rig.engine.stop()
    }

    @Test("rebuild_failure_reports_capture_failed: starting the engine throws during a rebuild after a configuration change reports capture failure (the host ends by system)")
    @MainActor
    func rebuild_failure_reports_capture_failed() async throws {
        let log = AudioCallLog()
        // The second engine start (the rebuild after start) throws.
        let rig = VPIOOrderRig(name: "b", log: log, startFailsOn: 2)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()

        rig.engine.rebuildForTesting()

        #expect(log.events.filter { $0 == "b:engine:start" }.count == 2)
        #expect(delegate.captureFailureReasons == [.rebuild])
        #expect(delegate.interruptionEvents.isEmpty)
        rig.engine.stop()
    }

    @Test("rebuild_success_reports_nothing: a successful rebuild does not report capture failure")
    @MainActor
    func rebuild_success_reports_nothing() async throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "k", log: log)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()

        rig.engine.rebuildForTesting()

        #expect(log.events.filter { $0 == "k:engine:start" }.count == 2)
        #expect(delegate.captureFailures == 0)
        rig.engine.stop()
    }

    @Test("frame_watchdog_judgement: a stalled frame is judged only while timing; it counts only after more than 1500 ms without a tap callback, measured from the later of the timing start and the most recent callback")
    func frame_watchdog_judgement() {
        var watchdog = ConversationFrameWatchdog()
        // Not timing (not running / interrupted / paused): never judged, however long it has been.
        #expect(!watchdog.stalled(nowMs: 100_000, lastFrameMs: nil))
        watchdog.arm(nowMs: 1_000)
        // No callback since the start: exactly 1500 ms does not count; only exceeding it does.
        #expect(!watchdog.stalled(nowMs: 2_500, lastFrameMs: nil))
        #expect(watchdog.stalled(nowMs: 2_501, lastFrameMs: nil))
        // Callbacks received: measured from the most recent callback.
        #expect(!watchdog.stalled(nowMs: 3_000, lastFrameMs: 2_000))
        #expect(watchdog.stalled(nowMs: 3_501, lastFrameMs: 2_000))
        // Callbacks before the timing start (before an interruption / pause) do not count: measured from the restarted timing.
        watchdog.arm(nowMs: 10_000)
        #expect(!watchdog.stalled(nowMs: 11_500, lastFrameMs: 2_000))
        #expect(watchdog.stalled(nowMs: 11_501, lastFrameMs: 2_000))
        // Interruption / pause: stop timing.
        watchdog.disarm()
        #expect(!watchdog.stalled(nowMs: 100_000, lastFrameMs: 2_000))
        #expect(watchdog.dueMs(lastFrameMs: 2_000) == nil)
        watchdog.arm(nowMs: 10_000)
        #expect(watchdog.dueMs(lastFrameMs: 2_000) == 11_501)
        #expect(watchdog.dueMs(lastFrameMs: 10_400) == 11_901)
    }

    @Test("engine_watchdog_stall_reports_capture_failed: on the real engine, a tap stopped for more than 1500 ms reports a stall; a callback restarts timing from it, and the watchdog only sleeps until the judgement time")
    @MainActor
    func engine_watchdog_stall_reports_capture_failed() async throws {
        let log = AudioCallLog()
        let timer = ManualWatchdogTimer()
        let rig = VPIOOrderRig(name: "w", log: log, timer: timer)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        timer.nowMs = 1_000
        try await rig.engine.prepareSession()
        try rig.engine.start()
        await drain()
        // Timing starts at launch: sleep until start + 1501, without waking on a fixed interval
        #expect(timer.sleeps == [1_501])

        // A callback arrives at 1.2 s; wake at 1501: measured from the callback, sleep another 1200
        timer.nowMs = 2_200
        rig.tap.deliver()
        timer.nowMs = 2_501
        timer.wake()
        await drain()
        #expect(timer.sleeps == [1_501, 1_200])
        #expect(delegate.captureFailures == 0)

        // No callback after that: beyond 1500 ms, judge a stalled frame
        timer.nowMs = 3_701
        timer.wake()
        await drain()
        #expect(delegate.captureFailureReasons == [.stall])
        #expect(timer.sleeps.count == 2)
        rig.engine.stop()
    }

    @Test("engine_watchdog_paused_or_interrupted_never_judges: no judgement and no wake-up while paused or interrupted; after resuming, timing starts from the resume moment")
    @MainActor
    func engine_watchdog_paused_or_interrupted_never_judges() async throws {
        let log = AudioCallLog()
        let timer = ManualWatchdogTimer()
        let center = NotificationCenter()
        let rig = VPIOOrderRig(name: "p", log: log, center: center, timer: timer)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()
        await drain()
        #expect(timer.sleeps == [1_501])

        // Paused: cancel the check; no judgement and no further sleep, however long it waits
        rig.engine.pauseCapture()
        timer.nowMs = 60_000
        timer.wake()
        await drain()
        #expect(delegate.captureFailures == 0)
        #expect(timer.sleeps == [1_501])

        // Resumed: measured from the resume moment
        rig.engine.resumeCapture()
        await drain()
        #expect(timer.sleeps == [1_501, 1_501])

        // Interrupted: likewise, no judgement and no wake-up
        if #available(iOS 27, *) {
            center.post(name: AVAudioSession.didBecomeInactiveNotification, object: AVAudioSession.sharedInstance())
        } else {
            center.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        }
        #expect(delegate.interruptionsBegan == 1)
        timer.nowMs = 120_000
        timer.wake()
        await drain()
        #expect(delegate.captureFailures == 0)
        #expect(timer.sleeps == [1_501, 1_501])
        rig.engine.stop()
    }

    @MainActor
    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("interruption_stale_resume_keeps_next_resume_session: began / ended / began / ended in quick succession with the first activation suspended; the second resume starts the engine and the stale resume does not deactivate the session")
    @MainActor
    func interruption_stale_resume_keeps_next_resume_session() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        // The second activation (the first resume after prepareSession) is suspended on the coordinator queue until open().
        let gate = ActivationGate(holdOn: 2)
        let rig = VPIOOrderRig(name: "s", log: AudioCallLog(), center: center, gate: gate)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()

        postInterruptionBegan(center, session)
        let first = rig.engine.interruptionEndedForTesting()
        await gate.waitArrived()
        postInterruptionBegan(center, session)
        let second = rig.engine.interruptionEndedForTesting()
        gate.open()
        await first?.value
        await second?.value
        try await rig.coordinator.perform([])

        #expect(first != nil)
        #expect(second != nil)
        #expect(delegate.interruptionEvents == ["began", "began", "ended"])
        #expect(rig.engine.isEngineRunningForTesting)
        #expect(rig.recorder.operations.filter { $0 == .activate }.count == 3)
        #expect(rig.deactivations == 0)
        rig.engine.stop()
    }

    @Test("interruption_resume_after_stop_deactivates: the lease is released before stop while resume activation is suspended; when resume returns it deactivates the just-activated session and does not start the engine")
    @MainActor
    func interruption_resume_after_stop_deactivates() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let owner = VoiceAudioSessionOwner()
        // The second activation (the first resume after prepareSession) is suspended on the coordinator queue until open().
        let gate = ActivationGate(holdOn: 2)
        let rig = VPIOOrderRig(name: "t", log: AudioCallLog(), owner: owner, center: center, gate: gate)
        let lease = owner.claim(.conversation)
        rig.engine.sessionLease = lease
        try await rig.engine.prepareSession()
        try rig.engine.start()

        postInterruptionBegan(center, session)
        let resume = rig.engine.interruptionEndedForTesting()
        await gate.waitArrived()
        // The conversation ends while activation is suspended: the lease is returned first (nobody holds it), then stop; stop no longer holds the lease and does not deactivate.
        owner.release(lease)
        rig.engine.stop()
        gate.open()
        await resume?.value
        try await rig.coordinator.perform([])

        #expect(resume != nil)
        #expect(rig.recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(rig.deactivations == 1)
        #expect(!rig.engine.isEngineRunningForTesting)
    }

    @Test("prepared_stop_after_lease_released_deactivates: prepared but not started, with the lease already released (nobody holds it), stop still deactivates and notifies others")
    @MainActor
    func prepared_stop_after_lease_released_deactivates() async throws {
        let owner = VoiceAudioSessionOwner()
        let rig = VPIOOrderRig(name: "r", log: AudioCallLog(), owner: owner)
        let lease = owner.claim(.conversation)
        rig.engine.sessionLease = lease
        try await rig.engine.prepareSession()
        owner.release(lease)
        #expect(owner.current == nil)

        rig.engine.stop()
        try await rig.coordinator.perform([])

        #expect(rig.recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(rig.deactivations == 1)
    }

    @Test("prepared_stop_after_lease_taken_keeps_session: prepared but not started, with the lease taken by a new session, stop does not deactivate")
    @MainActor
    func prepared_stop_after_lease_taken_keeps_session() async throws {
        let owner = VoiceAudioSessionOwner()
        let rig = VPIOOrderRig(name: "t", log: AudioCallLog(), owner: owner)
        rig.engine.sessionLease = owner.claim(.conversation)
        try await rig.engine.prepareSession()
        let fresh = owner.claim(.conversation)

        rig.engine.stop()
        try await rig.coordinator.perform([])

        #expect(owner.current == fresh)
        #expect(rig.deactivations == 0)
    }

    @Test("prepared_stop_while_read_aloud_holds_lease_keeps_session: prepared but not started, with read-aloud holding the lease, stop does not deactivate read-aloud's session")
    @MainActor
    func prepared_stop_while_read_aloud_holds_lease_keeps_session() async throws {
        let owner = VoiceAudioSessionOwner()
        let rig = VPIOOrderRig(name: "ra", log: AudioCallLog(), owner: owner)
        let lease = owner.claim(.conversation)
        rig.engine.sessionLease = lease
        try await rig.engine.prepareSession()
        let readAloud = owner.claim(.readAloud)

        rig.engine.stop()
        try await rig.coordinator.perform([])

        #expect(!owner.release(lease))
        #expect(owner.current == readAloud)
        #expect(rig.deactivations == 0)
    }

    @Test("interruption_resume_after_stop_while_read_aloud_holds_lease: while resume activation is suspended, read-aloud takes the lease and the conversation stops; when resume returns it does not deactivate")
    @MainActor
    func interruption_resume_after_stop_while_read_aloud_holds_lease() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let owner = VoiceAudioSessionOwner()
        let gate = ActivationGate(holdOn: 2)
        let rig = VPIOOrderRig(name: "rr", log: AudioCallLog(), owner: owner, center: center, gate: gate)
        rig.engine.sessionLease = owner.claim(.conversation)
        try await rig.engine.prepareSession()
        try rig.engine.start()

        postInterruptionBegan(center, session)
        let resume = rig.engine.interruptionEndedForTesting()
        await gate.waitArrived()
        let readAloud = owner.claim(.readAloud)
        rig.engine.stop()
        gate.open()
        await resume?.value
        try await rig.coordinator.perform([])

        #expect(resume != nil)
        #expect(owner.current == readAloud)
        #expect(rig.deactivations == 0)
        #expect(!rig.engine.isEngineRunningForTesting)
    }

    @Test("prepared_but_not_started_stop_deactivates: stop right after prepareSession without start deactivates through the coordinator and notifies others")
    @MainActor
    func prepared_but_not_started_stop_deactivates() async throws {
        let rig = VPIOOrderRig(name: "p", log: AudioCallLog())
        try await rig.engine.prepareSession()

        rig.engine.stop()
        try await rig.coordinator.perform([])

        #expect(rig.recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(rig.deactivations == 1)
        #expect(throws: VPIOConversationAudioEngine.SessionNotPrepared.self) { try rig.engine.start() }
    }

    @Test("interruption_ended_after_teardown_does_not_activate: an interruption-ended notification arriving after teardown does not activate the session")
    @MainActor
    func interruption_ended_after_teardown_does_not_activate() async throws {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let rig = VPIOOrderRig(name: "e", log: AudioCallLog(), center: center)
        let delegate = ConversationAudioDelegateSpy()
        rig.engine.delegate = delegate
        try await rig.engine.prepareSession()
        try rig.engine.start()
        rig.engine.stop()
        // Teardown removed the observer; re-register to simulate a notification that was already on its way before teardown.
        rig.engine.observe()

        postInterruptionEnded(center, session, engine: rig.engine)
        try await rig.coordinator.perform([])
        try await rig.coordinator.perform([])

        #expect(rig.recorder.operations.filter { $0 == .activate }.count == 1)
        #expect(rig.recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(delegate.interruptionsEnded == 0)
    }

    @Test("sentence_played_back_only_on_last_chunk: for a multi-chunk sentence, dataPlayedBack reports completion only on the last chunk")
    func sentencePlayedBackOnlyOnLastChunk() {
        var count = SentencePlaybackCount()
        for _ in 0..<3 { count.scheduled() }
        var reports: [Bool] = []
        // Synthesis has not finished: do not report even when chunks finish playing
        reports.append(count.playedBack(generation: 0, currentGeneration: 0, synthesisDone: false, pendingEmpty: true))
        reports.append(count.playedBack(generation: 0, currentGeneration: 0, synthesisDone: true, pendingEmpty: true))
        #expect(count.outstanding == 1)
        // Chunks still queued but not scheduled: do not report
        reports.append(count.playedBack(generation: 0, currentGeneration: 0, synthesisDone: true, pendingEmpty: false))
        count.scheduled()
        reports.append(count.playedBack(generation: 0, currentGeneration: 0, synthesisDone: true, pendingEmpty: true))
        #expect(reports == [false, false, false, true])
        #expect(count.outstanding == 0)
    }

    @Test("sentence_chunks_stopped_early_do_not_report: chunk callbacks from an early stop do not report completion or count")
    func sentenceChunksStoppedEarlyDoNotReport() {
        var count = SentencePlaybackCount()
        count.scheduled()
        count.scheduled()
        // Stop / reschedule advances the generation and resets the count; a late callback from the old generation
        count.reset()
        var reports: [Bool] = []
        reports.append(count.playedBack(generation: 0, currentGeneration: 1, synthesisDone: true, pendingEmpty: true))
        reports.append(count.playedBack(generation: 0, currentGeneration: 1, synthesisDone: true, pendingEmpty: true))
        #expect(count.outstanding == 0)
        // Chunks rescheduled in the new generation are counted as usual
        count.scheduled()
        reports.append(count.playedBack(generation: 1, currentGeneration: 1, synthesisDone: true, pendingEmpty: true))
        #expect(reports == [false, false, true])
    }
}

/// Posts an interruption-began event through the injected center.
@MainActor
private func postInterruptionBegan(_ center: NotificationCenter, _ session: AVAudioSession) {
    if #available(iOS 27, *) {
        center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
    } else {
        center.post(name: AVAudioSession.interruptionNotification, object: session,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    }
}

/// Posts an interruption-ended event. On iOS 27 the resume suggestion carries a system-built ResumptionContext that tests cannot construct, so tests use the engine's test entry point instead.
@MainActor
private func postInterruptionEnded(_ center: NotificationCenter, _ session: AVAudioSession, engine: VPIOConversationAudioEngine) {
    if #available(iOS 27, *) {
        engine.interruptionEndedForTesting()
    } else {
        center.post(name: AVAudioSession.interruptionNotification, object: session,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
    }
}

/// Call sequence shared by the test doubles.
@MainActor
private final class AudioCallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@MainActor
private final class RecordingVoiceProcessing: ConversationVoiceProcessing {
    private let name: String
    private let log: AudioCallLog
    private(set) var isEnabled = false
    init(name: String, log: AudioCallLog) { self.name = name; self.log = log }
    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
        log.record("\(name):vpio:\(enabled ? "on" : "off")")
    }
}

@MainActor
private final class RecordingInputTap: ConversationInputTap {
    private let name: String
    private let log: AudioCallLog
    private var block: AVAudioNodeTapBlock?
    init(name: String, log: AudioCallLog) { self.name = name; self.log = log }
    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        self.block = block
        log.record("\(name):tap:install")
    }
    /// Simulates one tap callback (empty buffer: only records the call, produces no frames).
    func deliver() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        block?(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }
    func remove() { log.record("\(name):tap:remove") }
}

/// The real VPIOConversationAudioEngine with the VPIO toggle, input tap and engine.start replaced by recording doubles; deactivation is counted but not performed.
@MainActor
private final class VPIOOrderRig {
    let voiceProcessing: RecordingVoiceProcessing
    let tap: RecordingInputTap
    /// Session operations are recorded through the injected coordinator and never touch a real AVAudioSession.
    let recorder = SessionOpRecorder()
    let coordinator: AudioSessionCoordinator
    /// Number of deactivations executed: deactivation is queued, so drain the coordinator before reading.
    var deactivations: Int { recorder.operations.filter { if case .deactivate = $0 { true } else { false } }.count }
    private(set) var engine: VPIOConversationAudioEngine!

    init(
        name: String, log: AudioCallLog, owner: VoiceAudioSessionOwner? = nil,
        center: NotificationCenter = NotificationCenter(), gate: ActivationGate? = nil,
        failActivationOn: Int? = nil, startFailsOn: Int? = nil, timer: ManualWatchdogTimer? = nil
    ) {
        let voiceProcessing = RecordingVoiceProcessing(name: name, log: log)
        let tap = RecordingInputTap(name: name, log: log)
        self.voiceProcessing = voiceProcessing
        self.tap = tap
        let record = recorder.apply
        let activations = CallCounter()
        let coordinator = AudioSessionCoordinator(apply: { op in
            gate?.before(op)
            if op == .activate, activations.next() == failActivationOn { throw SessionOpRecorder.Failure() }
            try record(op)
        })
        let starts = CallCounter()
        self.coordinator = coordinator
        let clock: @Sendable () -> Int
        if let timer { clock = { timer.nowMs } } else { clock = ConversationTapClock.uptimeMs }
        let sleep: (Int) async -> Void
        if let timer { sleep = { await timer.sleep($0) } } else { sleep = { try? await Task.sleep(for: .milliseconds($0)) } }
        engine = VPIOConversationAudioEngine(
            notificationCenter: center, owner: owner,
            inputTap: { _ in tap },
            voiceProcessing: { _ in voiceProcessing },
            startEngine: { _ in
                log.record("\(name):engine:start")
                if starts.next() == startFailsOn { throw SessionOpRecorder.Failure() }
            },
            coordinator: coordinator,
            watchdogClock: clock,
            watchdogSleep: sleep
        )
    }
}

/// The watchdog's manual clock and sleep: sleep records the milliseconds to sleep and suspends; wake releases all (the test advances time itself).
private nonisolated final class ManualWatchdogTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var slept: [Int] = []
    private var pending: [CheckedContinuation<Void, Never>] = []

    var nowMs: Int {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }

    var sleeps: [Int] { lock.withLock { slept } }

    func sleep(_ ms: Int) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                slept.append(ms)
                pending.append(continuation)
            }
        }
    }

    func wake() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { pending = [] }
            return pending
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Thread-safe call counter: next() returns which call this is.
private nonisolated final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Suspends the holdOn-th activation on the coordinator queue until open(); notifies waitArrived when it arrives.
private nonisolated final class ActivationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activations = 0
    private let holdOn: Int
    private let release = DispatchSemaphore(value: 0)
    private let arrived: AsyncStream<Void>
    private let arrivedContinuation: AsyncStream<Void>.Continuation

    init(holdOn: Int) {
        self.holdOn = holdOn
        (arrived, arrivedContinuation) = AsyncStream<Void>.makeStream()
    }

    func before(_ op: AudioSessionCoordinator.Operation) {
        guard op == .activate else { return }
        let count = lock.withLock { activations += 1; return activations }
        guard count == holdOn else { return }
        arrivedContinuation.yield()
        release.wait()
    }

    func waitArrived() async {
        for await _ in arrived { return }
    }

    func open() { release.signal() }
}

@MainActor
private final class ConversationAudioDelegateSpy: ConversationAudioEngineDelegate {
    private(set) var interruptionsBegan = 0
    private(set) var interruptionsEnded = 0
    /// Order of interruption callbacks: "began" / "ended".
    private(set) var interruptionEvents: [String] = []
    private(set) var captureFailureReasons: [ConversationCaptureFailure] = []
    var captureFailures: Int { captureFailureReasons.count }
    private(set) var routeChanges: [(route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool)] = []

    func conversationAudio(didCaptureFrame index: Int, db: Double) {}
    func conversationAudio(didMeasureOutput db: Double) {}
    func conversationAudioDidBeginSentence() {}
    func conversationAudioInterruptionBegan() { interruptionsBegan += 1; interruptionEvents.append("began") }
    func conversationAudioInterruptionEnded() { interruptionsEnded += 1; interruptionEvents.append("ended") }
    func conversationAudioInterruptionEndedWithoutResume() { interruptionEvents.append("endedWithoutResume") }
    func conversationAudioCaptureFailed(reason: ConversationCaptureFailure) { captureFailureReasons.append(reason) }
    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool) {
        routeChanges.append((route, oldDeviceUnavailable))
    }
}
