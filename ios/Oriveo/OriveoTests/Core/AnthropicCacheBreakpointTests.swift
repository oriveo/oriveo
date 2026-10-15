import Foundation
import Testing
@testable import Oriveo

/// Anthropic allows at most 4 cache breakpoints per request. With 5 images in the current turn plus
/// images in history, the official route keeps only the top-level `cache_control` and marks no blocks;
/// Relay places exactly one on the last content block of the last user message.
@Suite("Anthropic cache breakpoints", .serialized)
struct AnthropicCacheBreakpointTests {

    @Test("Official Anthropic: 5 images plus a history image yield only the single top-level cache_control")
    func officialKeepsOnlyTopLevelBreakpoint() async throws {
        AnthropicCaptureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicCaptureURLProtocol.self]
        let service = AnthropicService(session: URLSession(configuration: config))

        do {
            for try await _ in service.sendMessageStream(
                apiKey: "sk-test",
                modelID: "claude-sonnet-4-5",
                messages: Self.messagesWithManyImages(),
                reasoningMode: .automatic,
                webSearchEnabled: false,
                requestOptions: Self.visionOptions()
            ) {}
        } catch {
            // Only the outgoing request body matters; how the stub response parses is out of scope here
        }

        let body = try #require(AnthropicCaptureURLProtocol.bodies().first)
        let text = String(decoding: body, as: UTF8.self)
        #expect(Self.occurrences(of: "cache_control", in: text) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // The official route's vision evidence is unavailable in tests, so sendMessageStream turns images into
        // placeholders; encode blocks through the same production buildRequestMessage and confirm none of the
        // 6 image blocks carries a breakpoint.
        let blocksJSON = try AnthropicService.encodedWireMessages(
            Self.messagesWithManyImages(), transport: .anthropicMessages, model: nil
        )
        let blocksText = String(decoding: blocksJSON, as: UTF8.self)
        #expect(Self.occurrences(of: "\"type\":\"image\"", in: blocksText) == 6, "images are actually encoded as blocks")
        #expect(Self.occurrences(of: "cache_control", in: blocksText) == 0)
    }

    @Test("Relay Anthropic: 5 images plus a history image put the only breakpoint on the last block of the last user")
    func relayKeepsSingleBreakpointOnLastUserBlock() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: Self.messagesWithManyImages(),
            apiKey: "sk-test",
            baseURL: "https://relay.example.com",
            stream: true,
            reasoningMode: .automatic,
            requestOptions: Self.visionOptions(),
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages),
            keepImageAttachments: true
        )
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(Self.occurrences(of: "cache_control", in: text) == 1)

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cache_control"] == nil)
        #expect(Self.imageBlockCount(in: json) >= 5)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let lastUser = try #require(messages.last { $0["role"] as? String == "user" })
        let blocks = try #require(lastUser["content"] as? [[String: Any]])
        #expect((blocks.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("Relay Anthropic: a text-only last user expands into a single text block carrying the only breakpoint")
    func relayTextOnlyLastUserGetsBreakpoint() throws {
        let request = try AnthropicService().buildRelayMessagesRequest(
            modelID: "golden-relay-model",
            messages: [
                TestFactories.makeMessage(role: .user, text: "Hello", providerKind: .anthropic),
                TestFactories.makeMessage(role: .assistant, text: "Hi there.", providerKind: .anthropic),
                TestFactories.makeMessage(role: .user, text: "Summarize.", providerKind: .anthropic),
            ],
            apiKey: "sk-test",
            baseURL: "https://relay.example.com",
            stream: true,
            reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        )
        let body = try #require(request.httpBody)
        #expect(Self.occurrences(of: "cache_control", in: String(decoding: body, as: UTF8.self)) == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "Hello", "only the last user message is touched")
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "text")
        #expect(blocks.first?["text"] as? String == "Summarize.")
        #expect(blocks.first?["cache_control"] != nil)
    }

    // MARK: - Fixtures

    /// Model evidence declaring vision support; without it images become placeholders and never reach the body.
    private static func visionOptions() -> ChatRequestOptions {
        var options = ChatRequestOptions(systemPrompt: "System.")
        options.capabilityEvidenceModel = TestFactories.makeModel(id: "claude-sonnet-4-5", capabilities: [.text, .image])
        return options
    }

    private static func image(_ name: String) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .image,
            fileName: name,
            mimeType: "image/png",
            base64Data: "iVBORw0KGgo="
        )
    }

    private static func messagesWithManyImages() -> [ChatMessage] {
        [
            TestFactories.makeMessage(
                role: .user, text: "Earlier picture", providerKind: .anthropic,
                attachments: [image("history.png")]
            ),
            TestFactories.makeMessage(role: .assistant, text: "Seen.", providerKind: .anthropic),
            TestFactories.makeMessage(
                role: .user, text: "Compare these", providerKind: .anthropic,
                attachments: (1...5).map { image("current-\($0).png") }
            ),
        ]
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func imageBlockCount(in json: [String: Any]) -> Int {
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.reduce(0) { count, message in
            let blocks = message["content"] as? [[String: Any]] ?? []
            return count + blocks.filter { $0["type"] as? String == "image" }.count
        }
    }
}

private final class AnthropicCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []

    static func reset() { lock.withLock { captured = [] } }
    static func bodies() -> [Data] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4_096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = data
        }
        Self.lock.withLock { Self.captured.append(body ?? Data()) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
