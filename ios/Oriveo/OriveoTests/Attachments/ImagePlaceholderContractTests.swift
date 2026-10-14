import Foundation
import Testing
@testable import Oriveo

// Routes that send text only write one placeholder line per image.
// The fixture `shared/test-fixtures/attachments/image-placeholder.v1.json` is the same bytes on all three platforms;
// each case asserts two things: the placeholder declared by the route is byte-identical to the fixture, and the production builder of that route,
// given "one image + one sentence", produces a request body that carries the placeholder line and no image block at all.

private final class PlaceholderCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var bodies: [Data] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { bodies = [] } }
    static func first() -> Data? { lock.withLock { bodies.first } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaceholderCaptureProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(request) ?? Data()
        Self.lock.withLock { Self.bodies.append(body) }
        // Lock only the request shape: the response is 200 + an empty stream, and a server-side decode failure is tolerable.
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://placeholder.invalid")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
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

@Suite("image-placeholder.v1（iOS）", .serialized)
struct ImagePlaceholderContractTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Routes: Decodable { let ios: String }
            let id: String
            let placeholder: String
            let routes: Routes
        }
        let v: Int
        let cases: [Case]
    }

    private static let imageBase64 = "SU1BR0UtQllURVMtTUFSS0VS"

    private static func fixtureCase(_ id: String) throws -> Fixture.Case {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("shared/test-fixtures/attachments/image-placeholder.v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.v == 1)
        #expect(fixture.cases.count == 5, "Fixture case count is locked to prevent silently skipped cases")
        return try #require(fixture.cases.first { $0.id == id })
    }

    /// Fixture `routes.ios` -> this platform's route enum.
    private static func transport(_ name: String) -> AttachmentTransport? {
        switch name {
        case "deepSeekChat": return .deepSeekChat
        case "relayLlamaCppNative": return .relayLlamaCppNative
        case "miniMaxChat": return .miniMaxChat
        case "miniMaxAnthropicWeb": return .miniMaxAnthropicWeb
        case "geminiInteractions": return .geminiInteractions
        default: return nil
        }
    }

    private static func message(_ kind: ProviderKind, model: String, text: String = "look") -> ChatMessage {
        var message = ChatMessage(
            id: UUID(), role: .user, text: text, providerKind: kind,
            providerName: kind.displayName, modelName: model, state: .delivered
        )
        message.attachments = [Attachment(
            id: UUID(), kind: .image, fileName: "photo.png", mimeType: "image/png", base64Data: imageBase64
        )]
        return message
    }

    /// The route's declaration == the fixture bytes; the request body contains the placeholder line and no image block or image bytes.
    private static func assertCase(_ id: String, body: Data?) throws {
        let item = try fixtureCase(id)
        let transport = try #require(transport(item.routes.ios), "Fixture route \(item.routes.ios) has no matching enum on iOS")
        #expect(transport.profile.imagePlaceholderText == item.placeholder, "\(id): the placeholder declared by the route does not match the fixture")
        let data = try #require(body, "\(id): the production builder sent no request")
        let text = String(decoding: data, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(Self.strings(in: object).contains { $0.contains(item.placeholder) }, "\(id): the request body has no placeholder line: \(text)")
        for marker in ["image_url", "inlineData", "inline_data", "input_image", #""type":"image""#, imageBase64] {
            #expect(!text.contains(marker), "\(id): the request body carries an image block \(marker)")
        }
    }

    nonisolated private static func strings(in value: Any) -> [String] {
        switch value {
        case let string as String: return [string]
        case let array as [Any]: return array.flatMap(strings(in:))
        case let object as [String: Any]: return object.values.flatMap(strings(in:))
        default: return []
        }
    }

    @Test("IMAGE_PLACEHOLDER_deepseek_chat：DeepSeek Chat route sends text only")
    func IMAGE_PLACEHOLDER_deepseek_chat() async throws {
        await MetadataClient.shared.resetForTesting()
        PlaceholderCaptureProtocol.reset()
        do {
            for try await _ in DeepSeekService(session: PlaceholderCaptureProtocol.session()).sendMessageStream(
                apiKey: "fixture-key", modelID: "deepseek-chat", messages: [Self.message(.deepseek, model: "deepseek-chat")]
            ) {}
        } catch {}
        try Self.assertCase("deepseek_chat", body: PlaceholderCaptureProtocol.first())
    }

    @Test("IMAGE_PLACEHOLDER_relay_llamacpp_native：Relay llama.cpp native route sends text only")
    func IMAGE_PLACEHOLDER_relay_llamacpp_native() async throws {
        await MetadataClient.shared.resetForTesting()
        PlaceholderCaptureProtocol.reset()
        // .invalid never resolves: if preflight cannot go through, build as usual, and the request is intercepted by this file's replay protocol.
        let requested = RelayRequestedConfig(transport: .llamacppNative)
        var failure: (any Error)?
        do {
            for try await _ in OpenAIService(session: PlaceholderCaptureProtocol.session()).sendMessageStream(
                apiKey: "fixture-key", modelID: "local-model",
                messages: [Self.message(.relay, model: "local-model")],
                baseURL: "https://llama.invalid",
                relayRequested: requested
            ) {}
        } catch { failure = error }
        #expect(PlaceholderCaptureProtocol.first() != nil, "llama.cpp sent no request:\(String(describing: failure))")
        try Self.assertCase("relay_llamacpp_native", body: PlaceholderCaptureProtocol.first())
    }

    @Test("IMAGE_PLACEHOLDER_minimax_chat：MiniMax Chat route sends text only")
    func IMAGE_PLACEHOLDER_minimax_chat() async throws {
        await MetadataClient.shared.resetForTesting()
        PlaceholderCaptureProtocol.reset()
        do {
            for try await _ in MiniMaxService(session: PlaceholderCaptureProtocol.session()).sendMessageStream(
                apiKey: "fixture-key", modelID: "MiniMax-M2", messages: [Self.message(.miniMax, model: "MiniMax-M2")],
                baseURL: nil, reasoningMode: .automatic, requestOptions: ChatRequestOptions()
            ) {}
        } catch {}
        try Self.assertCase("minimax_chat", body: PlaceholderCaptureProtocol.first())
    }

    @Test("IMAGE_PLACEHOLDER_minimax_web：MiniMax web search (Anthropic-compatible endpoint) route sends text only")
    func IMAGE_PLACEHOLDER_minimax_web() async throws {
        let modelID = "MiniMax-M3"
        try await Self.loadWebRouteMetadata(providerKind: "miniMax", modelID: modelID, transport: "openai_chat", recipeRef: "minimax.messages.web.v1")
        // Precondition: the web search route is chosen by the production selection function, not assumed by the test itself.
        #expect(MiniMaxService.exactAnthropicWebRecipe(modelID: modelID, requested: true) != nil)
        PlaceholderCaptureProtocol.reset()
        var options = ChatRequestOptions()
        options.capabilityPreferences = CapabilityPreferenceValues(web: .automatic)
        _ = try? await MiniMaxService(session: PlaceholderCaptureProtocol.session()).sendMessage(
            apiKey: "fixture-key", modelID: modelID, messages: [Self.message(.miniMax, model: modelID)],
            baseURL: nil, reasoningMode: .automatic, requestOptions: options
        )
        let body = PlaceholderCaptureProtocol.first()
        #expect(body.map { String(decoding: $0, as: UTF8.self).contains("web_search") } == true, "Precondition: the request really took the web search route")
        try Self.assertCase("minimax_web", body: body)
    }

    @Test("IMAGE_PLACEHOLDER_gemini_interactions：Gemini Interactions route sends text only")
    func IMAGE_PLACEHOLDER_gemini_interactions() async throws {
        let modelID = "gemini-3-flash"
        try await Self.loadWebRouteMetadata(providerKind: "gemini", modelID: modelID, transport: "gemini_interactions", recipeRef: "gemini.interactions.web.v1")
        let recipe = try #require(GeminiService.interactionsRecipe(modelID: modelID, webSearchEnabled: true, historyHasVideo: false))
        let request = try GeminiService().buildInteractionsRequest(
            modelID: modelID, messages: [Self.message(.gemini, model: modelID)],
            apiKey: "fixture-key", stream: false, recipe: recipe
        )
        try Self.assertCase("gemini_interactions", body: request.httpBody)
    }

    /// Web search route metadata: the recipe comes from the production registry (`CapabilityRuntimeFixtures`), not hand-copied in the test.
    private static func loadWebRouteMetadata(
        providerKind: String, modelID: String, transport: String, recipeRef: String
    ) async throws {
        let document: [String: Any] = [
            "version": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "providers": [providerKind: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": transport,
                    "capabilities": ["text", "web"],
                    "capabilityControls": CapabilityRuntimeFixtures.controls(
                        .init(capability: "web", recipeRef: recipeRef)
                    ),
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        )
    }
}
