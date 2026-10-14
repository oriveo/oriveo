import Foundation
import Testing
@testable import Oriveo

// Capability matrix - the four subscription cells.
// Connections are always built from `shared/test-fixtures/provider-catalog/subscription-models.v1.json`
// through the production subscription catalog decoding and mapping (`GrokSubscriptionOAuthClient` / `OpenAISubscriptionOAuthClient`
// `.parseModelDescriptors` -> `ProviderManager.*SubscriptionModels`); expectations come from the `expected` section of the same fixture.
// Shape assertions go through the production ruling -> presentation -> shape function; outbound assertions land on the request bodies actually sent by the production builder / send chain.

/// Replays the subscription upstream from a script and records every request body. Used only by this file; shares no process-level state with other suites.
private final class SubscriptionMatrixProtocol: URLProtocol, @unchecked Sendable {
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
        config.protocolClasses = [SubscriptionMatrixProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.bodyData(request)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let next: (status: Int, body: Data) = Self.lock.withLock {
            Self.bodies.append(object)
            return Self.script.isEmpty ? (200, Data(okStream.utf8)) : Self.script.removeFirst()
        }
        let contentType = next.status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://subscription.invalid")!, statusCode: next.status,
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

/// Both subscription links are Responses streams: one text segment + completed.
private let okStream = """
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"ok"}

event: response.completed
data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":2,"output_tokens":1}}}


"""

/// Native file block rejected before any output (the 400 in the fallback set).
private let fileRejection = #"{"error":{"message":"input_file is not supported for this model","type":"invalid_request_error"}}"#

@Suite("Capability matrix - subscription (CAP-SUB)", .serialized)
struct CapabilityMatrixSubscriptionTests {
    private typealias Shape = ModelOptionCapabilityShape

    private static let grokModelID = "grok-4.6"
    private static let grokChatModelID = "grok-4.6-chat"
    private static let codexModelID = "gpt-5.6-sol"

    // MARK: - Fixtures (upstream /models -> production decoding and mapping)

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixture() throws -> [String: Any] {
        let url = try repoFile(["shared", "test-fixtures", "provider-catalog", "subscription-models.v1.json"])
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func upstreamBody(_ key: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try #require(try fixture()[key], "fixture is missing \(key)"))
    }

    private static func expected(_ modelID: String) throws -> [String: Any] {
        let all = try #require(try fixture()["expected"] as? [String: Any])
        return try #require(all[modelID] as? [String: Any], "fixture expected is missing \(modelID)")
    }

    private static func subscriptionProvider(kind: ProviderKind, models: [AIModel]) -> Provider {
        var provider = TestFactories.makeProvider(kind: kind, models: models)
        provider.authMode = .subscription
        return provider
    }

    @MainActor
    private static func grokProvider() throws -> Provider {
        let descriptors = try GrokSubscriptionOAuthClient.parseModelDescriptors(from: try upstreamBody("grok_models"))
        return subscriptionProvider(kind: .grok, models: ProviderManager.grokSubscriptionModels(from: descriptors))
    }

    @MainActor
    private static func codexProvider() throws -> Provider {
        let descriptors = try OpenAISubscriptionOAuthClient.parseModelDescriptors(from: try upstreamBody("codex_models"))
        return subscriptionProvider(kind: .openAI, models: ProviderManager.codexSubscriptionModels(from: descriptors))
    }

    private static func model(_ id: String, in provider: Provider) throws -> AIModel {
        try #require(provider.models.first { $0.id == id }, "subscription catalog has no \(id)")
    }

    // MARK: - Ruling / presentation

    /// Compares the production ruling + presentation with the fixture `expected.<id>.web` key by key. Presentation is compared by enum case name (that is what the fixture holds).
    private static func expectWebVerdict(provider: Provider, model: AIModel) throws {
        let expected = try #require(try Self.expected(model.id)["web"] as? [String: Any])
        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web")
        #expect(verdict.state.rawValue == expected["state"] as? String, "\(model.id)")
        #expect(verdict.reasonCode == expected["reasonCode"] as? String, "\(model.id)")
        if let intents = expected["intents"] as? [String] {
            #expect(verdict.intents == intents, "\(model.id)")
        }
        if let presentation = expected["presentation"] as? String {
            let actual = CapabilityControlPresentationResolver.presentation(
                provider: provider, model: model, capability: "web"
            )
            #expect("\(actual)" == presentation, "\(model.id)")
        }
    }

    private static func expectTransport(provider: Provider, model: AIModel) throws {
        #expect(
            CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
                == (try Self.expected(model.id)["transport"] as? String),
            "\(model.id)"
        )
    }

    /// Same value path as the panel: presentation comes from the production resolver, levels from the production ruling, and the selection is the value the user stored.
    @MainActor
    private static func webRow(provider: Provider, model: AIModel, selectedIntent: String) -> Shape {
        Shape.resolve(.init(
            capability: .web,
            presentation: CapabilityControlPresentationResolver.presentation(
                provider: provider, model: model, capability: "web"
            ),
            availableIntents: CapabilityControlResolution.resolve(
                provider: provider, model: model, capability: "web"
            ).intents,
            selectedIntent: selectedIntent
        ))
    }

    // MARK: - Outbound: Codex (OpenAIService subscription Responses builder)

    private static func codexOptions(model: AIModel, selection: ChatCapabilitySelection) -> ChatRequestOptions {
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.capabilityPreferences = selection.typedPreferences
        options.openAISubscription = OpenAISubscriptionRequestContext(
            responsesURL: URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
            accountID: "acct-cap-sub",
            requiredHeaders: ["originator": "oriveo"]
        )
        return options
    }

    private static func userMessage(_ text: String, kind: ProviderKind, modelID: String, attachments: [Oriveo.Attachment]? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .user, text: text, providerKind: kind, providerName: kind.displayName,
            modelID: modelID, modelName: modelID, state: .delivered, attachments: attachments
        )
    }

    private static func sendCodex(model: AIModel, selection: ChatCapabilitySelection) async throws -> [String: Any] {
        SubscriptionMatrixProtocol.reset([(200, okStream)])
        let stream = OpenAIService(session: SubscriptionMatrixProtocol.session()).sendMessageStream(
            apiKey: "codex-token", modelID: model.id,
            messages: [userMessage("\u{4ECA}\u{5929}\u{6709}\u{4EC0}\u{4E48}\u{65B0}\u{95FB}", kind: .openAI, modelID: model.id)],
            reasoningMode: selection.reasoningMode, webSearchEnabled: selection.webSearchEnabled,
            requestOptions: codexOptions(model: model, selection: selection)
        )
        for try await _ in stream {}
        let bodies = SubscriptionMatrixProtocol.recorded()
        #expect(bodies.count == 1, "Codex subscription sends exactly one request")
        return try #require(bodies.first, "Codex subscription sent no request")
    }

    private static func toolTypes(_ body: [String: Any]) -> [String] {
        ((body["tools"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String }
    }

    private static func effort(_ body: [String: Any]) -> String? {
        (body["reasoning"] as? [String: Any])?["effort"] as? String
    }

    // MARK: - Outbound: Grok (send orchestration / GrokService subscription Responses builder)

    private static let resourceBase = "https://cli-chat-proxy.grok.com/v1"

    private static func grokContext(provider: Provider, model: AIModel) throws -> GrokSubscriptionRequestContext {
        GrokSubscriptionRequestContext(
            chatURL: try #require(URL(string: "\(resourceBase)/chat/completions")),
            responsesURL: URL(string: "\(resourceBase)/responses"),
            requiredHeaders: ["x-grok-client-version": "1.0.4"],
            transport: try #require(CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model))
        )
    }

    private struct Harness {
        let state: AppState
        let provider: Provider
        let model: AIModel
        let conversationID: UUID
        let uid: String
    }

    /// A Grok subscription connection + one active library source; only "credential preparation" (truth lives in the Keychain, which the test host cannot access)
    /// is replaced by an injected outbound context; routing, builder and HTTP are all production implementations, with HTTP going into the replay session.
    @MainActor
    private static func grokHarness() throws -> Harness {
        let uid = "cap-sub-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: true, providerSession: SubscriptionMatrixProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore()
        )
        let provider = try Self.grokProvider()
        let model = try Self.model(Self.grokModelID, in: provider)
        let context = try Self.grokContext(provider: provider, model: model)
        state.chatManager.grokSubscriptionPreparer = { _ in
            .success(.init(accessToken: "grok-subscription-token", context: context, didRefresh: false))
        }
        let conversationID = UUID()
        state.providers = [provider]
        state.conversations = [TestFactories.makeConversation(
            id: conversationID, providerID: provider.id, providerKind: .grok, modelID: model.id, messages: []
        )]
        return Harness(state: state, provider: provider, model: model, conversationID: conversationID, uid: uid)
    }

    @MainActor
    private static func tearDown(_ harness: Harness) {
        try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: harness.uid))
    }

