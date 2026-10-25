import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// Ownership of the AVAudioSession shared by dictation and voice conversation.
/// Waiting always goes through continuations (the owner's onWaiterQueued / waitForConversationRelease), never sleep polling.
@Suite("Voice audio session owner", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct VoiceAudioSessionOwnerTests {

    @Test("A late stop from a superseded dictation after the conversation has claimed the session: no deactivation, and the conversation lease stays")
    func test_staleDictationRelease_afterConversationClaim_doesNotDeactivate() throws {
        let owner = VoiceAudioSessionOwner()
        let activator = RecordingSessionActivator()
        let input = FakeInputTap(sampleRate: 48_000)
        let capture = EngineAudioCapture(activator: activator, owner: owner, input: input)

        // Baseline: with no contention, stop deactivates as usual.
        try capture.start(handlers: [])
        capture.stop()
        #expect(activator.calls == [.activate, .deactivate])
        #expect(owner.current == nil)

        try capture.start(handlers: [])
        let dictation = try #require(owner.current)
        #expect(dictation.client == .dictation)
        let conversation = owner.claim(.conversation)
        #expect(conversation.generation > dictation.generation)
        capture.stop()

        #expect(input.stopCount == 2)
        #expect(activator.calls == [.activate, .deactivate, .activate])
        #expect(owner.current == conversation)
        #expect(!owner.release(dictation))
        #expect(owner.release(conversation))
        #expect(owner.current == nil)
    }

    @Test("While a conversation lease is held, dictation waits; releasing a lease superseded by a newer conversation does not wake it, only releasing the current conversation lease does")
    func test_dictationClaim_waitsForConversationRelease() async {
        let queued = QueuedSignal()
        let owner = VoiceAudioSessionOwner(onWaiterQueued: { queued.fire() })

        // No conversation lease: returns immediately without queueing.
        await owner.waitForConversationRelease()
        #expect(owner.waitingCount == 0)

        let first = owner.claim(.conversation)
        var waiter: Task<Void, Never>?
        await queued.wait {
            waiter = Task { await owner.waitForConversationRelease() }
        }
        #expect(owner.waitingCount == 1)

        let second = owner.claim(.conversation)
        #expect(!owner.release(first))
        #expect(owner.waitingCount == 1)
        #expect(owner.current == second)

        #expect(owner.release(second))
        await waiter?.value
        #expect(owner.waitingCount == 0)
        #expect(owner.current == nil)

        // The lease dictation claims afterwards belongs to a new generation.
        let dictation = owner.claim(.dictation)
        #expect(dictation.generation > second.generation)
    }

    @Test("Every conversation end path (cancel button / grace period expiry / after the idle earcon / start failure) releases the lease after audio.stop")
    func test_conversationRelease_inEveryEndPath() async throws {
        // Cancel button: stop runs synchronously, then the lease is released.
        do {
            let rig = SessionRig()
            #expect(await rig.start())
            #expect(rig.owner.current?.client == .conversation)
            rig.session.end(.user)
            await rig.owner.waitForConversationRelease()
            #expect(rig.audio.stops == 1)
            #expect(rig.audio.leaseHeldAtStop == [true])
            #expect(rig.owner.current == nil)
        }
        // Grace period expires after leaving the page: ends as if the user went back.
        do {
            let rig = SessionRig()
            rig.session.hostAppeared(rig.conversation)
            #expect(await rig.start())
            rig.session.hostDisappeared(rig.conversation)
            await rig.owner.waitForConversationRelease()
            #expect(!rig.session.isActive)
            #expect(rig.audio.stops == 1)
            #expect(rig.audio.leaseHeldAtStop == [true])
            #expect(rig.owner.current == nil)
        }
        // Idle end: the closing earcon plays first and stop is deferred; the session is already dismissed but the lease is only released after stop.
        do {
            let rig = SessionRig()
            #expect(await rig.start())
            rig.clock.nowMs = VoiceConversationLogic.Constants.idleTimeoutMs
            rig.clock.tick()
            #expect(!rig.session.isActive)
            #expect(rig.audio.earcons == [.end])
            #expect(rig.audio.stops == 0)
            #expect(rig.owner.current?.client == .conversation)
            await rig.owner.waitForConversationRelease()
            #expect(rig.audio.stops == 1)
            #expect(rig.audio.leaseHeldAtStop == [true])
            #expect(rig.owner.current == nil)
        }
        // Start failure (session activation throws): the conversation is not entered and the lease is released immediately.
        do {
            let rig = SessionRig()
            rig.audio.failStart = true
            #expect(await rig.start() == false)
            #expect(!rig.session.isActive)
            #expect(rig.owner.current == nil)
            #expect(rig.audio.stops == 0)
        }
        // The controller is deallocated before stop: the lease is released along with the wrapper, so dictation does not wait forever.
        do {
            let owner = VoiceAudioSessionOwner()
            var audio: SessionLeasedConversationAudio? = SessionLeasedConversationAudio(LeaseProbeAudio(owner: owner), owner: owner)
            try audio?.start()
            #expect(owner.current?.client == .conversation)
            audio = nil
            #expect(owner.current == nil)
        }
    }
}

extension VoiceAudioSessionOwnerTests {
    @Test("A conversation is reopened before the idle end's deferred stop arrives: the old wrapper does not call the engine's stop (so the new session is not deactivated), and the new lease stays")
    func test_staleConversationDelayedStop_afterNewConversationClaim_doesNotDeactivate() throws {
        let owner = VoiceAudioSessionOwner()
        let oldEngine = LeaseProbeAudio(owner: owner)
        let old = SessionLeasedConversationAudio(oldEngine, owner: owner)
        try old.start()
        let fresh = SessionLeasedConversationAudio(LeaseProbeAudio(owner: owner), owner: owner)
        try fresh.start()
        let current = try #require(owner.current)
        #expect(current.client == .conversation)

        old.stop()

        #expect(oldEngine.stops == 0)
        #expect(oldEngine.graphTearDowns == 1)
        #expect(owner.current == current)
    }
}

extension VoiceAudioSessionOwnerTests {
    @Test("The session already belongs to a newer conversation when the old engine's deferred stop arrives: only tear down the graph (engine stopped, observers removed) without deactivating the session")
    func test_staleConversationEngine_tearsDownGraphWithoutDeactivating() throws {
        let rig = VPIORig()
        // No real graph is built: the lease is handed to the engine the way the wrapper does it, and the running state is entered through the test hook.
        rig.engine.sessionLease = rig.owner.claim(.conversation)
        rig.engine.enterRunningStateForTesting()
        #expect(rig.engine.observerCountForTesting > 0)
        let fresh = rig.owner.claim(.conversation)

        rig.engine.stop()

        #expect(!rig.engine.isEngineRunningForTesting)
        #expect(rig.engine.observerCountForTesting == 0)
        #expect(rig.tap.removals == 1)
        rig.postInterruption()
        #expect(rig.delegate.interruptionsBegan == 0)
        #expect(rig.deactivations == 0)
        #expect(rig.owner.current == fresh)
    }

    @Test("Teardown of the current conversation: the lease is still the current generation, so the session is deactivated once; the graph-only teardown entry does not deactivate")
    func test_currentConversationTeardown_deactivatesSession() throws {
        let rig = VPIORig()
        let lease = rig.owner.claim(.conversation)
        rig.engine.sessionLease = lease
        rig.engine.enterRunningStateForTesting()

        rig.engine.stop()

        #expect(!rig.engine.isEngineRunningForTesting)
        #expect(rig.engine.observerCountForTesting == 0)
        #expect(rig.tap.removals == 1)
        #expect(rig.deactivations == 1)
        #expect(rig.owner.current == lease)

        // The graph-only teardown entry likewise does not deactivate once the lease has been superseded.
        let again = VPIORig()
        again.engine.sessionLease = again.owner.claim(.conversation)
        again.engine.enterRunningStateForTesting()
        again.engine.tearDownGraph()
        #expect(again.engine.observerCountForTesting == 0)
        #expect(again.tap.removals == 1)
        #expect(again.deactivations == 0)
    }
}

extension VoiceAudioSessionOwnerTests {
    @Test("Production dependencies: the cascade / realtime engines' owner is the same instance as deps.audioSession")
    func test_productionEngines_shareDependenciesOwner() throws {
        let owner = VoiceAudioSessionOwner()
        let deps = VoiceConversationSession.Dependencies.production(audioSession: owner)
        #expect(deps.audioSession === owner)

        let port = AppStateVoiceChatPort(host: FakeVoiceChatHost(), conversationID: nil) { _, _ in .refused }
        let controller = deps.makeController(DictationEngineChoice(engine: SilentSTT(), isSystem: true, fallback: nil), port)
        let leased = try #require(Mirror(reflecting: controller).descendant("audio") as? SessionLeasedConversationAudio)
        #expect(leased.sessionOwner === owner)
        let cascadeEngine = try #require(leased.engine as? VPIOConversationAudioEngine)
        #expect(cascadeEngine.sessionOwner === owner)

        let appState = AppState(seedDemoData: false, sessionUID: "audio-owner-\(UUID().uuidString)")
        let realtimeAudio = RealtimeVoiceSessionBuilder.production(appState: appState, audioSession: owner).makeAudio()
        #expect(realtimeAudio.sessionOwner === owner)
    }
}

// MARK: - Fixtures

/// One cascade conversation: a real VoiceConversationSession plus a real VoiceConversationController, with audio wrapped in SessionLeasedConversationAudio.
@MainActor
private final class SessionRig {
    let owner: VoiceAudioSessionOwner
    let clock: PortManualClock
    let audio: LeaseProbeAudio
    let session: VoiceConversationSession
    let conversation = UUID()

    init() {
        let owner = VoiceAudioSessionOwner()
        let clock = PortManualClock()
        let audio = LeaseProbeAudio(owner: owner)
        var deps = SessionProbe().dependencies()
        deps.audioSession = owner
        deps.makeController = { choice, port in
            VoiceConversationController(
                audio: SessionLeasedConversationAudio(audio, owner: owner),
                dictation: DictationEngineSource { choice },
                readAloud: .fixed(MuteSpeechEngine()),
                chat: port,
                prompt: VoiceConversationCopy.prompt,
                clock: clock,
                memory: VoiceBargeInMemory(defaults: UserDefaults(suiteName: "voice-owner-\(UUID())")!, osMajorVersion: 27),
                stopReadAloud: {},
                detectLanguage: { _ in "en" }
            )
        }
        self.owner = owner
        self.clock = clock
        self.audio = audio
        session = VoiceConversationSession(dependencies: deps)
    }

    func start() async -> Bool {
        await session.start(origin: .chat, conversationID: conversation, host: FakeVoiceChatHost()) { _, id in
            .sent(id ?? UUID())
        }
    }
}

private struct StartFailed: Error {}

/// Records whether the lease is still held at stop (release must come after stop); failStart simulates a session activation failure.
@MainActor
private final class LeaseProbeAudio: ConversationAudioEngine, SessionLeaseAwareAudio {
    weak var delegate: ConversationAudioEngineDelegate?
    var sessionLease: VoiceAudioSessionOwner.Lease?
    private(set) var graphTearDowns = 0
    func tearDownGraph() { graphTearDowns += 1 }
    var sessionOwner: VoiceAudioSessionOwner? { owner }
    var route: VoiceConversationLogic.Route = .headphones
    var isSpeakerRoute: Bool { route.isSpeaker }
    var failStart = false
    private(set) var stops = 0
    private(set) var leaseHeldAtStop: [Bool] = []
    private(set) var earcons: [VoiceConversationLogic.Earcon] = []
    private let owner: VoiceAudioSessionOwner

    init(owner: VoiceAudioSessionOwner) { self.owner = owner }

    func start() throws {
        if failStart { throw StartFailed() }
    }

    func stop() {
        stops += 1
        leaseHeldAtStop.append(owner.current?.client == .conversation)
    }

    func setCaptureMuted(_ muted: Bool) {}
    func pauseCapture() {}
    func resumeCapture() {}
    func beginUtterance(fromFrame frame: Int) {}
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) { completion(nil) }
    func discardUtterance() {}
    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome { .finished }
    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome { .finished }
    func pausePlayback() {}
    func resumePlayback(fromSentenceStart: Bool) {}
    func stopPlayback() {}
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { earcons.append(earcon) }
}

