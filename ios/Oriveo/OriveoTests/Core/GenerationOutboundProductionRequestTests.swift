import Foundation
import Testing
@testable import Oriveo

final class GenerationOutboundCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        let url: URL
        let body: [String: Any]
    }

    nonisolated(unsafe) static var captured: Captured?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://relay.invalid")!
        if Self.captured == nil, request.httpMethod == "POST", let body = Self.bodyObject(of: request) {
            Self.captured = .init(url: url, body: body)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyObject(of request: URLRequest) -> [String: Any]? {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { pointer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(pointer, maxLength: 4_096)
                if count <= 0 { break }
                buffer.append(pointer, count: count)
            }
            data = buffer
        } else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// End-to-end check of what goes out on the wire: every assertion reads the **URLRequest the
/// production send path actually produced** (AppState → ChatManager → service builder →
/// URLSession), never an intermediate value or a hand-written profile.
@Suite("generation outbound production requests", .serialized)
@MainActor
struct GenerationOutboundProductionRequestTests {

    @Test("an out-of-range item drops only itself, and omit never removes the max_tokens Anthropic requires")
    func relayAnthropicKeepsRequiredFieldAndDropsOnlyInvalidItem() async throws {
        let captured = try await Self.send(
            transport: .anthropicMessages,
            baseURL: "https://relay.test/v1",
            connectionDefaults: [
                "max_output_tokens": .init(state: .omit),
                "top_p": .init(state: .value, value: .number(5)),
                "top_k": .init(state: .value, value: .number(40)),
                "stop": .init(state: .value, value: .stringList(["END"])),
            ]
        )
        #expect(captured.url.path.hasSuffix("/messages"))
        let maxTokens = try #require((captured.body["max_tokens"] as? NSNumber)?.intValue, "the required max_tokens was removed")
        #expect(maxTokens > 0)
        #expect(captured.body["top_p"] == nil, "an out-of-range value was sent")
        #expect((captured.body["top_k"] as? NSNumber)?.intValue == 40, "a valid parameter in the same request was dropped along with it")
        #expect(captured.body["stop_sequences"] as? [String] == ["END"])
    }

    @Test("custom Anthropic endpoint with thinking on: temperature and top_k are not sent, and max_tokens returns to the default when it does not exceed the budget")
    func relayAnthropicThinkingGuardRunsInTheBuilder() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-06T00:00:00Z",
          "profiles": {
            "reasoning": {
              "relay_thinking_guard_test": {
                "transport": "anthropic_messages",
                "levels": ["deep"],
                "params": { "deep": {} }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-thinking-guard-etag")
        let captured = try await Self.send(
            transport: .anthropicMessages,
            baseURL: "https://relay.test/v1",
            connectionDefaults: [
                "temperature": .init(state: .value, value: .number(0.3)),
                "top_k": .init(state: .value, value: .number(40)),
                "max_output_tokens": .init(state: .value, value: .number(4_000)),
                "stop": .init(state: .value, value: .stringList(["END"])),
            ],
            reasoningProfile: "relay_thinking_guard_test",
            reasoningMode: .deep
        )
        await MetadataClient.shared.resetForTesting()

        // Premise: this request really carries the thinking fields, or the assertions below test nothing.
        let thinking = try #require(captured.body["thinking"] as? [String: Any], "the request has no thinking field")
        let budget = try #require((thinking["budget_tokens"] as? NSNumber)?.intValue)
        #expect(captured.body["temperature"] == nil)
        #expect(captured.body["top_k"] == nil)
        #expect(captured.body["stop_sequences"] as? [String] == ["END"], "a parameter unrelated to thinking was dropped along with the others")
        let maxTokens = try #require((captured.body["max_tokens"] as? NSNumber)?.intValue)
        #expect(maxTokens > budget, "max_tokens (\(maxTokens)) does not exceed the thinking budget (\(budget))")
        #expect(maxTokens != 4_000)
    }

    // MARK: - Fixture

    static func send(
        transport: RelayTransport,
        baseURL: String,
        engineProfile: String? = nil,
        resolvedAPIBaseURL: String? = nil,
        connectionDefaults: [String: GenerationParameterOverride],
        reasoningProfile: String? = nil,
        reasoningMode: ReasoningMode = .automatic
    ) async throws -> GenerationOutboundCaptureURLProtocol.Captured {
        GenerationOutboundCaptureURLProtocol.captured = nil
        let providerID = UUID()
        defer {
            GenerationOutboundCaptureURLProtocol.captured = nil
            GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID)
        }

        var model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        if let reasoningProfile {
            model.reasoningModeAvailable = true
            model.reasoningProfile = reasoningProfile
        }
        var requested = RelayRequestedConfig(transport: transport)
        requested.engineProfile = engineProfile
        requested.resolvedAPIBaseURL = resolvedAPIBaseURL
        let provider = Provider(
            id: providerID, kind: .relay, status: .connected,
            models: [model], catalogModels: [],
            apiKey: "relay-key", apiKeyPreview: "...key",
            baseURLText: baseURL, relayRequested: requested
        )
        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: connectionDefaults), providerID: providerID
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationOutboundCaptureURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "generation-outbound-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID, providerKind: .relay, modelID: "relay-model"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage(
            "Hello",
            in: conversation.id,
            capabilitySelection: ChatCapabilitySelection(reasoningMode: reasoningMode, webSearchEnabled: false)
        )

        let deadline = ContinuousClock.now + .seconds(5)
        while GenerationOutboundCaptureURLProtocol.captured == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let captured = try #require(GenerationOutboundCaptureURLProtocol.captured, "the send path produced no request")
        try? await Task.sleep(nanoseconds: 300_000_000)
        return captured
    }
}