    /// Sends one message starting at `sendMessage`, waits for the assistant message to leave the generating state, and returns the first request body the upstream received.
    @MainActor
    private static func sendGrok(_ harness: Harness, selection: ChatCapabilitySelection) async throws -> [String: Any] {
        await MetadataClient.shared.resetForTesting()
        SubscriptionMatrixProtocol.reset([(200, okStream), (200, okStream), (200, okStream)])
        let before = harness.state.conversation(for: harness.conversationID)?.messages.count ?? 0
        let sent = await harness.state.chatManager.sendMessage(
            "\u{67E5}\u{4E00}\u{4E0B}\u{65B9}\u{6848}", in: harness.conversationID, capabilitySelection: selection
        )
        #expect(sent != nil, "precondition: the send was not blocked by the gate")
        for _ in 0..<200 {
            let messages = harness.state.conversation(for: harness.conversationID)?.messages ?? []
            let assistant = messages.count > before ? messages.last(where: { $0.role == .assistant }) : nil
            if let assistant, assistant.state != .generating { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return try #require(SubscriptionMatrixProtocol.recorded().first, "Grok subscription sent no request")
    }

    /// Explicitly sets the native-file allowlist on the model in tests (the production Grok catalog does not send it; this is not a hand-made catalog).
    /// PDF going native also needs `pdfNativeDefault` (`AttachmentRouter`: a PDF with extracted text goes native only when it is true),
    /// and the fallback in ATTACH-02 requires the rejected native file to have extracted text, so both are set together.
    private static func withNativePDF(_ model: AIModel) -> AIModel {
        var model = model
        model.nativeFileMimes = ["application/pdf"]
        model.pdfNativeDefault = true
        return model
    }

    private static func textPdf() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
    }

    /// Goes straight through the GrokService subscription Responses entry (streaming), with the attachment on this turn's user message.
    private static func streamGrokWithPDF(
        provider: Provider, model: AIModel, connectionID: UUID
    ) async throws -> String {
        var options = ChatRequestOptions()
        options.capabilityEvidenceModel = model
        options.attachmentConnectionID = connectionID
        options.grokSubscription = try grokContext(provider: provider, model: model)
        let stream = GrokService(session: SubscriptionMatrixProtocol.session()).sendMessageStream(
            apiKey: "grok-subscription-token", modelID: model.id,
            messages: [userMessage("summarize", kind: .grok, modelID: model.id, attachments: [textPdf()])],
            reasoningMode: .automatic, webSearchEnabled: false, requestOptions: options
        )
        var text = ""
        for try await event in stream {
            if case let .delta(chunk) = event { text += chunk }
        }
        return text
    }

    private static func userContentParts(_ body: [String: Any]) -> [[String: Any]] {
        let input = (body["input"] as? [[String: Any]]) ?? []
        return input.filter { $0["role"] as? String == "user" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
    }

    private static func partTypes(_ body: [String: Any]) -> [String] {
        userContentParts(body).compactMap { $0["type"] as? String }
    }

    // MARK: - Web search

    @Test("CAP-SUB-WEB-01: gpt-5.6-sol web search is a toggle; preference off -> no web_search outbound, on -> present")
    @MainActor
    func CAP_SUB_WEB_01_codex_web_follows_preference() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = try Self.codexProvider()
        let model = try Self.model(Self.codexModelID, in: provider)
        try Self.expectTransport(provider: provider, model: model)
        try Self.expectWebVerdict(provider: provider, model: model)
        guard case .toggle = Self.webRow(provider: provider, model: model, selectedIntent: "off") else {
            Issue.record("Codex subscription web search should still be a toggle")
            return
        }
        #expect(try Self.expected(model.id)["outboundToolsWithWebPreferenceOff"] is NSNull)

        let off = try await Self.sendCodex(model: model, selection: .init(reasoningMode: .automatic, webSearchEnabled: false))
        #expect(!Self.toolTypes(off).contains("web_search"), "preference off must not carry web_search: \(off)")
        let on = try await Self.sendCodex(model: model, selection: .init(reasoningMode: .automatic, webSearchEnabled: true))
        #expect(Self.toolTypes(on).contains("web_search"), "preference on should carry web_search: \(on)")
    }

    @Test("CAP-SUB-WEB-02: grok-4.6 web search -> alwaysOn -> notice(Always on, ..., nil); preference off -> outbound tools still contain web_search")
    @MainActor
    func CAP_SUB_WEB_02_grok_web_always_on() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = try Self.grokProvider()
        let model = try Self.model(Self.grokModelID, in: provider)
        let expected = try Self.expected(model.id)
        try Self.expectTransport(provider: provider, model: model)
        try Self.expectWebVerdict(provider: provider, model: model)

        let row = try #require(expected["webRow"] as? [String: Any])
        #expect(row["shape"] as? String == "notice")
        #expect(row["link"] is NSNull)
        let status = try #require(row["status"] as? String)
        let body = try #require(row["body"] as? String)
        #expect(
            Self.webRow(provider: provider, model: model, selectedIntent: "off")
                == .notice(.init(status: L10n.tr(status, table: .chat), body: L10n.tr(body, table: .chat), link: nil))
        )