/// Releases wait once someone is queued in the waiting queue.
private nonisolated final class QueuedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fired = true
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume()
    }

    @MainActor
    func wait(after start: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if fired { return true }
                self.continuation = continuation
                return false
            }
            start()
            if resumeNow { continuation.resume() }
        }
    }
}

/// Records session activate / deactivate calls.
nonisolated final class RecordingSessionActivator: AudioSessionActivating, @unchecked Sendable {
    enum Call: Equatable { case activate, deactivate }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    func activateForRecording() throws { lock.withLock { _calls.append(.activate) } }
    func deactivate() { lock.withLock { _calls.append(.deactivate) } }
}

/// An input tap that never touches a real engine; onStart is called the moment the tap is installed.
nonisolated final class FakeInputTap: AudioInputTap, @unchecked Sendable {
    let format: AVAudioFormat
    var onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(sampleRate: Double) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    func start(bufferSize: AVAudioFrameCount, handlers: [AudioBufferHandler]) throws -> AVAudioFormat {
        startCount += 1
        onStart?()
        return format
    }

    func stop() { stopCount += 1 }
}

/// A real VPIOConversationAudioEngine whose deactivations are counted through an injected closure; notifications go through a private center.
@MainActor
private final class VPIORig {
    let owner = VoiceAudioSessionOwner()
    let center = NotificationCenter()
    let delegate = InterruptionSpy()
    let tap = CountingInputTap()
    private(set) var deactivations = 0
    private(set) var engine: VPIOConversationAudioEngine!

