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
        for earcon in [VoiceConversationLogic.Earcon.thinking, .end] {
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
    func vpio_enabled_before_start_and_tap_after_enable() throws {
        let log = AudioCallLog()
        let rig = VPIOOrderRig(name: "a", log: log)

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
    func superseded_lease_teardown_keeps_vpio() throws {
        let owner = VoiceAudioSessionOwner()
        let log = AudioCallLog()

        // The engine's own stop: the lease has already been taken over by a later owner.
        let direct = VPIOOrderRig(name: "d", log: log, owner: owner)
        direct.engine.sessionLease = owner.claim(.conversation)
        try direct.engine.start()
        _ = owner.claim(.conversation)
        direct.engine.stop()
        #expect(!log.events.contains("d:vpio:off"))
        #expect(log.events.filter { $0 == "d:tap:remove" }.count >= 2)

        // Cascade wrapper layer: the lease is superseded -> tearDownGraph.
        let cascade = VPIOOrderRig(name: "c", log: log, owner: owner)
        let wrapper = SessionLeasedConversationAudio(cascade.engine, owner: owner)
        try wrapper.start()
        let fresh = owner.claim(.conversation)
        wrapper.stop()
        #expect(!log.events.contains("c:vpio:off"))
        #expect(log.events.filter { $0 == "c:engine:start" }.count == 1)
        #expect(owner.current == fresh)
        #expect(cascade.deactivations == 0)
    }

    @Test("home_to_chat_handoff_never_toggles_vpio: on handoff from home to the conversation page, a late teardown of the old session never turns VPIO off, and the new session keeps it on from start to end")
    @MainActor
    func home_to_chat_handoff_never_toggles_vpio() throws {
        let owner = VoiceAudioSessionOwner()
        let log = AudioCallLog()
        let homeRig = VPIOOrderRig(name: "home", log: log, owner: owner)
        let chatRig = VPIOOrderRig(name: "chat", log: log, owner: owner)
        let home = RealtimeVoiceAudio(homeRig.engine, route: { .speaker })
        let chat = RealtimeVoiceAudio(chatRig.engine, route: { .speaker })

        home.sessionLease = owner.claim(.conversation)
        try home.startRealtime(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in }, onInterruption: {})
        chat.sessionLease = owner.claim(.conversation)
        try chat.startRealtime(uplinkSampleRate: RealtimePCM.sampleRate, onFrame: { _ in }, onInterruption: {})
        home.stopRealtime()

        let vpio = log.events.filter { $0.contains(":vpio:") }
        #expect(vpio == ["home:vpio:on", "chat:vpio:on"])
        #expect(chatRig.voiceProcessing.isEnabled)

        // Only the new session's own end turns it off.
        chat.stopRealtime()
        #expect(log.events.filter { $0.contains(":vpio:") } == ["home:vpio:on", "chat:vpio:on", "chat:vpio:off"])
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
    init(name: String, log: AudioCallLog) { self.name = name; self.log = log }
    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        log.record("\(name):tap:install")
    }
    func remove() { log.record("\(name):tap:remove") }
}

/// The real VPIOConversationAudioEngine with the VPIO toggle, input tap and engine.start replaced by recording doubles; deactivation is counted but not performed.
@MainActor
private final class VPIOOrderRig {
    let voiceProcessing: RecordingVoiceProcessing
    let tap: RecordingInputTap
    private(set) var deactivations = 0
    private(set) var engine: VPIOConversationAudioEngine!

    init(name: String, log: AudioCallLog, owner: VoiceAudioSessionOwner? = nil) {
        let voiceProcessing = RecordingVoiceProcessing(name: name, log: log)
        let tap = RecordingInputTap(name: name, log: log)
        self.voiceProcessing = voiceProcessing
        self.tap = tap
        engine = VPIOConversationAudioEngine(
            notificationCenter: NotificationCenter(), owner: owner,
            deactivateSession: { [unowned self] _ in deactivations += 1 },
            inputTap: { _ in tap },
            voiceProcessing: { _ in voiceProcessing },
            startEngine: { _ in log.record("\(name):engine:start") }
        )
    }
}

@MainActor
private final class ConversationAudioDelegateSpy: ConversationAudioEngineDelegate {
    private(set) var interruptionsBegan = 0
    private(set) var interruptionsEnded = 0
    private(set) var routeChanges: [(route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool)] = []

    func conversationAudio(didCaptureFrame index: Int, db: Double) {}
    func conversationAudio(didMeasureOutput db: Double) {}
    func conversationAudioDidBeginSentence() {}
    func conversationAudioInterruptionBegan() { interruptionsBegan += 1 }
    func conversationAudioInterruptionEnded() { interruptionsEnded += 1 }
    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool) {
        routeChanges.append((route, oldDeviceUnavailable))
    }
}