        // The same-named model on the Chat backend is still "this model cannot search the web" (unchanged).
        let chatModel = try Self.model(Self.grokChatModelID, in: provider)
        try Self.expectTransport(provider: provider, model: chatModel)
        try Self.expectWebVerdict(provider: provider, model: chatModel)

        let harness = try Self.grokHarness()
        defer { Self.tearDown(harness) }
        let sent = try await Self.sendGrok(harness, selection: .init(reasoningMode: .automatic, webSearchEnabled: false))
        let tools = try #require(expected["outboundToolsWithWebPreferenceOff"] as? [[String: Any]])
        let toolList = (sent["tools"] as? [[String: Any]]) ?? []
        for tool in tools {
            #expect(toolList.contains { $0["type"] as? String == tool["type"] as? String }, "\(sent)")
        }
        // Automatic reasoning sends only the default level declared by upstream.
        #expect(Self.effort(sent) == expected["automaticEffort"] as? String, "\(sent)")
    }

    @Test("Always-on web search for Grok subscriptions is not a stored user web preference: liveness is false, and neither the composer globe nor explicitKeys lights up for it")
    @MainActor
    func alwaysOnIsNotALiveWebPreference() async throws {
        await MetadataClient.shared.resetForTesting()
        #expect(!CapabilityWebPreferenceLiveness.reachesTheWire(status: .alwaysOn, customIsActive: false))
        let provider = try Self.grokProvider()
        let model = try Self.model(Self.grokModelID, in: provider)
        #expect(!CapabilityWebPreferenceLiveness.reachesTheWire(
            provider: provider, model: model, conversationID: UUID()
        ))
    }

    @Test("SUB-WEB-grok_always_on_does_not_light_composer_globe: always-on does not light the composer globe, while toggleable Codex web search lights it as usual")
    @MainActor
    func grokAlwaysOnDoesNotLightComposerGlobe() async throws {
        await MetadataClient.shared.resetForTesting()
        let grok = try Self.grokProvider()
        let grokModel = try Self.model(Self.grokModelID, in: grok)
        let grokPermitted = CapabilityWebPreferenceLiveness.composerWebPermitted(
            outboundPermitted: true, provider: grok, model: grokModel
        )
        #expect(!grokPermitted)
        let grokDecision = ChatCapabilityOutboundDecision.resolve(
            webRequested: true, webPermitted: grokPermitted,
            reasoningModeRequested: .automatic, reasoningModePermitted: true,
            reasoningIntentRequested: nil, reasoningIntentPermitted: false
        )
        #expect(!grokDecision.activeCapabilityGlyphs.contains("globe"))

        let codex = try Self.codexProvider()
        let codexModel = try Self.model(Self.codexModelID, in: codex)
        #expect(CapabilityWebPreferenceLiveness.composerWebPermitted(
            outboundPermitted: true, provider: codex, model: codexModel
        ))
    }

    // MARK: - Reasoning

    @Test("CAP-SUB-REASON-01: gpt-5.6-sol levels == [low,balanced,deep,max], balanced -> medium, max -> xhigh")
    @MainActor
    func CAP_SUB_REASON_01_codex_intents_map_to_effort() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = try Self.codexProvider()
        let model = try Self.model(Self.codexModelID, in: provider)
        let expected = try Self.expected(model.id)
        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
        #expect(verdict.intents == expected["reasoningIntents"] as? [String])

        let mapping = try #require(expected["effortForIntent"] as? [String: String])
        for intent in verdict.intents {
            let mode = try #require(ReasoningMode.fromIntent(intent), "\(intent)")
            let body = try await Self.sendCodex(model: model, selection: .init(reasoningMode: mode, webSearchEnabled: false))
            #expect(Self.effort(body) == mapping[intent], "\(intent)：\(body)")
        }
        #expect(mapping["balanced"] == "medium" && mapping["max"] == "xhigh")
    }

    @Test("CAP-SUB-REASON-02: gpt-5.6-sol automatic -> no reasoning.effort outbound")
    @MainActor
    func CAP_SUB_REASON_02_codex_automatic_sends_no_effort() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = try Self.codexProvider()
        let model = try Self.model(Self.codexModelID, in: provider)
        #expect(try Self.expected(model.id)["automaticEffort"] is NSNull)
        let body = try await Self.sendCodex(model: model, selection: .init(reasoningMode: .automatic, webSearchEnabled: false))
        #expect(Self.effort(body) == nil, "\(body)")
    }

    // MARK: - Attachments

    @Test("CAP-SUB-ATTACH-01: Grok subscription Responses line = input_file + alwaysWithTextFallback; allowlist contains PDF -> outbound contains input_file")
    @MainActor
    func CAP_SUB_ATTACH_01_grok_sends_input_file() async throws {
        await MetadataClient.shared.resetForTesting()
        NativeFileFallback.resetMemoryForTesting()
        let provider = try Self.grokProvider()
        let model = Self.withNativePDF(try Self.model(Self.grokModelID, in: provider))
        let line = try #require(try Self.expected(model.id)["fileLine"] as? [String: Any])

        let transport = try #require(AttachmentTransportResolver.resolve(
            provider: provider, model: model,
            request: .init(webSearchEnabled: false, webPreferenceIsAutomatic: false)
        ))
        #expect(transport == .grokSubscription)
        #expect("\(transport.profile.effectiveNativeFiles)" == line["nativeFiles"] as? String)

        SubscriptionMatrixProtocol.reset([(200, okStream)])
        _ = try await Self.streamGrokWithPDF(provider: provider, model: model, connectionID: UUID())
        let bodies = SubscriptionMatrixProtocol.recorded()
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        let block = try #require(line["nativeFileBlock"] as? String)
        #expect(Self.partTypes(body).contains(block), "\(body)")
        let file = try #require(Self.userContentParts(body).first { $0["type"] as? String == block })
        #expect(file["file_data"] as? String == "data:application/pdf;base64,JVBERi0xLjQ=")
        #expect(file["filename"] as? String == "report.pdf")
    }

    @Test("CAP-SUB-ATTACH-02: Grok subscription native file block rejected with a pre-output 400 -> resend once as text; the second request has no input_file, carries the injected text, and succeeds")
    @MainActor
    func CAP_SUB_ATTACH_02_grok_falls_back_to_text() async throws {
        await MetadataClient.shared.resetForTesting()
        NativeFileFallback.resetMemoryForTesting()
        defer { NativeFileFallback.resetMemoryForTesting() }
        let provider = try Self.grokProvider()
        let model = Self.withNativePDF(try Self.model(Self.grokModelID, in: provider))

        SubscriptionMatrixProtocol.reset([(400, fileRejection), (200, okStream)])
        let text = try await Self.streamGrokWithPDF(provider: provider, model: model, connectionID: UUID())
        #expect(text == "ok", "the fallback resend should succeed")
        let bodies = SubscriptionMatrixProtocol.recorded()
        #expect(bodies.count == 2, "resent exactly once")
        let first = try #require(bodies.first)
        let second = try #require(bodies.last)
        #expect(Self.partTypes(first).contains("input_file"), "first request carries the native file block: \(first)")
        #expect(!Self.partTypes(second).contains("input_file"), "resend carries no native file block: \(second)")
        let injected = Self.userContentParts(second)
            .filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .joined()
        #expect(injected.contains("EXTRACTED-PDF-BODY"), "resend injects the extracted text into the body: \(second)")
    }
}
