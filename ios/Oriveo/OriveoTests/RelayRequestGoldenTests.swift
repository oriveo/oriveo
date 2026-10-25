import Foundation
import Testing
@testable import Oriveo

/// RL2-MIGRATE-01: golden snapshots of existing outbound requests, captured before the choke point is replaced (`shared/test-fixtures/relay/request-golden/`).
///
/// The input list `cases.v1.json` is shared by all three clients; this client's output is `ios.v1.json`. Each case goes through the production Service streaming entry point,
/// capturing the raw method / url / headers / body bytes at the URLProtocol HTTP seam. Relay cases are dispatched through the same production entry point as the ChatManager
/// `.relay` branch, `ProviderServiceRouter` (messages -> AnthropicService, gemini -> GeminiService, everything else -> OpenAIService).
///
/// Record: `TEST_RUNNER_ORIVEO_GOLDEN_RECORD=1 bash scripts/ios-test.sh -only-testing:OriveoTests/RelayRequestGoldenTests`;
/// without that variable each case is compared; a missing file or any differing byte fails.
@Suite("RL2-MIGRATE-01 relay request golden (iOS)", .serialized, .sharedProcessState)
struct RelayRequestGoldenTests {

    // MARK: - Case list

    private struct CaseFile: Decodable {
        struct Turn: Decodable { let role: String; let content: String }
        struct Official: Decodable { let caseId: String; let providerKind: String; let model: String }
        struct Relay: Decodable { let caseId: String; let baseURL: String; let relayRequested: RawJSON }
        let version: Int
        let apiKey: String
        let conversation: [Turn]
        let official: [Official]
        let relay: [Relay]
        let relayModel: String
    }

