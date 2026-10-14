import Foundation
import Testing

@testable import Oriveo

// Shared fixture `shared/test-fixtures/provider-toolcall/gemini_interactions.selection.v1.json` (read-only):
// when the server judges a model's transport to be gemini_interactions, which requests go through Interactions and which recipe they carry.
// Each case has a test of the same name that goes through the production dispatch entry `GeminiService.sendMessageStream` and asserts the captured outbound request.

private final class SelectionCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [(url: URL?, body: Data)] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { requests = [] } }
    static func first() -> (url: URL?, body: Data)? { lock.withLock { requests.first } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SelectionCaptureProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(request) ?? Data()
        Self.lock.withLock { Self.requests.append((request.url, body)) }
        // Lock only the request shape: respond with 200 + an empty stream, and parse failures are tolerated.
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://selection.invalid")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: size)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Gemini Interactions routing (same-name cases for the shared fixtures)", .serialized)
struct GeminiInteractionsSelectionTests {
    private static let directory = ["shared", "test-fixtures", "provider-toolcall"]

    private static func url(_ components: [String]) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = components.reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func object(_ components: [String]) throws -> [String: Any] {
        let data = try Data(contentsOf: url(components))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func fixture() throws -> [String: Any] {
        try object(directory + ["gemini_interactions.selection.v1.json"])
    }

    private static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return "<invalid>"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// metadata = the fixture's model + capability_controls; runtime is an envelope in the production shape (the web recipe is the server registry's),
    /// and the reasoning recipe comes from the golden `reasoning_recipe`, installed as `gemini.interactions.reasoning.v1`.
    private static func loadMetadata(_ fixture: [String: Any]) async throws -> String {
        let model = try #require(fixture["model"] as? [String: Any])
        let modelID = try #require(model["modelId"] as? String)
        let transport = try #require(model["transport"] as? String)
        let controls = try #require(fixture["capability_controls"] as? [String: Any])
        var envelope = try CapabilityRuntimeFixtures.runtimeEnvelope()
        var recipes = try #require(envelope["recipes"] as? [String: Any])
        #expect(recipes["gemini.interactions.web.v1"] != nil, "registry is missing gemini.interactions.web.v1")
        let golden = try object(directory + ["gemini_interactions.request-golden.v1.json"])
        var reasoning = try #require(golden["reasoning_recipe"] as? [String: Any])
        // availableIntents goes through the verdict (control), not the recipe.
        reasoning.removeValue(forKey: "availableIntents")
        let reasoningID = try #require(reasoning["id"] as? String)
        #expect(reasoningID == "gemini.interactions.reasoning.v1")
        recipes[reasoningID] = reasoning
        envelope["recipes"] = recipes
        let document: [String: Any] = [
            "version": 1,
            "capabilityRuntime": envelope,
            "providers": ["gemini": [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": transport,
                    "capabilities": ["text", "web"],
                    "capabilityControls": controls,
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        )
        return modelID
    }

    private static func messages(_ input: [String: Any], modelID: String) throws -> [ChatMessage] {
        let raw = try #require(input["messages"] as? [[String: Any]])
        return try raw.map { item in
            let role: ChatRole = item["role"] as? String == "assistant" ? .assistant : .user
            let parts = try #require(item["parts"] as? [[String: Any]])
            let text = parts.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            let attachments: [Oriveo.Attachment] = parts.compactMap { part in
                guard part["type"] as? String == "video" else { return nil }
                return Oriveo.Attachment(
                    id: UUID(), kind: .video, fileName: "clip.mp4",
                    mimeType: part["mime_type"] as? String ?? "", base64Data: part["data"] as? String ?? ""
                )
            }
            var message = ChatMessage(
                id: UUID(), role: role, text: text, providerKind: .gemini,
                providerName: "Gemini", modelName: modelID, state: .delivered
            )
            message.attachments = attachments.isEmpty ? nil : attachments
            return message
        }
    }

    private static func keys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.keys).union(object.values.flatMap { keys(in: $0) })
        }
        if let array = value as? [Any] { return Set(array.flatMap { keys(in: $0) }) }
        return []
    }

    private static func verify(_ id: String) async throws {
        let fixture = try fixture()
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "fixture is missing case \(id)")
        let input = try #require(item["input"] as? [String: Any])
        let expected = try #require(item["expected"] as? [String: Any])
        let modelID = try await loadMetadata(fixture)
        let reasoningMode: ReasoningMode = try {
            guard let token = input["reasoning"] as? String else { return .automatic }
            return try #require(ReasoningMode.fromIntent(token), "unknown reasoning \(token)")
        }()

        let history = try messages(input, modelID: modelID)
        let webEnabled = input["web"] as? Bool == true

        // Attachment transport resolution before sending uses the same criterion as outbound dispatch (AttachmentTransportResolver reads the same routing function).
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        let resolvedTransport = AttachmentTransportResolver.resolve(
            provider: TestFactories.makeProvider(kind: .gemini, models: [model]), model: model,
            request: .init(webSearchEnabled: webEnabled, historyHasVideo: GeminiService.historyHasVideo(history))
        )
        let expectedTransport: AttachmentTransport = expected["route"] as? String == "interactions"
            ? .geminiInteractions : .geminiGenerateContent
        #expect(
            resolvedTransport == expectedTransport,
            "\(id): attachment transport resolution disagrees with outbound routing: \(String(describing: resolvedTransport))"
        )

        SelectionCaptureProtocol.reset()
        do {
            // The request is always streaming (fixture conventions.messages).
            for try await _ in GeminiService(session: SelectionCaptureProtocol.session()).sendMessageStream(
                apiKey: "fixture-key", modelID: modelID, messages: history,
                reasoningMode: reasoningMode, webSearchEnabled: webEnabled
            ) {}
        } catch {}
        let captured = try #require(SelectionCaptureProtocol.first(), "\(id): no request was sent")
        let path = try #require(captured.url?.path)
        let body = try #require(try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        let raw = String(decoding: captured.body, as: UTF8.self)

        switch expected["route"] as? String {
        case "interactions":
            let suffix = try #require(expected["path_suffix"] as? String)
            #expect(path.hasSuffix(suffix), "\(id): should go through Interactions, actually \(path)")
            let expectedConfig = expected["generation_config"]
            if expectedConfig == nil || expectedConfig is NSNull {
                #expect(body["generation_config"] == nil, "\(id): generation_config must not appear\n\(raw)")
            } else {
                #expect(
                    canonical(body["generation_config"] ?? NSNull()) == canonical(expectedConfig!),
                    "\(id): generation_config differs\n\(raw)"
                )
            }
            #expect(
                canonical(body["tools"] ?? NSNull()) == canonical(expected["tools"] ?? NSNull()),
                "\(id): tools differ\n\(raw)"
            )
        case "generate_content":
            #expect(path.contains(":streamGenerateContent"), "\(id): should go through generateContent, actually \(path)")
            for key in ["input", "store", "generation_config", "tools"] {
                #expect(body[key] == nil, "\(id): the generateContent body must not contain \(key)\n\(raw)")
            }
            let present = keys(in: body)
            for key in ["thinking_summaries", "thinking_level"] {
                #expect(!present.contains(key), "\(id): the generateContent body contained \(key)")
            }
            if expected["video_inline"] == nil || expected["video_inline"] is NSNull {
                #expect(!keys(in: body).contains("inlineData"), "\(id): inlineData should not be carried\n\(raw)")
            }
            if let video = expected["video_inline"] as? [String: Any] {
                let parts = ((body["contents"] as? [[String: Any]]) ?? [])
                    .flatMap { ($0["parts"] as? [[String: Any]]) ?? [] }
                let inline = parts.compactMap { $0["inlineData"] }.map { canonical($0) }
                #expect(inline.contains(canonical(video)), "\(id): the video was not delivered as inlineData\n\(raw)")
            }
        default:
            Issue.record("\(id): unknown route \(String(describing: expected["route"]))")
        }
    }

    @Test("A Gemini model with transport=gemini_interactions is visible in the picker")
    func interactionsTransportIsVisibleInPicker() async throws {
        let modelID = try await Self.loadMetadata(try Self.fixture())
        #expect(TransportRegistry.isSupported(kindRaw: "gemini_interactions"))
        #expect(try TransportRegistry.getStrategy(for: "gemini_interactions").kind == .geminiInteractions)
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        #expect(isModelTransportSupportedForPicker(
            provider: TestFactories.makeProvider(kind: .gemini, models: [model]), model: model
        ))
    }

    @Test func GI_SEL_REASONING_EXPLICIT() async throws { try await Self.verify("GI_SEL_REASONING_EXPLICIT") }
    @Test func GI_SEL_REASONING_AUTOMATIC() async throws { try await Self.verify("GI_SEL_REASONING_AUTOMATIC") }
    @Test func GI_SEL_WEB_OFF_STAYS_GENERATE() async throws { try await Self.verify("GI_SEL_WEB_OFF_STAYS_GENERATE") }
    @Test func GI_SEL_VIDEO_EXCLUDES_INTERACTIONS() async throws { try await Self.verify("GI_SEL_VIDEO_EXCLUDES_INTERACTIONS") }
    @Test func GI_SEL_VIDEO_IN_HISTORY_EXCLUDES_INTERACTIONS() async throws {
        try await Self.verify("GI_SEL_VIDEO_IN_HISTORY_EXCLUDES_INTERACTIONS")
    }
    @Test func GI_SEL_VIDEO_WITHOUT_DATA_EXCLUDES_INTERACTIONS() async throws {
        try await Self.verify("GI_SEL_VIDEO_WITHOUT_DATA_EXCLUDES_INTERACTIONS")
    }

    /// Video appears only in earlier turns that outbound normalization trims (a new question after a failed turn, where the old user turn is dropped by merging adjacent same-role turns):
    /// the pre-send check and the outbound path both judge by the outbound history, and both go through Interactions.
    /// When neither the history nor this turn has video: the pre-check returns false directly, without running outbound normalization or the attachment budget (the model panel calls it on every evaluation).
    @Test("preflightHistoryHasVideo short-circuits when there is no video, without running outbound normalization")
    func preflightShortCircuitsWithoutVideo() {
        var image = ChatMessage(
            id: UUID(), role: .user, text: "look", providerKind: .gemini,
            providerName: "Gemini", modelName: "m", state: .delivered
        )
        image.attachments = [Oriveo.Attachment(id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png", base64Data: "aGk=")]
        var calls = 0
        let result = ChatManager.preflightHistoryHasVideo(
            history: [image], pendingText: "q", pendingAttachments: [],
            outboundHistory: { calls += 1; return $0 }
        )
        #expect(!result)
        #expect(calls == 0, "Outbound normalization still ran without video")
        // Normalize only when there is video (this turn's video counts too).
        let video = Oriveo.Attachment(id: UUID(), kind: .video, fileName: "c.mp4", mimeType: "video/mp4", base64Data: nil)
        #expect(ChatManager.preflightHistoryHasVideo(
            history: [image], pendingText: "q", pendingAttachments: [video],
            outboundHistory: { calls += 1; return $0 }
        ))
        #expect(calls == 1)
    }

    @Test func GI_PREFLIGHT_USES_OUTBOUND_HISTORY() async throws {
        let modelID = try await Self.loadMetadata(try Self.fixture())
        var early = ChatMessage(
            id: UUID(), role: .user, text: "What happens in this clip?", providerKind: .gemini,
            providerName: "Gemini", modelName: modelID, state: .delivered
        )
        early.attachments = [Oriveo.Attachment(
            id: UUID(), kind: .video, fileName: "clip.mp4", mimeType: "video/mp4", base64Data: "AAAAIGZ0eXBpc29t"
        )]
        let failed = ChatMessage(
            id: UUID(), role: .assistant, text: "Request failed.", providerKind: .gemini,
            providerName: "Gemini", modelName: modelID, state: .failed
        )
        let history = [early, failed]
        let pendingText = "And then?"
        let pending = ChatMessage(
            id: UUID(), role: .user, text: pendingText, providerKind: .gemini,
            providerName: "Gemini", modelName: modelID, state: .delivered
        )

        // Pre-send check (the same function ChatManager.composerAttachmentOverLimit uses).
        let preflightVideo = ChatManager.preflightHistoryHasVideo(
            history: history, pendingText: pendingText, pendingAttachments: []
        )
        #expect(!preflightVideo, "The pre-check counted early video that outbound would trim")
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text])
        #expect(AttachmentTransportResolver.resolve(
            provider: TestFactories.makeProvider(kind: .gemini, models: [model]), model: model,
            request: .init(webSearchEnabled: true, historyHasVideo: preflightVideo)
        ) == .geminiInteractions)

        // Outbound: the history normalized by the production ChatRequestBuilder is handed to the production dispatch.
        let outbound = ChatRequestBuilder.build(from: ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: history + [pending], preferences: ChatRequestPreferencesSnapshot(), skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )).requestMessages
        SelectionCaptureProtocol.reset()
        do {
            for try await _ in GeminiService(session: SelectionCaptureProtocol.session()).sendMessageStream(
                apiKey: "fixture-key", modelID: modelID, messages: outbound,
                reasoningMode: .deep, webSearchEnabled: true
            ) {}
        } catch {}
        let path = try #require(SelectionCaptureProtocol.first()?.url?.path)
        #expect(path.hasSuffix("/v1beta/interactions"), "The outbound path should go through Interactions, actually \(path)")
    }
}
