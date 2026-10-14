import Foundation
import Testing
@testable import Oriveo

// Capability matrix for relay connections (the four RELAY sections of the capability spec).
// Every request goes out through the production `AppState.sendMessage`; the outbound body is captured at the URLProtocol HTTP seam.

/// Replays upstream responses in order and records every request. Used by this file only.
private final class RelayMatrixScriptedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    /// Responses replayed in order; once empty it answers 200 + `chatOK`.
    nonisolated(unsafe) private static var _script: [(status: Int, body: String)] = []
    private static let lock = NSLock()

    static let chatOK = """
    data: {"choices":[{"delta":{"content":"ok"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    static func reset(_ replies: [(Int, String)] = []) {
        lock.withLock {
            _requests = []
            _script = replies.map { ($0.0, $0.1) }
        }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayMatrixScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? readStream(request.httpBodyStream)
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A body stream can only be read once: read it here and hang it back on httpBody so tests can read it again.
        var recorded = request
        if recorded.httpBody == nil, let data = Self.readStream(request.httpBodyStream) {
            recorded.httpBody = data
        }
        let next: (status: Int, body: String) = Self.lock.withLock {
            Self._requests.append(recorded)
            return Self._script.isEmpty ? (200, Self.chatOK) : Self._script.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.invalid")!, statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": next.status == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Capability matrix: relay (CAP-RELAY)", .serialized)
@MainActor
struct CapabilityMatrixRelayTests {

    private static var retainedStates: [AppState] = []

    private static func metadataFixture() throws -> String {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/metadata-fixture.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func provider(_ requested: RelayRequestedConfig, model: AIModel) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay.test/v1",
            relayRequested: requested
        )
    }

    private static func model(_ transport: RelayTransport, inheritsOfficialWeb: Bool = false) -> AIModel {
        var model = AIModel(
            id: "gpt-5.4", name: "gpt-5.4", capabilities: inheritsOfficialWeb ? [.text, .web] : [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = transport
        model.relayTransportSource = .reachable
        if inheritsOfficialWeb { model.webSearchProfile = "oai_responses_web" }
        return model
    }

    /// Sends one message through the production `AppState.sendMessage` and returns the first outbound request body and the connection after sending.
    private static func send(
        provider: Provider, modelID: String, webPreferenceOn: Bool = false
    ) async throws -> (body: [String: Any], provider: Provider?) {
        var selection = ChatCapabilitySelection()
        selection.webSearchEnabled = webPreferenceOn
        let result = try await sendAll(provider: provider, modelID: modelID, selection: selection)
        let first = try #require(result.bodies.first, "The production send chain did not emit a request")
        return (first, result.provider)
    }

    /// Same as above but returns every outbound request body of the send; when `metadataJSON` is nil the shared metadata fixture is used.
    private static func sendAll(
        provider: Provider, modelID: String,
        selection: ChatCapabilitySelection = ChatCapabilitySelection(),
        attachments: [Oriveo.Attachment] = [],
        replies: [(Int, String)] = [],
        metadataJSON: String? = nil
    ) async throws -> (bodies: [[String: Any]], provider: Provider?, message: ChatMessage?) {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try metadataJSON ?? metadataFixture())
        defer { Task { await MetadataClient.shared.resetForTesting() } }
        RelayMatrixScriptedProtocol.reset(replies)

        let state = AppState(
            seedDemoData: false,
            sessionUID: "cap-relay-\(UUID().uuidString)",
            providerSession: RelayMatrixScriptedProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .relay, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage(
            "search the news", attachments: attachments, in: conversation.id, capabilitySelection: selection
        )

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant,
               message.state == .failed || message.state == .delivered {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return (
            RelayMatrixScriptedProtocol.requests.map(RelayMatrixScriptedProtocol.body),
            state.provider(for: provider.id),
            state.conversation(for: conversation.id)?.messages.last
        )
    }

    /// The shared metadata fixture with a few in-memory edits (the fixture file itself is not touched).
    private static func metadataFixture(_ edit: (inout [String: Any]) throws -> Void) throws -> String {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(metadataFixture().utf8)) as? [String: Any])
        try edit(&root)
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private static func text(_ body: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func tools(_ body: [String: Any]) -> [[String: Any]] {
        (body["tools"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    // MARK: - Web search

    @Test("CAP-RELAY-WEB-01: a stored fragment appears in the production request body (merged per mergeCases)")
    func CAP_RELAY_WEB_01_saved_fragment_reaches_body() async throws {
        // Chat: object keys are added straight into the request body.
        let chatModel = Self.model(.openaiChatCompletions)
        let chat = Self.provider(RelayRequestedConfig(transport: .openaiChatCompletions), model: chatModel)
        defer { RelayWebFragmentStore.shared.deleteConnection(chat.id) }
        RelayWebFragmentStore.shared.save(
            connectionID: chat.id, transport: .openaiChatCompletions,
            raw: #"{"web_search_options":{"search_context_size":"low"}}"#
        )
        let chatBody = try await Self.send(provider: chat, modelID: chatModel.id).body
        #expect(chatBody["model"] as? String == chatModel.id, "Precondition: a request for this model was actually sent")
        let options = try #require(chatBody["web_search_options"] as? [String: Any], "\(Self.text(chatBody))")
        #expect(options["search_context_size"] as? String == "low")

        // Responses: fragment tools are appended after the builder tools; they are always sent even when the in-chat web preference is off.
        let responsesModel = Self.model(.openaiResponses)
        let responses = Self.provider(RelayRequestedConfig(transport: .openaiResponses), model: responsesModel)
        defer { RelayWebFragmentStore.shared.deleteConnection(responses.id) }
        RelayWebFragmentStore.shared.save(
            connectionID: responses.id, transport: .openaiResponses, raw: #"{"tools":[{"type":"web_search"}]}"#
        )
        let responsesBody = try await Self.send(provider: responses, modelID: responsesModel.id, webPreferenceOn: false).body
        let types = Self.tools(responsesBody).compactMap { $0["type"] as? String }
        #expect(types == ["image_generation", "web_search"], "\(Self.text(responsesBody))")
    }

    @Test("CAP-RELAY-WEB-02: no fragment and no legacy field -> the request body has no web-search field at all (web preference on, model inherits the official web profile)")
    func CAP_RELAY_WEB_02_no_fragment_no_web_fields() async throws {
        for transport in [RelayTransport.openaiResponses, .geminiGenerateContent, .openaiChatCompletions] {
            let model = Self.model(transport, inheritsOfficialWeb: true)
            let provider = Self.provider(RelayRequestedConfig(transport: transport), model: model)
            defer { RelayWebFragmentStore.shared.deleteConnection(provider.id) }
            let body = try await Self.send(provider: provider, modelID: model.id, webPreferenceOn: true).body
            let text = Self.text(body)
            #expect(!body.isEmpty, "Precondition: a request was actually sent (\(transport.rawValue))")
            #expect(!text.contains("web_search"), "\(transport.rawValue) must not carry a web-search tool: \(text)")
            #expect(!text.contains("googleSearch") && !text.contains("google_search"), "\(transport.rawValue)：\(text)")
            #expect(body["plugins"] == nil, "\(transport.rawValue)：\(text)")
        }
    }

    @Test("CAP-RELAY-WEB-03: legacy connection with hasWebSearch == true, no profile, Responses -> same request body as the template, storage is not rewritten")
    func CAP_RELAY_WEB_03_legacy_flag_maps_to_template() async throws {
        let requested = try JSONDecoder().decode(
            RelayRequestedConfig.self, from: Data(#"{"transport":"openai_responses","hasWebSearch":true}"#.utf8)
        )
        let model = Self.model(.openaiResponses)
        let provider = Self.provider(requested, model: model)
        defer { RelayWebFragmentStore.shared.deleteConnection(provider.id) }
        let (body, after) = try await Self.send(provider: provider, modelID: model.id)
        let template = try #require(RelayWebFragments.template(for: .openaiResponses))
        let templateObject = try JSONSerialization.jsonObject(with: Data(template.utf8)) as? [String: Any]
        let templateTools = try #require(templateObject?["tools"] as? [[String: Any]])
        let sent = Self.tools(body)
        #expect(sent.count == 2, "\(Self.text(body))")
        let last = try #require(sent.last)
        let expectedTool = try #require(templateTools.first)
        #expect(NSDictionary(dictionary: last).isEqual(to: expectedTool), "\(Self.text(body))")
        #expect(RelayWebFragmentStore.shared.stored(connectionID: provider.id).isEmpty, "The mapping is not written into storage")
        #expect(after?.relayRequested?.hasWebSearch == true, "The legacy field in the connection config is not rewritten")
    }

    // MARK: - Reasoning

    private static func modelFacts(_ facts: [String: [String]]) throws -> String {
        try metadataFixture { root in
            root["modelFacts"] = facts.mapValues { ["reasoningEfforts": $0] }
            root["modelFactsRevision"] = "rev-cap-relay"
        }
    }

    @Test("CAP-RELAY-REASON-01: gemini-2.5-pro (Gemini protocol) whose model-facts list low...xhigh, max selected -> thinkingBudget = 24576")
    func CAP_RELAY_REASON_01_model_facts_tiers_reach_body() async throws {
        let json = try Self.modelFacts(["gemini/gemini-2.5-pro": ["low", "medium", "high", "xhigh"]])
        var model = AIModel(
            id: "gemini-2.5-pro", name: "gemini-2.5-pro", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = .geminiGenerateContent
        model.relayTransportSource = .reachable
        let provider = Self.provider(RelayRequestedConfig(transport: .geminiGenerateContent), model: model)

        // The same resolver the panel, the outbound request and the advanced page read: automatic tiers come from model-facts, with automatic first.
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
        #expect(verdict.intents == ["automatic", "low", "balanced", "deep", "max"], "\(verdict)")
        #expect(CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: "reasoning"
        ) == .automaticAvailable)

        var selection = ChatCapabilitySelection()
        selection.reasoningMode = .max
        let body = try #require(try await Self.sendAll(
            provider: provider, modelID: model.id, selection: selection, metadataJSON: json
        ).bodies.first)
        let config = (body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(config?["thinkingBudget"] as? Int == 24_576, "\(Self.text(body))")

        // No tier selected: still no reasoning field is sent (existing request bodies stay unchanged).
        let untouched = try #require(try await Self.sendAll(
            provider: provider, modelID: model.id, metadataJSON: json
        ).bodies.first)
        #expect(!Self.text(untouched).contains("thinkingConfig"), "\(Self.text(untouched))")
    }

    @Test("CAP-RELAY-REASON-02: Chat protocol, no model-facts -> with the template switch on, chat_template_kwargs.enable_thinking == true and other fields are unchanged")
    func CAP_RELAY_REASON_02_chat_template_switch() async throws {
        var model = AIModel(
            id: "local-qwen-x", name: "local-qwen-x", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .reachable
        let provider = Self.provider(RelayRequestedConfig(transport: .openaiChatCompletions), model: model)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())
        #expect(CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning").intents.isEmpty,
                "Precondition: without model-facts there are no tiers")

        let off = try #require(try await Self.sendAll(provider: provider, modelID: model.id).bodies.first)
        let modelKey = CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
        #expect(ChatTemplateThinkingSwitch.write(true, providerID: provider.id, modelID: modelKey, conversationID: nil))
        defer { _ = ChatTemplateThinkingSwitch.write(false, providerID: provider.id, modelID: modelKey, conversationID: nil) }
        var on = try #require(try await Self.sendAll(provider: provider, modelID: model.id).bodies.first)
        let kwargs = on.removeValue(forKey: "chat_template_kwargs") as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == true, "\(Self.text(on))")
        #expect(NSDictionary(dictionary: on).isEqual(to: off), "on: \(Self.text(on))\noff: \(Self.text(off))")
    }

    /// The connection stored low and this turn selects deep; take the first outbound request body through the production send chain.
    private static func bodyWithStoredConnectionEffort(_ transport: RelayTransport) async throws -> [String: Any] {
        let json = try modelFacts(["openAI/gpt-5.4": ["low", "medium", "high", "xhigh"]])
        let model = Self.model(transport)
        let provider = Self.provider(
            RelayRequestedConfig(transport: transport, reasoningEffort: .low), model: model
        )
        var selection = ChatCapabilitySelection()
        selection.reasoningMode = .deep
        return try #require(try await sendAll(
            provider: provider, modelID: model.id, selection: selection, metadataJSON: json
        ).bodies.first, "The production send chain did not emit a request")
    }

    @Test("Per-turn tier: stored reasoningEffort = low, this turn selects deep, Responses -> reasoning.effort is this turn's high")
    func relayConnectionLevelReasoningIsIgnoredOnResponses() async throws {
        let body = try await Self.bodyWithStoredConnectionEffort(.openaiResponses)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high", "\(Self.text(body))")
    }

    @Test("Per-turn tier: stored reasoningEffort = low, this turn selects deep, Chat Completions -> reasoning_effort is this turn's high")
    func relayConnectionLevelReasoningIsIgnoredOnChatCompletions() async throws {
        let body = try await Self.bodyWithStoredConnectionEffort(.openaiChatCompletions)
        #expect(body["reasoning_effort"] as? String == "high", "\(Self.text(body))")
    }

    // MARK: - Attachments

    private static let anthropicOK = [
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ].map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()

    /// anthropic claude-sonnet-4.5 with a native PDF allowlist (injected in memory).
    private static func pdfWhitelistMetadata() throws -> String {
        try metadataFixture { root in
            var providers = try #require(root["providers"] as? [String: Any])
            var anthropic = try #require(providers["anthropic"] as? [String: Any])
            var models = try #require(anthropic["models"] as? [String: Any])
            var sonnet = try #require(models["claude-sonnet-4.5"] as? [String: Any])
            sonnet["nativeFileMimes"] = ["application/pdf"]
            sonnet["pdfNativeDefault"] = true
            models["claude-sonnet-4.5"] = sonnet
            anthropic["models"] = models
            providers["anthropic"] = anthropic
            root["providers"] = providers
        }
    }

    /// A Messages model whose protocol source is observed, on a connection that defaults to Chat: the protocol comes only from this model's own observation.
    /// The allowlist is inherited through the production catalog enrichment (`RelayOfficialCatalogResolver.enrich`), not attached by hand.
    private static func observedMessagesProvider() async throws -> (Provider, AIModel) {
        var local = AIModel(
            id: "claude-sonnet-4.5", name: "claude-sonnet-4.5", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        local.relayTransport = .anthropicMessages
        local.relayTransportSource = .observed
        var provider = Self.provider(RelayRequestedConfig(transport: .openaiChatCompletions), model: local)
        provider.catalogModels = [local]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try pdfWhitelistMetadata())
        var resolved = RelayOfficialCatalogResolver.enrich(
            localModel: local, provider: provider, runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
        )
        // Enrichment merges catalog fields only; the model's own protocol and source are local fields, carried over as stored.
        resolved.relayTransport = local.relayTransport
        resolved.relayTransportSource = local.relayTransportSource
        #expect(resolved.nativeFileMimes.contains("application/pdf"), "Precondition: the official PDF allowlist was inherited")
        provider.models = [resolved]
        provider.catalogModels = [resolved]
        return (provider, resolved)
    }

    private static func textPdf() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
    }

    @Test("CAP-RELAY-ATTACH-01: a Messages model with an observed protocol source inherits the PDF allowlist -> the request body has type document")
    func CAP_RELAY_ATTACH_01_observed_messages_sends_document() async throws {
        let (provider, model) = try await Self.observedMessagesProvider()
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let result = try await Self.sendAll(
            provider: provider, modelID: model.id, attachments: [Self.textPdf()],
            replies: [(200, Self.anthropicOK)], metadataJSON: try Self.pdfWhitelistMetadata()
        )
        let body = Self.text(try #require(result.bodies.first, "No request was sent"))
        #expect(body.contains(#""type":"document""#), "\(body.prefix(800))")
        #expect(!body.contains("EXTRACTED-PDF-BODY"), "Extracted text is not injected when the native block is sent")
    }

    @Test("CAP-RELAY-ATTACH-02: upstream rejects the document with 400 before any output -> one text resend")
    func CAP_RELAY_ATTACH_02_document_rejected_resends_text_once() async throws {
        let (provider, model) = try await Self.observedMessagesProvider()
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let rejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"document blocks are not supported"}}"#
        let result = try await Self.sendAll(
            provider: provider, modelID: model.id, attachments: [Self.textPdf()],
            replies: [(400, rejection), (200, Self.anthropicOK)], metadataJSON: try Self.pdfWhitelistMetadata()
        )
        #expect(result.bodies.count == 2, "First send plus one text resend")
        let first = Self.text(try #require(result.bodies.first))
        let second = Self.text(try #require(result.bodies.last))
        #expect(first.contains(#""type":"document""#))
        #expect(!second.contains(#""type":"document""#) && second.contains("EXTRACTED-PDF-BODY"), "\(second.prefix(800))")
        #expect(result.message?.state == .delivered)
    }

    @Test("CAP-RELAY-ATTACH-03: vision unknown -> the photo entry is visible, then hidden after an image negative cache is recorded")
    func CAP_RELAY_ATTACH_03_unknown_vision_entry_hides_after_rejection() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())
        defer { Task { await MetadataClient.shared.resetForTesting() } }
        var model = AIModel(
            id: "relay-vision-unknown", name: "relay-vision-unknown", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .reachable
        let provider = Self.provider(RelayRequestedConfig(transport: .openaiChatCompletions), model: model)
        let cache = RelayNegativeCache(defaults: UserDefaults(suiteName: "cap-relay-attach-03-\(UUID().uuidString)")!)
        func photoEntryVisible() -> Bool {
            let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: "cap-relay-attach-03"
            )
            let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider: provider, model: model, identity: identity, keys: ["vision_input", "tool_call"]
            )
            let keys = ChatView.visibleCapabilityKeys(
                provider: provider, model: model, projection: projection, negativeCache: cache
            )
            return ChatComposerBar.supportsImageAttachment(provider: provider, model: model, visibleCapabilityKeys: keys)
        }
        #expect(RelayRejectionRecording.imageSupportUnknown(provider: provider, model: model), "Precondition: vision is unknown")
        #expect(photoEntryVisible(), "Unknown still shows the entry")
        let recorded = RelayRejectionRecording.recordImageRejection(
            provider: provider, model: model, transport: .openaiChatCompletions,
            rejection: RelayPreOutputRejection(
                status: 400, contentType: "application/json",
                body: Data(#"{"error":{"message":"image input is not supported for this model"}}"#.utf8)
            ),
            negativeCache: cache
        )
        #expect(recorded)
        #expect(!photoEntryVisible(), "Hidden after an image negative cache is recorded")
    }

    // MARK: - Tools

    @Test("CAP-RELAY-TOOL-01: after a toolCall negative cache is recorded the first leg carries no tools (production outbound gate evaluated per leg)")
    func CAP_RELAY_TOOL_01_negative_cache_drops_tools() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: try Self.metadataFixture())
        defer { Task { await MetadataClient.shared.resetForTesting() } }
        var model = AIModel(
            id: "relay-tool-model", name: "relay-tool-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .reachable
        let provider = Self.provider(RelayRequestedConfig(transport: .openaiChatCompletions), model: model)
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let memory = try makeToolLoopMemoryStore()

        // Whether the first leg carries tools is evaluated per leg by `permitsToolsOutbound` (the library and the tool loop share this gate).
        #expect(ToolCallCapabilityPolicy.permitsToolsOutbound(provider: provider, model: model, memory: memory),
                "Precondition: with toolCall unknown it fails open and the first leg carries tools")
        // Production write point: upstream rejects tools (400) before any output -> record a toolCall negative cache.
        RelayRejectionRecording.rememberToolCall(
            provider: provider, model: model, toolCall: false, reason: .toolsRejected4xx, statusCode: 400, sentTransport: .openaiChatCompletions, memory: memory
        )
        #expect(RelayNegativeCache.shared.isRejected(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.openaiChatCompletions.rawValue, kind: .toolCall
        ), "Precondition: the negative cache is recorded")
        #expect(!ToolCallCapabilityPolicy.permitsToolsOutbound(provider: provider, model: model, memory: memory),
                "After a toolCall negative cache is recorded the first leg carries no tools")
    }
}
