import Foundation
import Network
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The real URLSessionGeminiLiveSocket against a local WebSocket server: after an unexpected disconnect, reconnecting with the resume handle must actually open a connection and receive setupComplete.
@Suite("GeminiLiveSocketReconnect", .timeLimit(.minutes(1)))
struct GeminiLiveSocketReconnectTests {

    private static let config = GeminiLiveConfig(
        host: "generativelanguage.googleapis.com",
        path: "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        model: "gemini-3.8-live",
        voice: "Kore",
        apiKey: "k+y/="
    )

    private static let setupComplete = #"{"setupComplete":{}}"#
    private static func resumable(_ handle: String) -> String {
        #"{"sessionResumptionUpdate":{"resumable":true,"newHandle":"\#(handle)"}}"#
    }
    private static func speak(_ text: String) -> String {
        #"{"serverContent":{"outputTranscription":{"text":"\#(text)"}}}"#
    }

    /// Builds the input through the production plan projection: session instructions "Be brief.", no history.
    private static func input() throws -> RealtimeTransportInput {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."
            ),
            messages: [],
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

    private static func handle(of frame: String) throws -> String? {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let setup = try #require(object["setup"] as? [String: Any])
        return (setup["sessionResumption"] as? [String: Any])?["handle"] as? String
    }

    /// Points the production wss address at the local server (keeping the path and ?key=).
    private static func local(_ url: URL, port: UInt16) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = Int(port)
        return components.url!
    }

    @Test func unexpected_drop_reconnects_over_real_socket() async throws {
        let server = try LocalGeminiLiveServer(scripts: [
            .init(replies: [Self.setupComplete, Self.resumable("h1")], dropAfterReplies: true),
            .init(replies: [Self.setupComplete, Self.speak("Back")], dropAfterReplies: false),
        ])
        let port = try await server.start()
        defer { server.stop() }

        let transport = GeminiLiveTransport(
            config: Self.config,
            socketFactory: { URLSessionGeminiLiveSocket(url: Self.local($0, port: port)) }
        )
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        #expect(try await events.next() == .ready)
        #expect(try await events.next() == .resumable(handle: "h1"))
        // After the server drops the first connection, the transport reconnects over the real socket; the second connection replies setupComplete and the event stream continues
        #expect(try await events.next() == .assistantTranscript(itemId: nil, text: "Back", final: false))

        let setups = await server.recorder.setups()
        #expect(setups.count == 2)
        #expect(try Self.handle(of: try #require(setups.first)) == nil)
        #expect(try Self.handle(of: try #require(setups.last)) == "h1")
        await transport.close()
    }

    @Test func idle_connection_sends_no_websocket_ping() async throws {
        let server = try LocalGeminiLiveServer(scripts: [
            .init(replies: [Self.setupComplete], dropAfterReplies: false),
        ])
        let port = try await server.start()
        defer { server.stop() }

        // The disconnect root cause is the server ending an idle session (1008), which ping cannot fix: the production socket no longer sends periodic pings
        let transport = GeminiLiveTransport(
            config: Self.config,
            socketFactory: { URLSessionGeminiLiveSocket(url: Self.local($0, port: port)) }
        )
        var events = transport.openRealtimeSession(transport: try Self.input()).makeAsyncIterator()
        #expect(try await events.next() == .ready)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await server.recorder.pings() == 0)
        #expect(await server.recorder.setups().count == 1)
        await transport.close()
    }
}

/// Local ws server: after the Nth connection receives its first (setup) frame it replies with the Nth script's frames, and can drop the connection on demand.
private final class LocalGeminiLiveServer: @unchecked Sendable {
    struct Script: Sendable {
        let replies: [String]
        let dropAfterReplies: Bool
    }

    actor Recorder {
        private var frames: [String] = []
        private var connections = 0
        func nextIndex() -> Int {
            defer { connections += 1 }
            return connections
        }
        private var pingCount = 0
        func record(_ frame: String) { frames.append(frame) }
        func setups() -> [String] { frames }
        func recordPing() { pingCount += 1 }
        func pings() -> Int { pingCount }
    }

    let recorder = Recorder()
    private let scripts: [Script]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oriveo.gemini-live-reconnect-test")

    init(scripts: [Script]) throws {
        self.scripts = scripts
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            Task { await self.serve(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) async {
        let index = await recorder.nextIndex()
        guard index < scripts.count, let setup = await receiveText(connection) else {
            connection.cancel()
            return
        }
        await recorder.record(setup)
        let script = scripts[index]
        for reply in script.replies {
            await Self.sendText(reply, on: connection)
        }
        if script.dropAfterReplies {
            connection.forceCancel()
        } else {
            // Keep the connection open: keep reading until the peer closes
            while await receiveText(connection) != nil {}
        }
    }

    /// Next text frame; control frames such as ping are recorded in the recorder and skipped.
    private func receiveText(_ connection: NWConnection) async -> String? {
        while true {
            let received: (NWProtocolWebSocket.Opcode?, Data)? = await withCheckedContinuation { continuation in
                connection.receiveMessage { data, context, _, error in
                    guard error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    continuation.resume(returning: (metadata?.opcode, data ?? Data()))
                }
            }
            guard let (opcode, data) = received else { return nil }
            switch opcode {
            case .ping:
                await recorder.recordPing()
            case .close:
                return nil
            case .pong, .cont:
                continue
            default:
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    private static func sendText(_ text: String, on connection: NWConnection) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }
}