    init() {
        engine = VPIOConversationAudioEngine(
            session: .sharedInstance(), notificationCenter: center, owner: owner,
            deactivateSession: { [unowned self] _ in deactivations += 1 },
            inputTap: { [tap] _ in tap }
        )
        engine.delegate = delegate
    }

    func postInterruption() {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            center.post(name: AVAudioSession.didBecomeInactiveNotification, object: session)
        } else {
            center.post(name: AVAudioSession.interruptionNotification, object: session,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        }
    }
}

@MainActor
private final class InterruptionSpy: ConversationAudioEngineDelegate {
    private(set) var interruptionsBegan = 0
    func conversationAudio(didCaptureFrame index: Int, db: Double) {}
    func conversationAudio(didMeasureOutput db: Double) {}
    func conversationAudioDidBeginSentence() {}
    func conversationAudioInterruptionBegan() { interruptionsBegan += 1 }
    func conversationAudioInterruptionEnded() {}
    func conversationAudio(routeChanged route: VoiceConversationLogic.Route, oldDeviceUnavailable: Bool) {}
}

/// Counts input node tap installs / removals.
@MainActor
private final class CountingInputTap: ConversationInputTap {
    private(set) var installs = 0
    private(set) var removals = 0
    func install(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        installs += 1
    }
    func remove() { removals += 1 }
}
