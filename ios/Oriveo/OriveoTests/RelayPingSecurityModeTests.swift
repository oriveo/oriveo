import Foundation
import Testing
@testable import Oriveo

private final class RelayPingSecurityFakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [URL] = []

    static func reset() { lock.withLock { urls = [] } }
    static func captured() -> [URL] { lock.withLock { urls } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayPingSecurityFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.urls.append(request.url!) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"id\":\"ok\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The 1-token ping for Anthropic Messages / Gemini generateContent must also carry the connection's security-mode marker:
/// without it `RelayRequestSecurity.prepare` treats the request as remoteHTTPS, and a ping to a local http connection is blocked as plaintext.
@Suite("Relay ping security-mode marker", .serialized)
struct RelayPingSecurityModeTests {
    @Test("Local http connection: messages / gemini 1-token ping is not blocked as plaintext under remoteHTTPS")
    func localHTTPPingCarriesSecurityMode() async throws {
        for transport in [RelayTransport.anthropicMessages, .geminiGenerateContent] {
            RelayPingSecurityFakeServer.reset()
            let requested = RelayRequestedConfig(transport: transport, authMode: RelayAuthMode.none, securityMode: .localHTTP)
            let service = OpenAIService(session: RelayPingSecurityFakeServer.session())
            do {
                _ = try await service.pingRelay(
                    apiKey: "", baseURL: "http://127.0.0.1:11434", modelID: "local-model", relayRequested: requested
                )
            } catch {
                Issue.record("\(transport.rawValue): ping blocked \(error)")
            }
            #expect(RelayPingSecurityFakeServer.captured().count == 1, "\(transport.rawValue)")
            #expect(RelayPingSecurityFakeServer.captured().first?.host == "127.0.0.1", "\(transport.rawValue)")
        }
    }

    @Test("Local http connection: messages / gemini chat request builders do not block plaintext as remoteHTTPS (probe and chat share one builder)")
    func localHTTPChatBuildersCarrySecurityMode() throws {
        let session = RelayPingSecurityFakeServer.session()
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hi", providerKind: .relay,
            providerName: "Relay", modelName: "local-model", state: .delivered
        )
        func requested(_ transport: RelayTransport) -> RelayRequestedConfig {
            RelayRequestedConfig(transport: transport, authMode: RelayAuthMode.none, securityMode: .localHTTP)
        }
        let messages = try AnthropicService(session: session).buildRelayMessagesRequest(
            modelID: "local-model", messages: [message], apiKey: "", baseURL: "http://127.0.0.1:11434",
            stream: true, reasoningMode: .automatic, relayRequested: requested(.anthropicMessages)
        )
        #expect(messages.url?.absoluteString == "http://127.0.0.1:11434/v1/messages")
        let gemini = try GeminiService(session: session).buildRelayGenerateContentRequest(
            modelID: "local-model", messages: [message], apiKey: "", baseURL: "http://127.0.0.1:11434",
            stream: false, reasoningMode: .automatic, supportsImageGen: false,
            relayRequested: requested(.geminiGenerateContent)
        )
        #expect(gemini.url?.absoluteString == "http://127.0.0.1:11434/v1beta/models/local-model:generateContent")
        // Remote connections still block plaintext.
        #expect(throws: (any Error).self) {
            _ = try AnthropicService(session: session).buildRelayMessagesRequest(
                modelID: "m", messages: [message], apiKey: "sk", baseURL: "http://relay.example.com",
                stream: true, reasoningMode: .automatic,
                relayRequested: RelayRequestedConfig(transport: .anthropicMessages, authMode: .xApiKey, securityMode: .remoteHTTPS)
            )
        }
    }
}
