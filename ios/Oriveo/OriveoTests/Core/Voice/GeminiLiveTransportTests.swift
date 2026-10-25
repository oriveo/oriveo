import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// gemini_live connection, GoAway resume and end-of-session; replayed through a fake socket, no network.
@Suite("GeminiLiveTransport", .timeLimit(.minutes(1)))
struct GeminiLiveTransportTests {

    // MARK: - Fixture and input

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/realtime-events.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixtureCase(_ group: String, _ id: String) throws -> [String: Any] {
        let all = try #require(try fixture()[group] as? [[String: Any]])
        return try #require(all.first { $0["id"] as? String == id })
    }

    private static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON-escaped body of the production realtime delivery section, substituted for the DELIVERY placeholder in the fixture.
    private static func delivery() throws -> String {
        String(try canonical(ContextAssembler.deliveryRealtime).dropFirst().dropLast())
    }

    private static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private static func text(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    /// Builds the input through the production plan projection: session instructions "Be brief." plus history Hi / Hello.
    private static func input(withHistory: Bool = true) throws -> RealtimeTransportInput {
        let messages = withHistory ? [
            TestFactories.makeMessage(role: .user, text: "Hi"),
            TestFactories.makeMessage(role: .assistant, text: "Hello"),
        ] : []
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 131_072, currentSessionId: nil, sessionMessageIds: [], checkpoint: nil
        )
        let plan = ContextAssembler.assembleRealtimeSession(sessionInput)
        return try #require(PlannedRealtimeSession.from(plan)).transportInput()
    }

    private static let config = GeminiLiveConfig(
        host: "generativelanguage.googleapis.com",
        path: "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        model: "gemini-3.8-live",
        voice: "Kore",
        apiKey: "k+y/="
    )

    private static func setup(of frame: String) throws -> [String: Any] {
        try #require(try json(frame)["setup"] as? [String: Any])
    }

    private static func handle(of frame: String) throws -> String? {
        let setup = try setup(of: frame)
        return (setup["sessionResumption"] as? [String: Any])?["handle"] as? String
    }

