import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Answers chat/completions with a fixed reply and records each request. Installed on the injected provider
/// session only, the way the smoke harness installs `SmokeURLProtocol`.
private final class MemoryLiveSendProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var reply: String = ""

    override static func canInit(with request: URLRequest) -> Bool { true }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryLiveSendProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let completion: [String: Any] = [
            "id": "chatcmpl-memory", "object": "chat.completion", "model": "memory-model",
            "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": Self.reply]]],
        ]
        let body = try! JSONSerialization.data(withJSONObject: completion)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Memory live send session", .serialized)
@MainActor
struct MemoryLiveSendSessionTests {
    private static let model = AIModel(
        id: "memory-model", name: "memory-model", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
    )

    private static let relay = Provider(
        id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [model],
        apiKey: "sk-memory-fake", apiKeyPreview: APIKeyMask.masked("sk-memory-fake"),
        baseURLText: "https://memory-relay.test/v1",
        relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
    )

    /// App state whose provider session is the stub session.
    private func makeState(reply: String) -> AppState {
        MemoryLiveSendProtocol.requests = []
        MemoryLiveSendProtocol.reply = reply
        let state = AppState(seedDemoData: true, providerSession: MemoryLiveSendProtocol.session())
        state.providers = [Self.relay]
        return state
    }

    @Test("Relay https endpoint: organize is sent on the app provider session and parsed")
    func organizerUsesInjectedSession() async {
        let state = makeState(reply: #"[{"kind":"identity","content":"I write historical novels"}]"#)
        let organizer = MemoryOrganizer(candidates: [(Self.relay, Self.model)], session: state.providerSession)
        let outcome = await organizer.organize(content: "I write historical novels\nPrefer short replies")
        #expect(MemoryLiveSendProtocol.requests.count == 1)
        #expect(MemoryLiveSendProtocol.requests.first?.url?.absoluteString == "https://memory-relay.test/v1/chat/completions")
        guard case let .entries(entries) = outcome else {
            Issue.record("expected entries, got \(outcome)")
            return
        }
        #expect(entries.map(\.content) == ["I write historical novels"])
    }

    @Test("Relay https endpoint: confirmed memory draft is sent on the app provider session")
    func extractionUsesInjectedSession() async {
        let state = makeState(reply: "I am a novelist.")
        let flow = MemoryExtractionFlow()
        let message = TestFactories.makeMessage(role: .user, text: "I write novels", providerID: Self.relay.id)
        let conversation = TestFactories.makeConversation(messages: [message], updatedAt: Date(timeIntervalSince1970: 1))
        #expect(flow.prepareDraft(conversations: [conversation], candidates: [(Self.relay, Self.model)]) == .awaitingConfirmation)
        let outcome = await flow.confirm(session: state.providerSession)
        #expect(MemoryLiveSendProtocol.requests.count == 1)
        #expect(MemoryLiveSendProtocol.requests.first?.url?.absoluteString == "https://memory-relay.test/v1/chat/completions")
        #expect(outcome == .draft("I am a novelist."))
    }
}
