import Foundation
import GRDB
import OriveoProviderKit
import Testing

@testable import Oriveo

// MARK: - Regression tests for the tool-capability review fixes

private func fixtureURL(_ name: String) throws -> URL {
    var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while cursor.path != "/" {
        let candidate = ["shared", "test-fixtures", "provider-toolcall", name].reduce(cursor) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        cursor.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

/// Replays one fixed response for every request.
private final class FixedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    static func reset(_ text: String) { body = Data(text.utf8) }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixedResponseURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct UnsupportedContract: Decodable {
    struct Case: Decodable {
        let id: String
        let status: Int
        let body: String
        let expect: Bool
    }
    let cases: [Case]
}

/// A standalone GRDB database (runs the full migrator) that leaves the DatabaseManager's current user pool alone.
private func makeMemoryStore() throws -> ToolCallMemoryStore {
    let uid = "toolcall-memory-fixup-\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
    let pool = try DatabasePool(
        path: AppSessionStore.databasePath(for: uid).path,
        configuration: DatabaseSchema.makeConfiguration()
    )
    let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
    try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
    return ToolCallMemoryStore(poolProvider: { pool })
}

private func userMessage(kind: ProviderKind) -> ChatMessage {
    ChatMessage(id: UUID(), role: .user, text: "the weather in Melbourne today", providerKind: kind, providerName: kind.displayName, modelName: "m", state: .delivered)
}

@Suite("Tool-capability review fixes", .serialized, .sharedProcessState)
struct R3FixupTests {
    @Test("Every contract case goes through mapHTTPError + annotate and then matches(_ error:), and the verdict agrees with expect (including a 422 detail[].msg)")
    @MainActor
    func contractCasesThroughProductionMapping() throws {
        let contract = try JSONDecoder().decode(UnsupportedContract.self, from: Data(contentsOf: fixtureURL("tool-unsupported-4xx.json")))
        #expect(contract.cases.count >= 10)
        let base = BaseAPIService(session: FixedResponseURLProtocol.session())
        var sawDetailShape = false
        for item in contract.cases {
            let data = Data(item.body.utf8)
            let mapped = base.mapHTTPError(
                statusCode: item.status, data: data,
                url: URL(string: "https://relay.test/v1/chat/completions"), isRelay: true
            )
            let annotated = ToolUnsupportedErrorMatcher.annotate(mapped, statusCode: item.status, rawBody: data)
            #expect(ToolUnsupportedErrorMatcher.matches(annotated) == item.expect, "case \(item.id) is judged differently from the contract after the production mapping")
            if item.expect, annotated is ToolsRejectedByUpstreamError {
                // A bare mapped detail cannot see shapes like detail[].msg; that is the gap this closes.
                if !ToolUnsupportedErrorMatcher.matches(mapped) { sawDetailShape = true }
            }
        }
        #expect(sawDetailShape, "at least one case only matches when the raw body is read (otherwise the test misses the point)")
        // A non-tools rejection: annotate returns the mapped error unchanged, so the presentation layer is unaffected
        let plain = base.mapHTTPError(statusCode: 400, data: Data(#"{"error":{"message":"Invalid model id"}}"#.utf8))
        #expect(ToolUnsupportedErrorMatcher.annotate(plain, statusCode: 400, rawBody: Data(#"{"error":{"message":"Invalid model id"}}"#.utf8)) is ProviderServiceError)
        #expect(makeProviderError(ToolsRejectedByUpstreamError(statusCode: 400, underlying: .upstream(statusCode: 400, detail: "x"))).detail.contains("x"))
    }

    @Test("Memory lookup goes through the in-process cache, record / clear invalidate it; observedAt is stored as TEXT and round-trips")
    func memoryCacheAndObservedAtRoundtrip() throws {
        let store = try makeMemoryStore()
        let connection = UUID()
        #expect(store.lookup(connectionID: connection, modelID: "m") == nil)
        let observed = Date(timeIntervalSince1970: 1_787_457_600)
        #expect(store.record(connectionID: connection, modelID: "m", toolCall: false, reason: .toolsRejected4xx, now: observed))
        let remembered = try #require(store.lookup(connectionID: connection, modelID: "m"))
        #expect(remembered.toolCall == false)
        #expect(abs(remembered.observedAt.timeIntervalSince(observed)) < 0.001)
        // Read the database directly, bypassing the cache: the column holds GRDB's Date TEXT encoding, not a REAL
        let fresh = ToolCallMemoryStore(poolProvider: store.poolProviderForTesting)
        let direct = try #require(fresh.lookup(connectionID: connection, modelID: "m"))
        #expect(abs(direct.observedAt.timeIntervalSince(observed)) < 0.001)
        store.clear(connectionID: connection)
        #expect(store.lookup(connectionID: connection, modelID: "m") == nil)
        #expect(fresh.lookup(connectionID: connection, modelID: "m") != nil, "another instance's cache is unaffected (each instance invalidates its own); production only has the one .shared")
    }

    @Test("The seven private non-streaming sendMessage paths do not throw emptyResponse for an empty body plus tool_calls", arguments: [
        "groq", "together", "fireworks", "siliconflow", "qwen", "minimax", "mistral",
    ])
    @MainActor
    func privateNonStreamingToolCallsSurvive(provider: String) async throws {
        await MetadataClient.shared.resetForTesting()
        FixedResponseURLProtocol.reset(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_ns","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Melbourne\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)
        let session = FixedResponseURLProtocol.session()
        let result: ProviderChatResult
        switch provider {
        case "groq": result = try await GroqService(session: session).sendMessage(apiKey: "k", modelID: "llama", messages: [userMessage(kind: .groq)])
        case "together": result = try await TogetherService(session: session).sendMessage(apiKey: "k", modelID: "llama", messages: [userMessage(kind: .together)])
        case "fireworks": result = try await FireworksService(session: session).sendMessage(apiKey: "k", modelID: "llama", messages: [userMessage(kind: .fireworks)])
        case "siliconflow": result = try await SiliconFlowService(session: session).sendMessage(apiKey: "k", modelID: "qwen", messages: [userMessage(kind: .siliconFlow)])
        case "qwen": result = try await QwenService(session: session).sendMessage(apiKey: "k", modelID: "qwen-plus", messages: [userMessage(kind: .qwen)])
        case "minimax": result = try await MiniMaxService(session: session).sendMessage(apiKey: "k", modelID: "MiniMax-M2", messages: [userMessage(kind: .miniMax)])
        default: result = try await MistralService(session: session).sendMessage(apiKey: "k", modelID: "mistral-large", messages: [userMessage(kind: .mistral)])
        }
        #expect(result.text.isEmpty, Comment(rawValue: provider))
        #expect(result.toolCalls?.map(\.name) == ["get_weather"], Comment(rawValue: provider))
        #expect(result.toolCalls?.first?.providerCallID == "call_ns", Comment(rawValue: provider))
    }
}