    private static let setupComplete = #"{"setupComplete":{}}"#
    private static func resumable(_ handle: String) -> String {
        #"{"sessionResumptionUpdate":{"resumable":true,"newHandle":"\#(handle)"}}"#
    }
    private static func speak(_ text: String) -> String {
        #"{"serverContent":{"outputTranscription":{"text":"\#(text)"}}}"#
    }
    private static let turnComplete = #"{"serverContent":{"turnComplete":true}}"#
    private static func goAway(_ timeLeft: String? = nil) -> String {
        timeLeft.map { #"{"goAway":{"timeLeft":"\#($0)"}}"# } ?? #"{"goAway":{}}"#
    }

    // MARK: - Cases

    @Test func history_sent_after_setup_complete() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        let input = try Self.input()
        var events = transport.openRealtimeSession(transport: input).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let socket = try #require(await sockets.next())

        let mapCase = try Self.fixtureCase("mapCases", "gemini_normal_turn")
        let messages = try #require((mapCase["input"] as? [String: Any])?["messages"] as? [[String: Any]])
        let expected = try #require(mapCase["expected"] as? [Any])
        for message in messages { socket.push(try Self.text(message)) }
        var received: [Any] = []
        while received.count < expected.count, let event = try await events.next() {
            received.append(event.jsonObject)
        }
        #expect(try Self.canonical(received) == Self.canonical(expected))

        // Frames sent = open_gemini_history_in_client_content; the fixture's DELIVERY placeholder is replaced with the production realtime delivery section
        let openCase = try Self.fixtureCase("openCases", "open_gemini_history_in_client_content")
        let opening = try #require(openCase["expected"] as? [String: Any])
        let frames = try #require(opening["beforeReady"] as? [Any]) + (try #require(opening["afterReady"] as? [Any]))
        let expectedFrames = try Self.canonical(frames)
            .replacingOccurrences(of: #"\nDELIVERY\n"#, with: #"\n"# + Self.delivery() + #"\n"#)
        #expect(try Self.canonical(socket.sent.map { try Self.json($0) }) == expectedFrames)
        #expect(input.instructions.contains("Be brief."))

        // clientContent is sent only after setupComplete arrives
        let log = socket.log
        let delivered = try #require(log.firstIndex(of: "recv:\(try Self.text(messages[0]))"))
        let history = try #require(log.firstIndex { $0.hasPrefix("send:") && $0.contains("clientContent") })
        #expect(delivered < history)
        await transport.close()
    }

    @Test func connect_uses_authenticated_url() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let socket = try #require(await sockets.next())
        #expect(socket.url.absoluteString == GeminiLiveWire.authenticatedURL(
            host: Self.config.host, path: Self.config.path, key: Self.config.apiKey
        ))
        #expect(socket.url.absoluteString.hasSuffix("?key=k%2By%2F%3D"))
        #expect(!Self.config.description.contains(Self.config.apiKey))
        #expect(!String(reflecting: Self.config).contains(Self.config.apiKey))
        #expect(!"\(Self.config)".contains(Self.config.apiKey))
        socket.push(Self.setupComplete)
        #expect(try await events.next() == .ready)
        await transport.close()
    }

    @Test func resumed_open_sends_handle_not_history() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config, resumeHandle: "h0")
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let socket = try #require(await sockets.next())
        socket.push(Self.setupComplete)
        #expect(try await events.next() == .ready)
        socket.push(Self.speak("Hi"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Hi", final: false))

        #expect(socket.sent.count == 1)
        let setup = try Self.setup(of: try #require(socket.sent.first))
        #expect(try Self.handle(of: socket.sent[0]) == "h0")
        #expect(setup["historyConfig"] == nil)
        #expect(!socket.sent.contains { $0.contains("clientContent") })
        #expect(await transport.lastResumeHandle == "h0")
        await transport.close()
    }

    @Test func go_away_idle_reconnects_with_last_handle() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.resumable("h2"))
        first.push(Self.goAway("10s"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .resumable(handle: "h2"))
        #expect(try await events.next() == .goAway(timeLeftMs: 10_000))

        let second = try #require(await sockets.next())
        let setup = await second.frame(0)
        #expect(first.closed)
        #expect(second.url == first.url)
        #expect(try Self.handle(of: setup) == "h2")
        #expect(try Self.setup(of: setup)["historyConfig"] == nil)
        #expect(await transport.lastResumeHandle == "h2")

        // Resume setup = beforeReady of open_gemini_resume_sends_handle_not_history (original instructions, latest handle, no history)
        let resumeCase = try Self.fixtureCase("openCases", "open_gemini_resume_sends_handle_not_history")
        let resumeOpening = try #require(resumeCase["expected"] as? [String: Any])
        let expectedSetup = try Self.canonical(try #require(resumeOpening["beforeReady"] as? [Any]))
            .replacingOccurrences(of: #"\nDELIVERY\n"#, with: #"\n"# + Self.delivery() + #"\n"#)
            .replacingOccurrences(of: #""handle":"h-1""#, with: #""handle":"h2""#)
        second.push(Self.setupComplete)
        second.push(Self.speak("Back"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Back", final: false))
        #expect(try Self.canonical(second.sent.map { try Self.json($0) }) == expectedSetup)
        #expect(!second.sent.contains { $0.contains("clientContent") })
        await transport.close()
    }

    @Test func go_away_mid_turn_waits_for_turn_complete() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.speak("It's"))
        first.push(Self.goAway())
        first.push(Self.speak(" late"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "It's", final: false))
        #expect(try await events.next() == .goAway(timeLeftMs: nil))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "It's late", final: false))
        #expect(!first.closed)
        #expect(hub.opened == 1)

        first.push(Self.turnComplete)
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "It's late", final: true))
        #expect(try await events.next() == .assistantTurnDone(itemId: nil, status: .completed, text: "It's late"))
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        #expect(first.closed)
        await transport.close()
    }

    @Test func go_away_forces_switch_when_time_left_runs_out() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.speak("Long"))
        first.push(Self.goAway("5s"))
        first.push(Self.speak(" answer"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Long", final: false))
        #expect(try await events.next() == .goAway(timeLeftMs: 5_000))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Long answer", final: false))
        #expect(await sleeps.next() == 4_000)
        #expect(!first.closed)
        #expect(hub.opened == 1)

        hub.releaseSleep()
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        #expect(first.closed)
        await transport.close()

        // A timeLeft beyond the Int64 nanosecond range is treated as untimed: no crash, no switch, wait for turnComplete
        let hugeHub = FakeSocketHub()
        let huge = hugeHub.transport(config: Self.config)
        var hugeEvents = huge.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var hugeSockets = hugeHub.sockets.makeAsyncIterator()
        let old = try #require(await hugeSockets.next())
        old.push(Self.setupComplete)
        old.push(Self.resumable("h1"))
        old.push(Self.speak("Long"))
        old.push(Self.goAway("99999999999s"))
        old.push(Self.speak(" answer"))
        #expect(try await hugeEvents.next() == .ready)
        #expect(try await hugeEvents.next() == .resumable(handle: "h1"))
        #expect(try await hugeEvents.next() == .assistantTranscript(itemId: nil, text: "Long", final: false))
        #expect(try await hugeEvents.next() == .goAway(timeLeftMs: 99_999_999_999_000))
        #expect(try await hugeEvents.next() == .assistantTranscript(itemId: nil, text: "Long answer", final: false))
        #expect(!old.closed)
        #expect(hugeHub.opened == 1)
        old.push(Self.turnComplete)
        let resumed = try #require(await hugeSockets.next())
        #expect(try Self.handle(of: await resumed.frame(0)) == "h1")
        await huge.close()

        // The default sleep saturates without trapping, and cancelling ends it
        let saturated = Task { try await GeminiLiveTransport.defaultSleep(Int.max) }
        saturated.cancel()
        let outcome = await saturated.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    private static func hear(_ text: String) -> String {
        #"{"serverContent":{"inputTranscription":{"text":"\#(text)"}}}"#
    }
    private static let activityStart = #"{"voiceActivity":{"type":"ACTIVITY_START"}}"#

    @Test func gemini_switch_flushes_pending_user_text() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.speak("Long"))
        first.push(Self.goAway("5s"))
        first.push(Self.activityStart)
        first.push(Self.hear("Wait"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Long", final: false))
        #expect(try await events.next() == .goAway(timeLeftMs: 5_000))
        #expect(try await events.next() == .userSpeechStarted(itemId: nil))
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Wait", final: false))
        #expect(await sleeps.next() == 4_000)

        hub.releaseSleep()
        let second = try #require(await sockets.next())
        // Before switching connections the old mapper emits the user text carried into the next turn as final; an unfinished assistant reply is not flushed
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Wait", final: true))
        second.push(Self.setupComplete)
        second.push(Self.speak("Next"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Next", final: false))
        await transport.close()
    }

    @Test func gemini_switch_flushes_current_turn_user_text() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.hear("Hello"))
        first.push(Self.goAway("5s"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: false))
        #expect(try await events.next() == .goAway(timeLeftMs: 5_000))
        #expect(await sleeps.next() == 4_000)

        hub.releaseSleep()
        let second = try #require(await sockets.next())
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: true))
        second.push(Self.setupComplete)
        second.push(Self.speak("Hi"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Hi", final: false))
        await transport.close()
    }

    @Test func gemini_expiry_without_handle_flushes_pending_user_text() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.hear("Hello"))
        first.push(Self.goAway())
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: false))
        #expect(try await events.next() == .goAway(timeLeftMs: nil))

        // No handle: end the session once the server closes it, first emitting any unfinished user text as final
        first.finishFromServer()
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: true))
        #expect(try await events.next() == .sessionEnded(reason: "go_away"))
        #expect(try await events.next() == nil)
        #expect(hub.opened == 1)
    }

    @Test func gemini_session_expired_flushes_pending_user_text() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.hear("Hello"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: false))

        // 1008 session expired: before ending with sessionExpired, first emit any unfinished user text as final
        first.finishFromServer(closeCode: 1008, reason: "session expired")
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: true))
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .sessionExpired(reason: "session expired"))
        #expect(hub.opened == 1)
    }

    @Test func gemini_unexpected_close_without_handle_flushes_pending_user_text() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.speak("Hi"))
        first.push(Self.hear("Hello"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Hi", final: false))
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: false))

        // Unexpected disconnect without a handle: before ending with connectionClosed, first finalize the user text; an unfinished assistant reply is not flushed
        first.finishFromServer()
        #expect(try await events.next() == .userTranscript(itemId: nil, text: "Hello", final: true))
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .connectionClosed)
        #expect(hub.opened == 1)
    }

    @Test func resumed_ready_not_reemitted() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.goAway())
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .goAway(timeLeftMs: nil))

        let second = try #require(await sockets.next())
        second.push(Self.setupComplete)
        second.push(Self.speak("Back"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Back", final: false))
        #expect(!second.sent.contains { $0.contains("clientContent") })
        await transport.close()
    }

    @Test func audio_buffered_during_switch_and_flushed_after_ready() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        await transport.appendAudio(base64: "ZZZZ")
        #expect(first.sent.last.map { $0.contains("ZZZZ") } == true)

        first.push(Self.goAway())
        #expect(try await events.next() == .goAway(timeLeftMs: nil))
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        let big1 = String(repeating: "A", count: 120_000)
        let big2 = String(repeating: "B", count: 120_000)
        await transport.appendAudio(base64: big1)
        await transport.appendAudio(base64: big2)
        await transport.appendAudio(base64: "CCCC")
        #expect(second.sent.count == 1)

        second.push(Self.setupComplete)
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        let audio = try second.sent.dropFirst().map { frame -> String in
            let input = try #require(try Self.json(frame)["realtimeInput"] as? [String: Any])
            return try #require((input["audio"] as? [String: Any])?["data"] as? String)
        }
        #expect(audio == [big2, "CCCC"])
        #expect(!first.sent.contains { $0.contains("CCCC") })

        await transport.appendAudio(base64: "DDDD")
        #expect(second.sent.last.map { $0.contains("DDDD") } == true)
        await transport.close()
    }

    @Test func go_away_without_handle_ends_session() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.goAway())
        first.push(Self.speak("Bye"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .goAway(timeLeftMs: nil))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Bye", final: false))
        #expect(!first.closed)

        first.finishFromServer()
        #expect(try await events.next() == .sessionEnded(reason: "go_away"))
        #expect(try await events.next() == nil)
        #expect(hub.opened == 1)
    }

    @Test func unexpected_close_fails_stream() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        // An unexpected disconnect without a resume handle still ends with an error
        first.finishFromServer()
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .connectionClosed)
        #expect(hub.opened == 1)
        Self.expectNoKey(try #require(closeError))

        // First connection fails: the underlying URLError (including the URL with the key) does not leak, only our own case is thrown
        let failingHub = FakeSocketHub(failConnect: true)
        let failing = failingHub.transport(config: Self.config)
        var failingEvents = failing.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var connectError: (any Error)?
        do { _ = try await failingEvents.next() } catch { connectError = error }
        #expect(connectError as? GeminiLiveTransportError == .connectFailed)
        Self.expectNoKey(try #require(connectError))
    }

    @Test func close_finishes_stream_without_event() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        await transport.close()
        #expect(try await events.next() == nil)
        #expect(first.closed)
        #expect(hub.opened == 1)

        // Cancelling collection also closes the socket
        let cancelHub = FakeSocketHub()
        let cancelled = cancelHub.transport(config: Self.config)
        let stream = cancelled.openRealtimeSession(transport: try Self.input())
        var cancelSockets = cancelHub.sockets.makeAsyncIterator()
        let consumer = Task {
            for try await _ in stream {}
        }
        let socket = try #require(await cancelSockets.next())
        socket.push(Self.setupComplete)
        consumer.cancel()
        await socket.waitClosed()
        #expect(socket.closed)
    }

    // MARK: - Resume after an unexpected disconnect

    // MARK: - Uplink backlog detected as a stall

    /// A 100 ms 16 kHz PCM16 frame (the capture side already outputs at uplinkSampleRate), all samples equal to value; chunks are the verbatim base64.
    private static func uplinkFrames(_ count: Int) -> (frames: [Data], chunks: [String]) {
        let frames = (0..<count).map { index -> Data in
            var data = Data()
            let bits = UInt16(bitPattern: Int16(index + 1))
            for _ in 0..<1600 {
                data.append(UInt8(bits & 0xFF))
                data.append(UInt8(bits >> 8))
            }
            return data
        }
        return (frames, frames.map { $0.base64EncodedString() })
    }

    private static func audioChunks(_ sent: [String]) throws -> [String] {
        try sent.compactMap { frame -> String? in
            guard let input = try Self.json(frame)["realtimeInput"] as? [String: Any] else { return nil }
            return try #require((input["audio"] as? [String: Any])?["data"] as? String)
        }
    }

    /// After the first connection is Ready the upstream stalls while 10 s frames keep being pushed: once the backlog exceeds 16 kHz × 2 B × 8 s the old connection is closed and resumed with the handle,
    /// and after the new connection is Ready the newest frames within the buffer cap (about 5 s) are replayed. Returns the resumed connection and the number of frames pushed.
    private static func stallAndResume(
        _ hub: FakeSocketHub,
        _ control: GeminiLiveSessionControl,
        _ events: inout AsyncThrowingStream<RealtimeSessionEvent, Error>.AsyncIterator,
        _ sockets: inout AsyncStream<FakeGeminiSocket>.AsyncIterator
    ) async throws -> (socket: FakeGeminiSocket, pushed: Int) {
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        first.stallSends(from: first.sent.count)
        let (frames, chunks) = Self.uplinkFrames(100)
        let threshold = 16_000 * 2 * 8
        let chunkBytes = try #require(Data(base64Encoded: chunks[0])).count
        #expect(chunkBytes * 80 <= threshold && chunkBytes * 81 > threshold)
        frames.forEach(control.sendAudio)
        await first.waitClosed()
        await control.drainUplink()
        #expect(try Self.audioChunks(first.sent).isEmpty)

        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        #expect(second.sent.count == 1)
        second.push(Self.setupComplete)
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        var kept: [String] = []
        var keptChars = 0
        for chunk in chunks.reversed() {
            guard keptChars + chunk.count <= GeminiLiveTransport.audioBufferLimit else { break }
            kept.insert(chunk, at: 0)
            keptChars += chunk.count
        }
        #expect(kept.count < chunks.count)
        #expect(try Self.audioChunks(second.sent) == kept)
        return (second, frames.count)
    }

    @Test func stalled_send_drops_and_resumes() async throws {
        let hub = FakeSocketHub()
        let control = GeminiLiveSessionControl(transport: hub.transport(config: Self.config))
        var events = control.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let (second, pushed) = try await Self.stallAndResume(hub, control, &events, &sockets)

        // The new connection keeps receiving frames normally
        let (more, moreChunks) = Self.uplinkFrames(pushed + 1)
        control.sendAudio(more[pushed])
        await control.drainUplink()
        #expect(try Self.audioChunks(second.sent).last == moreChunks[pushed])
        #expect(!second.closed)
        #expect(hub.opened == 2)
        control.close()
        await second.waitClosed()
    }

    @Test func resume_flush_does_not_trip_stall() async throws {
        let hub = FakeSocketHub()
        let control = GeminiLiveSessionControl(transport: hub.transport(config: Self.config))
        var events = control.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let (second, pushed) = try await Self.stallAndResume(hub, control, &events, &sockets)
        let flushed = try Self.audioChunks(second.sent).count

        // After the full buffer (about 5 s) has been replayed, another 7 s backlog builds up: the replay already sent no longer counts toward the backlog, so a total above 8 s is not judged a stall
        second.stallSends(from: second.sent.count)
        let (all, allChunks) = Self.uplinkFrames(pushed + 70)
        all[pushed...].forEach(control.sendAudio)
        second.releaseSends()
        await control.drainUplink()
        let audio = try Self.audioChunks(second.sent)
        #expect(Array(audio.dropFirst(flushed)) == Array(allChunks[pushed...]))
        #expect(!second.closed)
        #expect(hub.opened == 2)
        control.close()
        await second.waitClosed()
    }

    /// The first connection stalls and resumes onto a second connection; after the second is Ready the first replayed chunk hangs (upstream stalls again). Returns the second connection and all frames.
    private static func stallDuringFlush(
        _ control: GeminiLiveSessionControl,
        _ events: inout AsyncThrowingStream<RealtimeSessionEvent, Error>.AsyncIterator,
        _ sockets: inout AsyncStream<FakeGeminiSocket>.AsyncIterator
    ) async throws -> (socket: FakeGeminiSocket, frames: [Data], chunks: [String]) {
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        first.stallSends(from: first.sent.count)
        let (frames, chunks) = Self.uplinkFrames(160)
        frames[..<100].forEach(control.sendAudio)
        await first.waitClosed()
        await control.drainUplink()

        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        second.stallSends(from: 1)
        second.push(Self.setupComplete)
        await second.waitStalled(1)
        return (second, frames, chunks)
    }

    /// The newest segment within the buffer cap (same basis as the transport's head truncation).
    private static func newestWithinLimit(_ chunks: ArraySlice<String>) -> [String] {
        var kept: [String] = []
        var keptChars = 0
        for chunk in chunks.reversed() {
            guard keptChars + chunk.count <= GeminiLiveTransport.audioBufferLimit else { break }
            kept.insert(chunk, at: 0)
            keptChars += chunk.count
        }
        return kept
    }

    /// After the resumed connection is Ready and about 5 s are replayed, the upstream stalls again: replay in flight plus subsequent new frames totalling more than 8 s is judged a stall,
    /// the second connection is closed and resumed again with the handle, and the third connection replays the newest ~5 s and then continues normally.
    @Test func stalled_flush_drops_and_resumes() async throws {
        let hub = FakeSocketHub()
        let control = GeminiLiveSessionControl(transport: hub.transport(config: Self.config))
        var events = control.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let (second, frames, chunks) = try await Self.stallDuringFlush(control, &events, &sockets)

        // Keep pushing 4 s while the replay hangs: replay volume (about 5.1 s) + 4 s > 8 s
        frames[100..<140].forEach(control.sendAudio)
        await second.waitClosed()
        await control.drainUplink()
        #expect(try Self.audioChunks(second.sent).isEmpty)
        // No serverContent between the two connections: the second resume backs off 1 s
        var sleeps = hub.sleeps.makeAsyncIterator()
        #expect(await sleeps.next() == 1000)
        hub.releaseSleep()

        let third = try #require(await sockets.next())
        #expect(try Self.handle(of: await third.frame(0)) == "h1")
        #expect(third.sent.count == 1)
        third.push(Self.setupComplete)
        third.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        #expect(try Self.audioChunks(third.sent) == Self.newestWithinLimit(chunks[..<140]))

        control.sendAudio(frames[140])
        await control.drainUplink()
        #expect(try Self.audioChunks(third.sent).last == chunks[140])
        #expect(!third.closed)
        #expect(hub.opened == 3)
        control.close()
        await third.waitClosed()
    }

    /// When a stall is declared the old connection is torn down forcibly: server messages already received on it but not yet processed are no longer delivered into the session stream.
    @Test func stall_drop_closes_old_socket_immediately() async throws {
        let hub = FakeSocketHub()
        let control = GeminiLiveSessionControl(transport: hub.transport(config: Self.config))
        var events = control.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let (second, frames, _) = try await Self.stallDuringFlush(control, &events, &sockets)

        // While the replay hangs the old connection receives an answer: the session is still in the replay and has not processed it
        second.push(Self.speak("late"))
        frames[100..<140].forEach(control.sendAudio)
        await second.waitClosed()
        #expect(second.closed)
        // The discarded "late" does not count as serverContent: the reconnect count is not reset, and the second resume backs off 1 s
        var sleeps = hub.sleeps.makeAsyncIterator()
        #expect(await sleeps.next() == 1000)
        hub.releaseSleep()

        let third = try #require(await sockets.next())
        third.push(Self.setupComplete)
        third.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        #expect(hub.opened == 3)
        control.close()
        await third.waitClosed()
    }

    @Test func backlog_below_threshold_keeps_connection() async throws {
        let hub = FakeSocketHub()
        let control = GeminiLiveSessionControl(transport: hub.transport(config: Self.config))
        var events = control.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let socket = try #require(await sockets.next())
        socket.push(Self.setupComplete)
        socket.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // 7 s backlog: not judged a stall; once the upstream recovers the same connection sends everything in order
        socket.stallSends(from: socket.sent.count)
        let (frames, chunks) = Self.uplinkFrames(70)
        frames.forEach(control.sendAudio)
        socket.releaseSends()
        await control.drainUplink()
        #expect(try Self.audioChunks(socket.sent) == chunks)
        #expect(!socket.closed)
        #expect(hub.opened == 1)
        control.close()
        await socket.waitClosed()
    }

    @Test func unexpected_close_with_handle_resumes_with_last_handle() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        first.push(Self.resumable("h2"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        #expect(try await events.next() == .resumable(handle: "h2"))

        // No goAway and not a client close: open a 2nd socket with the last handle, sending only setup (no history)
        first.finishFromServer()
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h2")
        await transport.appendAudio(base64: "AAAA")
        await transport.appendAudio(base64: "BBBB")
        #expect(second.sent.count == 1)

        second.push(Self.setupComplete)
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        let audio = try second.sent.dropFirst().map { frame -> String in
            let input = try #require(try Self.json(frame)["realtimeInput"] as? [String: Any])
            return try #require((input["audio"] as? [String: Any])?["data"] as? String)
        }
        #expect(audio == ["AAAA", "BBBB"])
        #expect(hub.opened == 2)
        await transport.close()
        #expect(try await events.next() == nil)
    }

    @Test func unexpected_close_resume_backs_off_and_ends_with_original_error_after_four_attempts() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // The 1st reconnect does not wait; if it disconnects again before Ready, wait 1 s for the 2nd; once the 2nd reaches Ready the count and backoff reset
        first.finishFromServer()
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        second.finishFromServer()
        #expect(await sleeps.next() == 1_000)
        hub.releaseSleep()
        let third = try #require(await sockets.next())
        third.push(Self.setupComplete)
        third.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))

        // Disconnect again: the waits before the 4 reconnects are 0 / 1 / 2 / 4 s, none reach Ready → end with the first error
        third.finishFromServer()
        var attempts: [FakeGeminiSocket] = []
        for wait in [0, 1_000, 2_000, 4_000] {
            if wait > 0 {
                #expect(await sleeps.next() == wait)
                hub.releaseSleep()
            }
            let socket = try #require(await sockets.next())
            #expect(try Self.handle(of: await socket.frame(0)) == "h1")
            attempts.append(socket)
            socket.finishFromServer()
        }
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .connectionClosed)
        #expect(attempts.count == GeminiLiveTransport.maxRecoveryAttempts)
        #expect(hub.opened == 7)
    }

    // The count is not reset at setupComplete, only on the first serverContent after Ready
    @Test func ready_then_drop_repeatedly_stops_after_four() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // Every resume is dropped by a non-1008 close right after setupComplete: backoff 0 / 1 / 2 / 4 s for 4 attempts in total, and the 5th does not reconnect
        first.finishFromServer()
        for wait in [0, 1_000, 2_000, 4_000] {
            if wait > 0 {
                #expect(await sleeps.next() == wait)
                hub.releaseSleep()
            }
            let socket = try #require(await sockets.next())
            #expect(try Self.handle(of: await socket.frame(0)) == "h1")
            socket.push(Self.setupComplete)
            socket.finishFromServer()
        }
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .connectionClosed)
        #expect(hub.opened == 5)
    }

    @Test func counter_resets_after_server_content() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // The 2nd connection is dropped right after Ready: the count is not reset, the next wait is 1 s
        first.finishFromServer()
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        second.push(Self.setupComplete)
        second.finishFromServer()
        #expect(await sleeps.next() == 1_000)
        hub.releaseSleep()

        // After the 3rd connection receives serverContent once Ready, the count starts from 0: after another drop, 0 / 1 / 2 / 4 s for 4 attempts in total
        let third = try #require(await sockets.next())
        third.push(Self.setupComplete)
        third.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        third.finishFromServer()
        for wait in [0, 1_000, 2_000, 4_000] {
            if wait > 0 {
                #expect(await sleeps.next() == wait)
                hub.releaseSleep()
            }
            let socket = try #require(await sockets.next())
            _ = await socket.frame(0)
            socket.finishFromServer()
        }
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .connectionClosed)
        #expect(hub.opened == 7)
    }

    @Test func resume_rejected_as_expired_session_ends_without_further_backoff() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // After the server closes an idle session the handle resume is rejected (1008 session missing / expired): end immediately with sessionExpired, no further backoff retry.
        first.finishFromServer()
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        second.finishFromServer(closeCode: 1008, reason: "session not found or expired")
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .sessionExpired(reason: "session not found or expired"))
        #expect(hub.opened == 2)
    }

    // MARK: - 1008 after Ready = session expired

    @Test func ready_connection_closed_with_1008_ends_as_session_expired() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // Closed with 1008 after the first connection is Ready: no resume even with a handle
        first.finishFromServer(closeCode: 1008, reason: "session expired")
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .sessionExpired(reason: "session expired"))
        #expect(hub.opened == 1)
        Self.expectNoKey(try #require(closeError))
    }

    // The 1008 close reason is recorded in the error description (truncated to 200 characters, without URL / key)
    @Test func session_expired_description_carries_close_reason() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        #expect(try await events.next() == .ready)

        let lead = "BidiGenerateContent session is already connected to an existing client"
        let reason = lead + " wss://\(Self.config.host)\(Self.config.path)?key=\(Self.config.apiKey) "
            + String(repeating: "x", count: 300)
        first.finishFromServer(closeCode: 1008, reason: reason)
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        let error = try #require(closeError)
        let text = String(describing: error)
        #expect(text.contains(lead))
        #expect(!text.contains("wss://"))
        #expect(!text.contains(Self.config.host))
        #expect(!text.contains(String(repeating: "x", count: 200)))
        #expect(text.count <= 240)
        Self.expectNoKey(error)
    }

    @Test func resumed_connection_closed_with_1008_after_ready_ends_as_session_expired() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        // A non-1008 disconnect still resumes; if the resumed connection is closed with 1008 after Ready → sessionExpired, no 3rd connection
        first.finishFromServer()
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        second.push(Self.setupComplete)
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        second.finishFromServer(closeCode: 1008, reason: "session expired")
        var closeError: (any Error)?
        do { _ = try await events.next() } catch { closeError = error }
        #expect(closeError as? GeminiLiveTransportError == .sessionExpired(reason: "session expired"))
        #expect(hub.opened == 2)
    }

    @Test func client_close_during_backoff_ends_without_reconnecting() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        first.finishFromServer()
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        second.finishFromServer()
        #expect(await sleeps.next() == 1_000)
        // Client closes during the backoff wait: the stream ends normally, and after the wait is released no new connection is opened
        await transport.close()
        #expect(try await events.next() == nil)
        hub.releaseSleep()
        await transport.close()
        #expect(hub.opened == 2)
    }

    private static func audioFrames(_ socket: FakeGeminiSocket) throws -> [String] {
        try socket.sent.compactMap { frame -> String? in
            guard let input = try Self.json(frame)["realtimeInput"] as? [String: Any] else { return nil }
            return (input["audio"] as? [String: Any])?["data"] as? String
        }
    }

    @Test func audio_send_failure_after_ready_resumes_and_replays_failed_chunk() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        await transport.appendAudio(base64: "AAAA")
        #expect(try Self.audioFrames(first) == ["AAAA"])

        // Uplink send failure = unexpected disconnect: the failed frame goes into the buffer, and after reconnecting with the handle it is replayed in order
        first.failSends(from: first.sent.count)
        await transport.appendAudio(base64: "BBBB")
        let second = try #require(await sockets.next())
        #expect(try Self.handle(of: await second.frame(0)) == "h1")
        await transport.appendAudio(base64: "CCCC")
        second.push(Self.setupComplete)
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        #expect(try Self.audioFrames(second) == ["BBBB", "CCCC"])
        #expect(hub.opened == 2)
        await transport.close()

        // No handle: still ends with an error
        let bareHub = FakeSocketHub()
        let bare = bareHub.transport(config: Self.config)
        var bareEvents = bare.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var bareSockets = bareHub.sockets.makeAsyncIterator()
        let only = try #require(await bareSockets.next())
        only.push(Self.setupComplete)
        #expect(try await bareEvents.next() == .ready)
        only.failSends(from: only.sent.count)
        await bare.appendAudio(base64: "AAAA")
        var sendError: (any Error)?
        do { _ = try await bareEvents.next() } catch { sendError = error }
        #expect(sendError as? GeminiLiveTransportError == .connectionClosed)
        #expect(bareHub.opened == 1)
    }

    /// When a send suspends during the Ready replay and the buffer is head-truncated, what is cut is the in-flight chunk itself; later chunks must not be removed by mistake.
    @Test func flush_trim_during_inflight_send_keeps_following_chunks() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        first.push(Self.goAway())
        #expect(try await events.next() == .goAway(timeLeftMs: nil))
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        let big1 = String(repeating: "X", count: 120_000)
        let big2 = String(repeating: "Z", count: 120_000)
        await transport.appendAudio(base64: big1)
        await transport.appendAudio(base64: "YYYY")
        // setup is sent (frame 0), the first replayed audio chunk suspends
        second.stallSends(from: 1)
        second.push(Self.setupComplete)
        while second.stalledCount == 0 { await Task.yield() }
        // While the replay is suspended another large chunk arrives: the buffer exceeds its cap and is head-truncated
        await transport.appendAudio(base64: big2)
        second.releaseSends()
        second.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        #expect(try Self.audioFrames(second) == [big1, "YYYY", big2])
        await transport.close()
    }

    @Test func flush_failure_at_ready_keeps_unsent_chunks_in_order() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input(withHistory: false)).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        var sleeps = hub.sleeps.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        first.finishFromServer()
        let second = try #require(await sockets.next())
        _ = await second.frame(0)
        await transport.appendAudio(base64: "AAAA")
        await transport.appendAudio(base64: "BBBB")
        await transport.appendAudio(base64: "CCCC")
        // Replay at Ready: AAAA goes out, BBBB onward fail → BBBB and CCCC go back into the buffer in their original order
        second.failSends(from: 2)
        second.push(Self.setupComplete)
        // Ready without a serverContent does not reset the count, so the 2nd resume waits 1 s
        #expect(await sleeps.next() == 1_000)
        hub.releaseSleep()
        let third = try #require(await sockets.next())
        #expect(try Self.handle(of: await third.frame(0)) == "h1")
        await transport.appendAudio(base64: "DDDD")
        third.push(Self.setupComplete)
        third.push(Self.speak("ok"))
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "ok", final: false))
        #expect(try Self.audioFrames(second) == ["AAAA"])
        #expect(try Self.audioFrames(third) == ["BBBB", "CCCC", "DDDD"])
        #expect(hub.opened == 3)
        await transport.close()
    }

    @Test func history_send_failure_ends_with_connection_closed() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        _ = await first.frame(0)
        // Only setup can be sent: sending history fails after Ready → end directly with connectionClosed, no resume
        first.failSends(from: 1)
        first.push(Self.setupComplete)
        #expect(try await events.next() == .ready)
        var historyError: (any Error)?
        do { _ = try await events.next() } catch { historyError = error }
        #expect(historyError as? GeminiLiveTransportError == .connectionClosed)
        #expect(first.closed)
        #expect(hub.opened == 1)
    }

    @Test func client_close_with_handle_does_not_resume() async throws {
        let hub = FakeSocketHub()
        let transport = hub.transport(config: Self.config)
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        var sockets = hub.sockets.makeAsyncIterator()
        let first = try #require(await sockets.next())
        first.push(Self.setupComplete)
        first.push(Self.resumable("h1"))
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))

        await transport.close()
        #expect(try await events.next() == nil)
        #expect(first.closed)
        #expect(hub.opened == 1)
    }

    private static func expectNoKey(_ error: any Error) {
        let texts = [String(describing: error), String(reflecting: error), error.localizedDescription,
                     "\((error as NSError).userInfo)"]
        for text in texts {
            #expect(!text.contains(config.apiKey))
            #expect(!text.contains("k%2By"))
            #expect(!text.contains("key="))
        }
    }
}

