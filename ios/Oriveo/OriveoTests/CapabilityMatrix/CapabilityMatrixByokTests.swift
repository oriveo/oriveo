import Foundation
import Testing
@testable import Oriveo

// Capability matrix: the four cells of an official BYOK connection.
// The connection is always an official API key; the recipe always comes from the production registry (`CapabilityRuntimeFixtures`),
// and the catalog comes from the shared metadata fixture; assertions land on the request bodies actually produced by the production builder / send chain and on production decision functions.

/// Replays upstream responses from a script and records every request body. Used only by this file; process-level state is not shared with other suites.
private final class ByokScriptedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var script: [(status: Int, body: Data)] = []
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    private static let lock = NSLock()

    static func reset(_ responses: [(Int, String)]) {
        lock.withLock {
            script = responses.map { ($0.0, Data($0.1.utf8)) }
            bodies = []
        }
    }

    static func recorded() -> [[String: Any]] { lock.withLock { bodies } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ByokScriptedProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.bodyData(request)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let next: (status: Int, body: Data) = Self.lock.withLock {
            Self.bodies.append(object)
            return Self.script.isEmpty ? (200, Data()) : Self.script.removeFirst()
        }
        let contentType = next.status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://byok.invalid")!, statusCode: next.status,
            httpVersion: nil, headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
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

private let anthropicOKStream = [
    ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#),
    ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
    ("message_stop", #"{"type":"message_stop"}"#),
].map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()

private func chatTextLeg(_ text: String) -> String {
    [
        #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
    ].map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
}

/// The 422 shape (`detail[].msg`) from the shared contract for unsupported tools.
private let toolsRejected422 = #"{"detail":[{"type":"extra_forbidden","loc":["body","tools"],"msg":"Extra inputs are not permitted","input":[]}]}"#

@Suite("Capability matrix · official BYOK (CAP-BYOK)", .serialized)
struct CapabilityMatrixByokTests {

    // MARK: - Web search / thinking (official Anthropic Messages connection)

    private static let anthropicModelID = "claude-sonnet-4-6"
    private static let webRecipe = "anthropic.messages.web.v1"
    private static let reasoningRecipe = "anthropic.messages.reasoning.v2"

    private static func loadAnthropicMetadata(controls: [CapabilityRuntimeFixtures.ControlSpec]) async throws {
        let document: [String: Any] = [
            "version": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "providers": ["anthropic": [
                "resolveMap": [anthropicModelID: anthropicModelID],
                "models": [anthropicModelID: [
                    "canonicalModelId": anthropicModelID,
                    "transport": "anthropic_messages",
                    "capabilities": ["text", "web", "reasoning"],
                    "capabilityControls": CapabilityRuntimeFixtures.controls(controls),
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self),
            metadataETag: CapabilityRuntimeFixtures.defaultRevision
        )
    }

    private static func reasoningControl() throws -> CapabilityRuntimeFixtures.ControlSpec {
        .init(
            capability: "reasoning", recipeRef: reasoningRecipe,
            availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(ofRecipe: reasoningRecipe)
        )
    }

    private static let anthropicProvider = TestFactories.makeProvider(
        kind: .anthropic, models: [TestFactories.makeModel(id: anthropicModelID)]
    )

    /// The first request body sent by the official Anthropic production builder; when `identity` is non-nil it is sent under that dispatch identity (the negative cache is read by it).
    private static func anthropicBody(
        reasoningMode: ReasoningMode = .automatic,
        webSearchEnabled: Bool = false,
        identity: CapabilityEvidenceRequestIdentity? = nil
    ) async throws -> [String: Any] {
        ByokScriptedProtocol.reset([(200, anthropicOKStream)])
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .anthropic,
            providerName: "Anthropic", modelName: anthropicModelID, state: .delivered
        )
        let send = {
            for try await _ in AnthropicService(session: ByokScriptedProtocol.session()).sendMessageStream(
                apiKey: "sk-ant-fixture", modelID: anthropicModelID, messages: [message],
                reasoningMode: reasoningMode, webSearchEnabled: webSearchEnabled, requestOptions: ChatRequestOptions()
            ) {}
        }
        do {
            if let identity {
                try await CapabilityEvidenceRequestContext.$current.withValue(identity) { try await send() }
            } else {
                try await send()
            }
        } catch {}
        return try #require(ByokScriptedProtocol.recorded().first, "The production builder sent no request")
    }

    private static func effort(_ body: [String: Any]) -> String? {
        (body["output_config"] as? [String: Any])?["effort"] as? String
    }

    private static func recipeEffort(_ intent: String) throws -> String {
        try #require(try CapabilityRuntimeFixtures.recipeValue(
            recipeRef: reasoningRecipe, intent: intent, pointer: "/output_config/effort"
        ) as? String)
    }

    @Test("CAP-BYOK-WEB-01：the recipe ships web auto_available and the user turns web search on -> the request body contains the fields the recipe writes")
    func CAP_BYOK_WEB_01_recipe_web_reaches_body() async throws {
        try await Self.loadAnthropicMetadata(controls: [.init(capability: "web", recipeRef: Self.webRecipe)])
        let body = try await Self.anthropicBody(webSearchEnabled: true)
        let expected = try #require(
            try CapabilityRuntimeFixtures.recipeValue(recipeRef: Self.webRecipe, pointer: "/tools/-") as? [String: Any]
        )
        let tools = try #require(body["tools"] as? [[String: Any]], "The request body has no tools")
        #expect(tools.contains { NSDictionary(dictionary: $0).isEqual(to: expected) }, "tools has no web search tool written by the recipe:\(tools)")
    }

    @Test("CAP-BYOK-WEB-02：same model without a recipe (control missing / unknown) and the preference still on -> the request body has no web search field at all")
    func CAP_BYOK_WEB_02_no_recipe_no_web_fields() async throws {
        let variants: [[CapabilityRuntimeFixtures.ControlSpec]] = [
            [try Self.reasoningControl()],
            [.init(capability: "web", state: "unknown"), try Self.reasoningControl()],
        ]
        for controls in variants {
            try await Self.loadAnthropicMetadata(controls: controls)
            let body = try await Self.anthropicBody(webSearchEnabled: true)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            #expect(body["model"] as? String == Self.anthropicModelID, "Precondition: a request for this model was really sent")
            #expect(body["tools"] == nil, "Without a recipe there must be no tools:\(text)")
            #expect(!text.contains("web_search"), "Without a recipe there must be no web search field:\(text)")
        }
    }

    @Test("CAP-BYOK-REASON-01：recipe availableIntents has several levels and one is picked -> the request body is that level's value written through the recipe")
    func CAP_BYOK_REASON_01_selected_intent_reaches_body() async throws {
        let control = try Self.reasoningControl()
        #expect((control.availableIntents?.count ?? 0) > 1, "Precondition: the recipe declares several levels")
        try await Self.loadAnthropicMetadata(controls: [control])
        let body = try await Self.anthropicBody(reasoningMode: .deep)
        #expect(Self.effort(body) == (try Self.recipeEffort("deep")))
        let thinking = try #require(body["thinking"] as? [String: Any])
        let expectedThinking = try #require(try CapabilityRuntimeFixtures.recipeValue(
            recipeRef: Self.reasoningRecipe, intent: "deep", pointer: "/thinking"
        ) as? [String: Any])
        #expect(NSDictionary(dictionary: thinking).isEqual(to: expectedThinking))
    }

    @Test("CAP-BYOK-REASON-02：levels the upstream rejected fall to the nearest level on send (down first, then up); levels not rejected are unaffected; if all are rejected the item is omitted")
    func CAP_BYOK_REASON_02_rejected_tier_falls_to_nearest() async throws {
        try await Self.loadAnthropicMetadata(controls: [try Self.reasoningControl()])
        UnsupportedParamCache.shared.resetForTesting()
        defer { UnsupportedParamCache.shared.resetForTesting() }
        let model = TestFactories.makeModel(id: Self.anthropicModelID)
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: Self.anthropicProvider, model: model, partitionID: "cap-byok-reason-02",
            hasExplicitValue: true, metadataETag: CapabilityRuntimeFixtures.defaultRevision
        )
        // The negative cache and the outbound gate use the same exact identity: connection x canonical model x final protocol x runtime generation.
        let scoped = try #require(
            identity.resolvingCapabilityRuntimeTransport("anthropic_messages")?
                .resolvingRuntimeRevision(CapabilityRuntimeFixtures.defaultRevision)
        )
        func reject(_ mode: ReasoningMode) {
            UnsupportedParamCache.shared.markCapabilityRejected(
                providerKind: .anthropic, modelID: scoped.query.effectiveModelID, source: .providerRecipe,
                owner: "reasoning", recipeRef: Self.reasoningRecipe, setting: "/output_config/effort",
                capabilityKey: "reasoning_level/\(mode.rawValue)",
                endpointFingerprint: scoped.query.endpointFingerprint, identity: scoped
            )
        }

        // Only max was rejected: picking max falls down to deep.
        reject(.max)
        // The panel reads the same negative cache: an official connection (no endpoint fingerprint) also shows the rejected level.
        let panelKeys = ModelControlsSheet.rejectedCapabilityKeys(
            provider: Self.anthropicProvider, model: model, partitionID: "cap-byok-reason-02"
        )
        #expect(panelKeys == ["reasoning_level/max"], "Levels rejected on the panel:\(panelKeys)")
        #expect(Self.effort(try await Self.anthropicBody(reasoningMode: .max, identity: identity)) == (try Self.recipeEffort("deep")))

        // Reject deep too: picking balanced is unaffected; picking max keeps falling down to balanced.
        reject(.deep)
        #expect(Self.effort(try await Self.anthropicBody(reasoningMode: .balanced, identity: identity)) == (try Self.recipeEffort("balanced")))
        #expect(Self.effort(try await Self.anthropicBody(reasoningMode: .max, identity: identity)) == (try Self.recipeEffort("balanced")))

        // When nothing usable remains below, go up: reject only low, and picking low -> balanced.
        UnsupportedParamCache.shared.resetForTesting()
        reject(.fast)
        #expect(Self.effort(try await Self.anthropicBody(reasoningMode: .fast, identity: identity)) == (try Self.recipeEffort("balanced")))

        // A non-leveled rejection coexisting with leveled ones: there is no way to tell which level still works, so the whole group is omitted (even if the selected level was not rejected).
        UnsupportedParamCache.shared.resetForTesting()
        reject(.deep)
        UnsupportedParamCache.shared.markCapabilityRejected(
            providerKind: .anthropic, modelID: scoped.query.effectiveModelID, source: .providerRecipe,
            owner: "reasoning", recipeRef: Self.reasoningRecipe, setting: "/output_config/effort",
            capabilityKey: nil, endpointFingerprint: scoped.query.endpointFingerprint, identity: scoped
        )
        for mode in [ReasoningMode.deep, .balanced] {
            let mixed = try await Self.anthropicBody(reasoningMode: mode, identity: identity)
            #expect(mixed["output_config"] == nil && mixed["thinking"] == nil, "A non-leveled plus leveled mix must omit the whole group (\(mode)):\(mixed)")
        }
        UnsupportedParamCache.shared.resetForTesting()
        reject(.fast)

        // Only when all levels are rejected is the item omitted.
        for mode in [ReasoningMode.balanced, .deep, .max] { reject(mode) }
        let none = try await Self.anthropicBody(reasoningMode: .deep, identity: identity)
        #expect(none["output_config"] == nil && none["thinking"] == nil, "When all levels are rejected the item must be omitted:\(none)")
    }

    // MARK: - Attachments

    /// Shared relay metadata fixture + a native-file allowlist added in memory for claude-sonnet-4.5; the fixture file is not modified.
    private static func loadFixtureMetadata(nativeFileMimes: [String]?) async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
                url.appendPathComponent("shared/test-fixtures/relay/metadata-fixture.json")
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        if let nativeFileMimes {
            var providers = try #require(root["providers"] as? [String: Any])
            var anthropic = try #require(providers["anthropic"] as? [String: Any])
            var models = try #require(anthropic["models"] as? [String: Any])
            var sonnet = try #require(models["claude-sonnet-4.5"] as? [String: Any])
            sonnet["nativeFileMimes"] = nativeFileMimes
            sonnet["pdfNativeDefault"] = true
            models["claude-sonnet-4.5"] = sonnet
            anthropic["models"] = models
            providers["anthropic"] = anthropic
            root["providers"] = providers
        }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        )
    }

    @Test("CAP-BYOK-ATTACH-01：nativeFileMimes contains PDF and Anthropic Messages attaches a PDF -> native document block, no text fallback")
    func CAP_BYOK_ATTACH_01_pdf_native_document_block() async throws {
        try await Self.loadFixtureMetadata(nativeFileMimes: ["application/pdf"])
        NativeFileFallback.resetMemoryForTesting()
        defer { NativeFileFallback.resetMemoryForTesting() }
        // The allowlist comes from the production catalog enrichment (models stored in the connection are refreshed from metadata), not attached by hand.
        let local = CatalogModelBuilder.enrichStoredModel(
            TestFactories.makeModel(id: "claude-sonnet-4.5", capabilities: [.text]), providerKind: .anthropic
        )
        let provider = TestFactories.makeProvider(kind: .anthropic, models: [local])
        let evidence = AttachmentTransportResolver.evidenceModel(provider: provider, model: local)
        #expect(evidence.nativeFileMimes.contains("application/pdf") && evidence.pdfNativeDefault, "Precondition: the catalog allowlist reached the model used for sending")
        #expect(AttachmentTransportResolver.resolve(provider: provider, model: local, request: .init(webSearchEnabled: false)) == .anthropicMessages)

        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = evidence
        options.attachmentConnectionID = provider.id
        let pdf = Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
        let turn = ChatMessage(
            id: UUID(), role: .user, text: "summarize", providerKind: .anthropic, providerName: "Anthropic",
            modelID: local.id, modelName: local.name, state: .delivered, attachments: [pdf]
        )
        ByokScriptedProtocol.reset([(200, anthropicOKStream)])
        do {
            for try await _ in AnthropicService(session: ByokScriptedProtocol.session()).sendMessageStream(
                apiKey: "sk-ant-fixture", modelID: local.id, messages: [turn], requestOptions: options
            ) {}
        } catch {}
        let bodies = ByokScriptedProtocol.recorded()
        #expect(bodies.count == 1, "A direct connection neither falls back nor resends")
        let body = try #require(bodies.first)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let blocks = ((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]) ?? []
        #expect(blocks.contains { $0["type"] as? String == "document" }, "No native document block:\(text)")
        #expect(text.contains("JVBERi0xLjQ="), "The document block should hold the raw PDF bytes")
        #expect(!text.contains("EXTRACTED-PDF-BODY"), "With the native path there must be no text fallback:\(text)")
    }

    @Test("CAP-BYOK-ATTACH-02：vision unknown (no positive image evidence in the catalog) -> the photo library / vision entry is hidden")
    func CAP_BYOK_ATTACH_02_unknown_vision_hides_photo_entry() async throws {
        try await Self.loadFixtureMetadata(nativeFileMimes: nil)
        var model = TestFactories.makeModel(id: "claude-private-preview", capabilities: [.text])
        model.isManual = true
        let provider = TestFactories.makeProvider(kind: .anthropic, models: [model])
        #expect(MetadataClient.shared.syncResolveCatalogModel(modelID: model.id, providerKind: .anthropic) == nil, "Precondition: the catalog does not contain this model")
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "cap-byok-attach-02", hasExplicitValue: false
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: ["vision_input"]
        )
        #expect(projection.resolution(for: "vision_input")?.support == .unknown, "Precondition: vision is unknown")
        let visible = ChatView.visibleCapabilityKeys(provider: provider, model: model, projection: projection)
        #expect(!ChatComposerBar.supportsImageAttachment(provider: provider, model: model, visibleCapabilityKeys: visible))
    }
}