    /// relayRequested is handed unchanged to the production decoder; fields are not rebuilt in the test.
    private struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(AnyJSON.self)
            data = try JSONSerialization.data(withJSONObject: value.foundation)
        }
    }

    private indirect enum AnyJSON: Decodable {
        case object([String: AnyJSON]), array([AnyJSON]), string(String), number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
            self = .object(try c.decode([String: AnyJSON].self))
        }
        var foundation: Any {
            switch self {
            case .object(let v): return v.mapValues(\.foundation)
            case .array(let v): return v.map(\.foundation)
            case .string(let v): return v
            case .number(let v): return v == v.rounded() ? Int(v) : v
            case .bool(let v): return v
            case .null: return NSNull()
            }
        }
    }

    // MARK: - Output

    struct Record: Codable, Equatable {
        let caseId: String
        var method: String?
        var url: String?
        var headers: [String: String]?
        var body: String?
        var unsupported: String?
    }

    private struct GoldenFile: Codable {
        var comment: String
        var version: Int
        var end: String
        var cases: [Record]
        enum CodingKeys: String, CodingKey {
            case comment = "$comment", version, end, cases
        }
    }

    // MARK: - Paths

    private static func goldenDirectory() throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("relay")
                .appendingPathComponent("request-golden")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("cases.v1.json").path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func loadCases() throws -> CaseFile {
        let url = try goldenDirectory().appendingPathComponent("cases.v1.json")
        return try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: url))
    }

    private static var isRecording: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ORIVEO_GOLDEN_RECORD"] == "1" || env["TEST_RUNNER_ORIVEO_GOLDEN_RECORD"] == "1"
    }

    // MARK: - Input construction (IDs and timestamps are all fixed so values in the body do not drift between runs)

    private static func fixedUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    private static func requestOptions(_ cases: CaseFile) -> ChatRequestOptions {
        var options = ChatRequestOptions()
        // ChatMessage has no system role: production passes the system prompt through requestOptions.systemPrompt.
        options.systemPrompt = cases.conversation.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        return options
    }

    private static func messages(_ cases: CaseFile, providerKind: ProviderKind, modelID: String) -> [ChatMessage] {
        cases.conversation.enumerated().compactMap { index, turn in
            guard let role = ChatRole(rawValue: turn.role) else { return nil }
            return TestFactories.makeMessage(
                id: fixedUUID(index + 1), role: role, text: turn.content,
                providerID: fixedUUID(900), providerKind: providerKind,
                modelID: modelID, modelName: modelID, createdAt: fixedDate.addingTimeInterval(Double(index))
            )
        }
    }

    private static func localProviderKind(_ key: String) -> ProviderKind? {
        switch key {
        case "togetherAI": return .together
        case "fireworksAI": return .fireworks
        default: return ProviderKind(rawValue: key)
        }
    }

    // MARK: - Sending (production Service streaming entry points, with their sessions swapped for an intercepting session)

    private static func officialStream(
        kind: ProviderKind, session: URLSession, apiKey: String, modelID: String,
        messages: [ChatMessage], options: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>? {
        switch kind {
        case .openAI:
            return OpenAIService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .anthropic:
            return AnthropicService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .gemini:
            return GeminiService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .openRouter:
            return OpenRouterService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .groq:
            return GroqService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .deepseek:
            return DeepSeekService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .siliconFlow:
            return SiliconFlowService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .together:
            return TogetherService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .fireworks:
            return FireworksService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .miniMax:
            return MiniMaxService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .zhipu:
            return ZhipuService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .qwen:
            return QwenService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .grok:
            return GrokService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .moonshot:
            return MoonshotService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .mistral:
            return MistralService(session: session).sendMessageStream(apiKey: apiKey, modelID: modelID, messages: messages, requestOptions: options)
        case .relay:
            return nil
        }
    }

    /// The same production entry point (`ProviderServiceRouter`) used by the ChatManager `.relay` non-image, stream != false branch;
    /// all inputs are taken from the provider / model.
    private static func relayStream(
        provider: Provider, model: AIModel, session: URLSession,
        messages: [ChatMessage], options baseOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error>? {
        guard case .byProtocol(let route) = ProviderServiceRouter.route(provider: provider, model: model) else {
            return nil
        }
        let modelID = ModelResolver.resolvedProviderModelIdentifier(model.id, providerKind: provider.kind)
        return ProviderServiceRouter.Services(session: session).protocolStream(
            route, apiKey: provider.apiKey, modelID: modelID, messages: messages,
            reasoningMode: .automatic, webSearchEnabled: false,
            supportsImageGen: model.capabilities.contains(.imageGen), requestOptions: baseOptions
        )
    }

    private static func capture(
        caseId: String, _ make: (URLSession) -> AsyncThrowingStream<StreamEvent, Error>?
    ) async -> Record {
        GoldenCaptureProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoldenCaptureProtocol.self]
        let session = URLSession(configuration: config)
        guard let stream = make(session) else {
            return Record(caseId: caseId, unsupported: "no production stream entry for this case")
        }
        var streamError: Error?
        do { for try await _ in stream {} } catch { streamError = error }
        guard let request = GoldenCaptureProtocol.captured.first else {
            return Record(
                caseId: caseId,
                unsupported: "no request reached the HTTP seam: \(streamError.map { String(describing: $0) } ?? "stream finished without sending")"
            )
        }
        return request.record(caseId: caseId)
    }

    /// Makes the golden environment deterministic, giving the same answer as the Web / Android goldens:
    /// - official_anthropic: the catalog declares promptCache.policyRef = anthropic.explicit for claude-sonnet-4-5, so the official route still places the breakpoint;
    /// - no relayRuntimeConfig: the Codex UA uses the built-in fallback version and does not pick up delivered values other tests loaded into MetadataClient.shared.
    private static func installGoldenMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-19T00:00:00Z",
          "profiles": { "reasoning": {}, "webSearch": {}, "imageGen": {} },
          "providers": {
            "anthropic": {
              "displayName": "Anthropic",
              "defaultModelId": "claude-sonnet-4-5",
              "validationModelId": "claude-sonnet-4-5",
              "resolveMap": { "claude-sonnet-4-5": "claude-sonnet-4-5" },
              "models": {
                "claude-sonnet-4-5": {
                  "canonicalModelId": "claude-sonnet-4-5",
                  "displayName": "Claude Sonnet 4.5",
                  "capabilities": ["text"],
                  "promptCache": { "policyRef": "anthropic.explicit" }
                }
              }
            }
          }
        }
        """, metadataETag: "relay-request-golden-\(UUID().uuidString)")
    }

    private static func recordAll(_ cases: CaseFile) async throws -> (records: [Record], relayWriteBack: [String]) {
        try await installGoldenMetadata()
        let options = requestOptions(cases)
        var records: [Record] = []
        var writeBack: [String] = []

        for item in cases.official {
            guard let kind = localProviderKind(item.providerKind) else {
                records.append(Record(caseId: item.caseId, unsupported: "unknown providerKind \(item.providerKind)"))
                continue
            }
            let msgs = messages(cases, providerKind: kind, modelID: item.model)
            records.append(await capture(caseId: item.caseId) { session in
                officialStream(kind: kind, session: session, apiKey: cases.apiKey, modelID: item.model, messages: msgs, options: options)
            })
        }

        for (index, item) in cases.relay.enumerated() {
            let relayRequested: RelayRequestedConfig
            do {
                relayRequested = try JSONDecoder().decode(RelayRequestedConfig.self, from: item.relayRequested.data)
            } catch {
                records.append(Record(caseId: item.caseId, unsupported: "relayRequested does not decode: \(error)"))
                continue
            }
            // The model has only an id and no relayTransport: the transport can only come from provider.relayRequested.
            let model = TestFactories.makeModel(id: cases.relayModel, capabilities: [.text], isDefault: true)
            var provider = TestFactories.makeProvider(
                id: fixedUUID(1_000 + index), kind: .relay, models: [model],
                lastCheckedAt: fixedDate, apiKey: cases.apiKey, apiKeyPreview: "",
                baseURLText: item.baseURL
            )
            provider.relayRequested = relayRequested
            let providerBefore = provider
            let modelBefore = model
            let msgs = messages(cases, providerKind: .relay, modelID: cases.relayModel)
            records.append(await capture(caseId: item.caseId) { session in
                relayStream(provider: provider, model: model, session: session, messages: msgs, options: options)
            })
            if provider != providerBefore || provider.relayRequested != relayRequested {
                writeBack.append("\(item.caseId): provider.relayRequested changed")
            }
            if model != modelBefore || provider.models != [modelBefore] {
                writeBack.append("\(item.caseId): model changed")
            }
        }
        return (records, writeBack)
    }

    // MARK: - Tests

    @Test("RL2_MIGRATE_01 each case's outbound request is byte-identical to ios.v1.json (record mode writes the file)")
    func RL2_MIGRATE_01_outboundRequestsMatchGolden() async throws {
        let cases = try Self.loadCases()
        #expect(cases.version == 1)
        #expect(cases.official.count == 15)
        #expect(cases.relay.count == 9)
        let (records, _) = try await Self.recordAll(cases)
        #expect(records.count == cases.official.count + cases.relay.count)

        let fileURL = try Self.goldenDirectory().appendingPathComponent("ios.v1.json")
        if Self.isRecording {
            let golden = GoldenFile(
                comment: "RL2-MIGRATE-01 iOS baseline. Generated by OriveoTests/RelayRequestGoldenTests with ORIVEO_GOLDEN_RECORD=1; do not hand-edit. body: object keys sorted (iOS key order follows the per-process random Swift Dictionary seed), every other byte as sent. session_id and the app / OS versions inside user-agent are recorded as fixed placeholders after a shape check.",
                version: 1, end: "ios", cases: records
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(golden)
            data.append(0x0A)
            try data.write(to: fileURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Issue.record("missing \(fileURL.path); record it with TEST_RUNNER_ORIVEO_GOLDEN_RECORD=1")
            return
        }
        let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: fileURL))
        let expected = Dictionary(uniqueKeysWithValues: golden.cases.map { ($0.caseId, $0) })
        #expect(Set(expected.keys) == Set(records.map(\.caseId)), "golden case set drifted from cases.v1.json")
        for actual in records {
            guard let want = expected[actual.caseId] else { continue }
            #expect(actual == want, "\(actual.caseId) differs:\n\(Self.diff(want: want, got: actual))")
        }
    }

    @Test("RL2_MIGRATE_01 after a relay send, provider.relayRequested and the model object are not written back")
    func RL2_MIGRATE_01_relaySendDoesNotWriteBack() async throws {
        let cases = try Self.loadCases()
        let (_, writeBack) = try await Self.recordAll(cases)
        #expect(writeBack.isEmpty, "\(writeBack)")
    }

    private static func diff(want: Record, got: Record) -> String {
        var lines: [String] = []
        if want.unsupported != got.unsupported { lines.append("  unsupported: \(want.unsupported ?? "nil") -> \(got.unsupported ?? "nil")") }
        if want.method != got.method { lines.append("  method: \(want.method ?? "nil") -> \(got.method ?? "nil")") }
        if want.url != got.url { lines.append("  url: \(want.url ?? "nil") -> \(got.url ?? "nil")") }
        let names = Set((want.headers ?? [:]).keys).union((got.headers ?? [:]).keys).sorted()
        for name in names where want.headers?[name] != got.headers?[name] {
            lines.append("  header \(name): \(want.headers?[name] ?? "<absent>") -> \(got.headers?[name] ?? "<absent>")")
        }
        if want.body != got.body {
            lines.append("  body want: \(want.body ?? "nil")")
            lines.append("  body got:  \(got.body ?? "nil")")
        }
        return lines.joined(separator: "\n")
    }
}

/// Captures only the request and replies with a minimal stream that lets each protocol parser finish normally; the request content is not altered by a single byte.
private final class GoldenCaptureProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        let method: String?
        let url: String?
        let headers: [String: String]
        let body: Data?

        func record(caseId: String) -> RelayRequestGoldenTests.Record {
            var lowered: [String: String] = [:]
            for (name, value) in headers { lowered[name.lowercased()] = value }
            // The Codex identity header's session_id is a per-request `UUID().uuidString` in production (the default argument of RelayRuntimeSupport
            // .codexIdentityHeaders) with no injection point: the field is kept, and after validating the value is a UUID it is replaced with a fixed placeholder.
            if let session = lowered["session_id"] {
                lowered["session_id"] = UUID(uuidString: session) != nil ? "<per-request UUID>" : "<not a UUID: \(session)>"
            }
            if let agent = lowered["user-agent"] {
                lowered["user-agent"] = Self.stableUserAgent(agent)
            }
            return RelayRequestGoldenTests.Record(
                caseId: caseId, method: method, url: url, headers: lowered,
                body: body.map(Self.stableBody) ?? ""
            )
        }

        /// The app version and OS version in the UA change with releases / simulator runtimes: they are replaced with a placeholder only when the shape matches; otherwise the original stays so the comparison fails.
        /// The codex_cli_rs version is a production constant and is not replaced.
        private static func stableUserAgent(_ agent: String) -> String {
            let rules: [(pattern: String, template: String)] = [
                (#"^Oriveo/\d+(?:\.\d+)* \(iOS \d+(?:\.\d+)*\)$"#, "Oriveo/<app-version> (iOS <os-version>)"),
                (#"^(codex_cli_rs/[^ ]+) \(iOS \d+(?:\.\d+)*; ([^)]+)\)$"#, "$1 (iOS <os-version>; $2)"),
            ]
            let range = NSRange(agent.startIndex..., in: agent)
            for rule in rules {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern),
                      regex.firstMatch(in: agent, range: range) != nil else { continue }
                return regex.stringByReplacingMatches(in: agent, range: range, withTemplate: rule.template)
            }
            return agent
        }

        /// The production body is encoded by `JSONSerialization.data(withJSONObject: [String: Any])`, so object key order follows
        /// the per-process random hash seed of Swift Dictionary, and key order differs on every run for the same request. Here only object keys are sorted,
        /// using the same JSONSerialization writer, so escaping, number formatting and all other bytes match what was sent.
        private static func stableBody(_ data: Data) -> String {
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
                  sorted.count == data.count else {
                return String(decoding: data, as: UTF8.self)
            }
            return String(decoding: sorted, as: UTF8.self)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [Captured] = []

    static var captured: [Captured] { lock.withLock { storage } }
    static func reset() { lock.withLock { storage = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        let item = Captured(
            method: request.httpMethod, url: request.url?.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:], body: body
        )
        Self.lock.withLock { Self.storage.append(item) }
        let url = request.url?.absoluteString ?? ""
        let payload: String
        if url.contains("generateContent") {
            payload = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        } else if url.contains("/messages") {
            payload = """
            event: content_block_start
            data: {"index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"index":0,"delta":{"type":"text_delta","text":"ok"}}

            event: message_stop
            data: {}


            """
        } else if url.contains("/responses") {
            payload = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"ok"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_golden","status":"completed"}}

            data: [DONE]


            """
        } else {
            payload = """
            data: {"choices":[{"delta":{"content":"ok"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

            data: [DONE]


            """
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }
}
