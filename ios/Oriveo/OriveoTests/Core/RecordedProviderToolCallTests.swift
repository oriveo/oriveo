import Foundation
import OriveoProviderKit
import Testing

@testable import Oriveo


private enum RecordedToolCallFixtures {
    static let directory = ["shared", "test-fixtures", "provider-toolcall", "recorded"]

    struct ExpectedToolCall: Decodable {
        let id: String?
        let name: String
        let arguments: String
    }

    struct Expected: Decodable {
        let text: String
        let finishReason: String?
        let toolCalls: [ExpectedToolCall]
        let toolCallEvents: Int

        enum CodingKeys: String, CodingKey {
            case text
            case finishReason = "finish_reason"
            case toolCalls = "tool_calls"
            case toolCallEvents = "tool_call_events"
        }
    }

    struct Entry: Decodable {
        let file: String
        let transport: String
        let provider: String
        let model: String
        let expected: Expected
    }

    struct Manifest: Decodable {
        let fixtures: [Entry]
    }

    static func url(_ name: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = (directory + [name]).reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data("expected.json"))
    }

    static func entry(_ provider: String) throws -> Entry {
        try #require(try manifest().fixtures.first { $0.provider == provider })
    }

    static func normalizedJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return raw }
        return String(decoding: canonical, as: UTF8.self)
    }
}

private final class RecordedFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var captured: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(serving fixture: String) throws -> URLSession {
        body = try RecordedToolCallFixtures.data(fixture)
        captured = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordedFixtureURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct Collected {
    var text = ""
    var toolCallEvents: [[ProviderToolCall]] = []
    var done: ProviderChatResult?
    var toolCalls: [ProviderToolCall] { toolCallEvents.flatMap { $0 } }
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> Collected {
    var out = Collected()
    for try await event in stream {
        switch event {
        case let .delta(chunk): out.text += chunk
        case let .toolCallDeltas(calls): out.toolCallEvents.append(calls)
        case let .done(result): out.done = result
        case .reasoning, .citations, .imagePart: break
        }
    }
    return out
}

private func user(_ kind: ProviderKind) -> ChatMessage {
    ChatMessage(
        id: UUID(), role: .user, text: "Please call get_weather for Melbourne weather, do not make it up",
        providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered
    )
}

private func responsesSnapshot(providerKey: String, baseURL: String, modelID: String) -> String {
    """
    {
      "version": 1,
      "updatedAt": "2026-08-22T00:00:00Z",
      "providers": {
        "\(providerKey)": {
          "transport": {
            "baseUrl": "\(baseURL)",
            "endpoints": { "chat": "/v1/chat/completions", "responses": "/v1/responses" }
          },
          "resolveMap": { "\(modelID)": "\(modelID)" },
          "models": {
            "\(modelID)": {
              "canonicalModelId": "\(modelID)",
              "capabilities": ["text"],
              "transport": "openai_responses",
              "toolCall": true
            }
          }
        }
      }
    }
    """
}


@Suite("Recorded Provider Tool Call Tests", .serialized)
struct RecordedProviderToolCallTests {
    static let providers = [
        "groq", "together", "fireworks", "qwen", "zhipu", "siliconflow", "deepseek",
        "moonshot", "moonshot_web_search", "anthropic", "gemini", "grok", "openai",
    ]

    @Test("Manifest Covers All Recordings")
    func manifestCoversAllRecordings() throws {
        let manifest = try RecordedToolCallFixtures.manifest()
        #expect(manifest.fixtures.map(\.provider) == Self.providers)
        for entry in manifest.fixtures {
            #expect(FileManager.default.fileExists(atPath: try RecordedToolCallFixtures.url(entry.file).path), Comment(rawValue: entry.file))
            #expect(entry.expected.toolCalls.count == 1, Comment(rawValue: entry.provider))
        }
    }

    @MainActor
    private static func productionStream(provider: String, modelID: String, session: URLSession) -> AsyncThrowingStream<StreamEvent, Error> {
        switch provider {
        case "groq":
            return GroqService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.groq)])
        case "together":
            return TogetherService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.together)])
        case "fireworks":
            return FireworksService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.fireworks)])
        case "qwen":
            return QwenService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.qwen)])
        case "zhipu":
            return ZhipuService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.zhipu)])
        case "siliconflow":
            return SiliconFlowService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.siliconFlow)])
        case "deepseek":
            return DeepSeekService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.deepseek)])
        case "moonshot", "moonshot_web_search":
            return MoonshotService(session: session).sendMessageStream(apiKey: "k", modelID: modelID, messages: [user(.moonshot)])
        case "anthropic":
            return AnthropicService(session: session).sendMessageStream(apiKey: "sk-ant-k", modelID: modelID, messages: [user(.anthropic)])
        case "gemini":
            return GeminiService(session: session).sendMessageStream(apiKey: "AIza-k", modelID: modelID, messages: [user(.gemini)])
        case "grok":
            return GrokService(session: session).sendMessageStream(apiKey: "xai-k", modelID: modelID, messages: [user(.grok)])
        case "openai":
            return OpenAIService(session: session).sendMessageStream(apiKey: "sk-k", modelID: modelID, messages: [user(.openAI)])
        default:
            preconditionFailure("unknown provider \(provider)")
        }
    }

    @Test("Real-network leg 1 SSE → production Service → .toolCallDeltas (name / id / arguments match the recorded assembly, single event, .done does not throw)", arguments: providers)
    @MainActor
    func productionDecoderEmitsRecordedToolCall(provider: String) async throws {
        await MetadataClient.shared.resetForTesting()
        let entry = try RecordedToolCallFixtures.entry(provider)
        switch provider {
        case "grok":
            try await MetadataClient.shared.loadForTesting(json: responsesSnapshot(providerKey: "grok", baseURL: "https://api.x.ai", modelID: entry.model))
        case "openai":
            try await MetadataClient.shared.loadForTesting(json: responsesSnapshot(providerKey: "openAI", baseURL: "https://api.openai.com", modelID: entry.model))
        default:
            break
        }
        let session = try RecordedFixtureURLProtocol.session(serving: entry.file)
        let collected = try await collect(Self.productionStream(provider: provider, modelID: entry.model, session: session))

        if entry.transport == "openai_responses" {
            #expect(RecordedFixtureURLProtocol.captured.first?.url?.path.hasSuffix("/responses") == true)
        }
        #expect(collected.text == entry.expected.text)
        #expect(collected.toolCallEvents.count == entry.expected.toolCallEvents)
        let calls = collected.toolCalls
        #expect(calls.count == entry.expected.toolCalls.count, Comment(rawValue: provider))
        for (got, want) in zip(calls, entry.expected.toolCalls) {
            #expect(got.name == want.name, Comment(rawValue: provider))
            #expect(got.providerCallID == want.id)
            #expect(
                RecordedToolCallFixtures.normalizedJSON(got.rawArguments) == RecordedToolCallFixtures.normalizedJSON(want.arguments),
                "\(provider): arguments were not fully assembled or were rewritten: \(got.rawArguments)"
            )
        }
        #expect(collected.done != nil)
        await MetadataClient.shared.resetForTesting()
    }
}
