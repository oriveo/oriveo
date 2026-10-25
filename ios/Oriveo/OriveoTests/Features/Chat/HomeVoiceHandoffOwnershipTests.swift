import Combine
import Foundation
import Testing
@testable import Oriveo

// Home voice bar ownership switches on the "handed off" event, not on whether the conversation id has been written back yet.

@MainActor
@Suite("Home voice handoff ownership")
struct HomeVoiceHandoffOwnershipTests {
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

    @Test("the first utterance creates the conversation and hands off: the reply enters speaking before the id is written back, and the home voice bar no longer observes the controller")
    func handoff_before_id_writeback_detaches_home_bar() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies(listening: DictationEngineChoice(
            engine: FixedTextSTT(text: "hello"), isSystem: true, fallback: nil
        )))
        let host = FakeVoiceChatHost()
        let created = UUID()
        // Same as the first utterance in AppState: right after the conversation is created and before the chat page opens, call back the new id synchronously.
        var presentedAt: VoiceConversationSession.HostKey?
        let started = await session.start(origin: .home, conversationID: nil, host: host) { _, id in
            #expect(id == nil)
            VoiceSendContext.onConversationCreated?(created)
            presentedAt = .conversation(created)
            return .sent(created)
        }
        #expect(started)
        await settle()
        let controller = try #require(session.controller)
        let port = try #require(session.port)
        #expect(session.homeVoiceSurface != nil)

        // Inject the timing: the id write-back is postponed until after the reply enters speaking.
        let writeBack = port.onConversationChanged
        var deferred: [UUID] = []
        port.onConversationChanged = { deferred.append($0) }

        utterance(controller)
        await settle()
        #expect(presentedAt == .conversation(created))
        #expect(deferred == [created])
        #expect(session.conversationID == nil)
        #expect(session.homeVoiceSurface == nil)

        // The reply streams in and the first sentence is playing (playback hangs and never finishes).
        probe.audio.holdPlayback = true
        host.busy.insert(created)
        host.streaming[created] = "First sentence. Second"
        host.textSubject.send()
        await settle()
        #expect(controller.displayState == .speaking)
        // During the reply: the home bar cannot get the controller, so speaking / interrupt / pending confirmation never reach home.
        #expect(session.homeVoiceSurface == nil)

        deferred.forEach { writeBack?($0) }
        #expect(session.conversationID == created)
        #expect(session.homeVoiceSurface == nil)
        #expect(session.isPresented(in: created))

        session.end(.user)
        await settle()
        #expect(session.homeVoiceSurface == nil)
    }

    @Test("a conversation started from the chat page does not belong to the home bar")
    func chat_origin_never_owned_by_home() async throws {
        let probe = SessionProbe()
        let session = VoiceConversationSession(dependencies: probe.dependencies())
        await session.start(origin: .chat, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in .refused }
        await settle()
        #expect(session.isActive)
        #expect(session.homeVoiceSurface == nil)
        session.end(.user)
        await settle()
    }
}
