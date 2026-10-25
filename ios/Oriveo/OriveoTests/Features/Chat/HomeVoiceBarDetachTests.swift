import Combine
import Foundation
import Testing
@testable import Oriveo

// After the session is handed off from home, a home bar that is still mounted (fading out / under the chat page) no longer reads the controller, and the chat page bar owns it alone.

@MainActor
@Suite("Home voice bar detach")
struct HomeVoiceBarDetachTests {
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// 200 ms of silence + 400 ms of speech + 600 ms of silence -> one complete utterance.
    private func utterance(_ controller: VoiceConversationController) {
        var frame = 0
        for db in Array(repeating: -60.0, count: 10) + Array(repeating: -30.0, count: 20) + Array(repeating: -60.0, count: 30) {
            controller.conversationAudio(didCaptureFrame: frame, db: db)
            frame += 1
        }
    }

    @Test("after the handoff the home bar is still mounted: the controller enters speaking, the home bar stays at its pre-handoff home state and receives no changes; the chat page bar gets speaking")
    func handed_off_home_bar_keeps_last_home_state() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "hello"), isSystem: true, fallback: nil
        )))
        let host = FakeVoiceChatHost()
        let created = UUID()
        let started = await session.start(origin: .home, conversationID: nil, host: host) { _, _ in
            VoiceSendContext.onConversationCreated?(created)
            return .sent(created)
        }
        #expect(started)
        await settle()
        let controller = try #require(session.controller)

        // The home bar attaches the feed and renders the pre-handoff home state once.
        let cache = HomeVoiceBarFeedCache()
        let homeBar = try #require(cache.feed(for: session))
        #expect(cache.feed(for: session) === homeBar)
        let lastHomeStatus = try #require(homeBar.statusKey)
        let lastHomeDisplay = homeBar.displayState
        #expect(VoiceConversationPage.home.reachableStatusKeys.contains(lastHomeStatus))

        var homeBarChanges = 0
        let watch = homeBar.objectWillChange.sink { homeBarChanges += 1 }
        defer { watch.cancel() }

        // The first utterance creates the conversation and hands off; home no longer gives a new feed.
        utterance(controller)
        await settle()
        #expect(session.homeVoiceSurface == nil)
        #expect(cache.feed(for: session) == nil)
        homeBarChanges = 0

        // The reply streams in and the first sentence is playing.
        probe.audio.holdPlayback = true
        host.busy.insert(created)
        host.streaming[created] = "First sentence. Second"
        host.textSubject.send()
        await settle()
        #expect(controller.displayState == .speaking)

        // The still-mounted home bar: its state is frozen at the pre-handoff home state, and controller changes are no longer forwarded.
        #expect(homeBar.statusKey == lastHomeStatus)
        #expect(homeBar.displayState == lastHomeDisplay)
        #expect(homeBarChanges == 0)

        // The chat page bar observes the session's surface directly and gets speaking.
        let chatBar = try #require(session.surface)
        #expect(chatBar.displayState == .speaking)
        if let key = chatBar.statusKey {
            #expect([.speaking, .speakingTapToInterrupt].contains(key))
        } else {
            Issue.record("chat bar has no status while speaking")
        }

        session.end(.user)
        await settle()
        #expect(homeBar.statusKey == lastHomeStatus)
    }

    // Follows the @ObservedObject semantics: every time the controller announces a change, the next tick re-renders
    // the home bar once and checks the reachability table. The whole round (handoff -> thinking -> speaking -> finished
    // and back to listening) must never read a state that is unreachable on home (that used to trap with
    // "voice bar on home reached unreachable status speaking").
    @Test("home bar re-render after every controller change following the handoff: every state read during the whole round is within the home reachability table")
    func home_bar_rerenders_stay_home_reachable_through_turn() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "hello"), isSystem: true, fallback: nil
        )))
        let host = FakeVoiceChatHost()
        let created = UUID()
        let started = await session.start(origin: .home, conversationID: nil, host: host) { _, _ in
            VoiceSendContext.onConversationCreated?(created)
            return .sent(created)
        }
        #expect(started)
        await settle()
        let controller = try #require(session.controller)
        let homeBar = try #require(HomeVoiceBarFeedCache().feed(for: session))

        // Every re-render while the home bar is mounted: read the home bar state on the tick after the controller announces a change.
        var rendered: [VoiceConversationLogic.StatusKey] = []
        var controllerStates: [VoiceConversationLogic.DisplayState] = []
        let rerender = controller.objectWillChange.sink { _ in
            Task { @MainActor in
                if let key = homeBar.statusKey { rendered.append(key) }
                if let state = controller.displayState { controllerStates.append(state) }
            }
        }
        defer { rerender.cancel() }

        // The first utterance creates the conversation and hands off, the reply streams in and the first sentence is playing.
        utterance(controller)
        await settle()
        #expect(session.homeVoiceSurface == nil)
        probe.audio.holdPlayback = true
        host.busy.insert(created)
        host.streaming[created] = "First sentence. Second"
        host.textSubject.send()
        await settle()
        #expect(controller.displayState == .speaking)

        // The reply is written and played out, back to listening.
        host.streaming[created] = "First sentence. Second sentence."
        host.busy.remove(created)
        host.finishSubject.send()
        await settle()
        probe.audio.holdPlayback = false
        probe.audio.completeCurrent()
        await settle()
        probe.audio.completeCurrent()
        await settle()

        #expect(controllerStates.contains(.speaking), "controller never reached speaking: \(controllerStates)")
        #expect(!rendered.isEmpty)
        let unreachable = rendered.filter { !VoiceConversationPage.home.reachableStatusKeys.contains($0) }
        #expect(unreachable.isEmpty, "home bar re-rendered chat-only states: \(unreachable)")

        session.end(.user)
        await settle()
    }
}