// MARK: - Fake socket

/// Replay fake socket: the test pushes server messages and receive yields them in order; log records the relative order of send / recv.
private nonisolated final class FakeGeminiSocket: GeminiLiveSocket, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var inbox: [String] = []
    private var ended = false
    private var waiter: CheckedContinuation<String?, Never>?
    private var _sent: [String] = []
    private var _log: [String] = []
    private var _closed = false
    private var frameWaiters: [(Int, CheckedContinuation<String, Never>)] = []

    init(url: URL) { self.url = url }

    var sent: [String] { lock.withLock { _sent } }
    var log: [String] { lock.withLock { _log } }
    var closed: Bool { lock.withLock { _closed } }

    /// Returns once the frame at `index` has been sent (the transport gets the socket first and then sends setup).
    func frame(_ index: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let ready: String? = lock.withLock {
                if _sent.count > index { return _sent[index] }
                frameWaiters.append((index, continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func push(_ text: String) { deliver(text) }
    func finishFromServer() { deliver(nil) }
    /// The server closes with a close code: receive throws a close error of the same shape as the production socket.
    func finishFromServer(closeCode: Int, reason: String?) {
        lock.withLock { closeError = GeminiLiveSocketClosed(code: closeCode, reason: reason) }
        deliver(nil)
    }
    private var closeError: GeminiLiveSocketClosed?

    private func deliver(_ text: String?) {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            guard !ended else { return nil }
            if text == nil { ended = true }
            if let waiter {
                self.waiter = nil
                if let text { _log.append("recv:\(text)") }
                return waiter
            }
            if let text { inbox.append(text) }
            return nil
        }
        resume?.resume(returning: text)
    }

    /// From the point where the sent-frame count reaches count, every later send throws (simulates an uplink send failure).
    func failSends(from count: Int) { lock.withLock { failFrom = count } }
    private var failFrom: Int?

    /// From the point where the sent-frame count reaches count, send suspends and never returns: releaseSends() lets them go out as usual, close() makes them throw (simulates a stuck upstream TCP connection).
    func stallSends(from count: Int) { lock.withLock { stallFrom = count } }
    func releaseSends() {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            stallFrom = nil
            defer { stalledSends = [] }
            return stalledSends
        }
        waiters.forEach { $0.resume(returning: true) }
    }
    private var stallFrom: Int?
    private var stalledSends: [CheckedContinuation<Bool, Never>] = []
    var stalledCount: Int { lock.withLock { stalledSends.count } }
    private var stallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Returns once at least count sends are suspended (or the socket is closed).
    func waitStalled(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if stalledSends.count >= count || _closed { return true }
                stallWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func dueStallWaiters() -> [CheckedContinuation<Void, Never>] {
        let due = stallWaiters.filter { stalledSends.count >= $0.0 || _closed }.map(\.1)
        stallWaiters.removeAll { stalledSends.count >= $0.0 || _closed }
        return due
    }

    func send(_ text: String) async throws {
        let failing: Bool = lock.withLock { failFrom.map { _sent.count >= $0 } ?? false }
        if failing { throw URLError(.networkConnectionLost) }
        let released = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (immediate, woken): (Bool?, [CheckedContinuation<Void, Never>]) = lock.withLock {
                guard let stallFrom, _sent.count >= stallFrom else { return (true, []) }
                if _closed { return (false, []) }
                stalledSends.append(continuation)
                return (nil, dueStallWaiters())
            }
            woken.forEach { $0.resume() }
            if let immediate { continuation.resume(returning: immediate) }
        }
        if !released { throw URLError(.cancelled) }
        let due: [(CheckedContinuation<String, Never>, String)] = lock.withLock {
            _sent.append(text)
            _log.append("send:\(text)")
            let sent = _sent
            let due = frameWaiters.filter { $0.0 < sent.count }.map { ($0.1, sent[$0.0]) }
            frameWaiters.removeAll { $0.0 < sent.count }
            return due
        }
        due.forEach { $0.0.resume(returning: $0.1) }
    }

    func receive() async throws -> String? {
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let immediate: String?? = lock.withLock {
                if !inbox.isEmpty {
                    let text = inbox.removeFirst()
                    _log.append("recv:\(text)")
                    return .some(text)
                }
                if ended { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
        if text == nil, let error = lock.withLock({ closeError }) { throw error }
        return text
    }

    func close() {
        let (waiters, stalled): ([CheckedContinuation<Void, Never>], [CheckedContinuation<Bool, Never>]) = lock.withLock {
            _closed = true
            defer {
                closeWaiters = []
                stalledSends = []
            }
            return (closeWaiters + dueStallWaiters(), stalledSends)
        }
        waiters.forEach { $0.resume() }
        stalled.forEach { $0.resume(returning: false) }
        deliver(nil)
    }

    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if _closed { return true }
                closeWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Collects the sockets and sleep requests the transport creates; sleep waits for releaseSleep() to let it go.
private nonisolated final class FakeSocketHub: @unchecked Sendable {
    let sockets: AsyncStream<FakeGeminiSocket>
    let sleeps: AsyncStream<Int>
    private let socketSink: AsyncStream<FakeGeminiSocket>.Continuation
    private let sleepSink: AsyncStream<Int>.Continuation
    private let gate: AsyncStream<Void>
    private let gateSink: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var _opened = 0
    private let failConnect: Bool

    init(failConnect: Bool = false) {
        self.failConnect = failConnect
        (sockets, socketSink) = AsyncStream<FakeGeminiSocket>.makeStream()
        (sleeps, sleepSink) = AsyncStream<Int>.makeStream()
        (gate, gateSink) = AsyncStream<Void>.makeStream()
    }

    var opened: Int { lock.withLock { _opened } }

    func releaseSleep() { gateSink.yield() }

    func transport(config: GeminiLiveConfig, resumeHandle: String? = nil) -> GeminiLiveTransport {
        GeminiLiveTransport(
            config: config,
            resumeHandle: resumeHandle,
            socketFactory: { [self] url in
                if failConnect {
                    throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
                }
                let socket = FakeGeminiSocket(url: url)
                lock.withLock { _opened += 1 }
                socketSink.yield(socket)
                return socket
            },
            sleep: { [self] ms in
                sleepSink.yield(ms)
                for await _ in gate { return }
            }
        )
    }
}
