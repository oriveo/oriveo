import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Captures the request bodies the relay send chain actually emits (each case only takes the first request).
private final class MaxTokensURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.capturedBody == nil, let body = Self.bodyObject(of: request) {
            Self.capturedBody = body
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
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

/// max_tokens = plan.budget.oWire; when the Anthropic thinking budget >= oWire, it equals budget + 4096.
/// The max_tokens cases all assert on request bodies the production send chain actually emits.
extension ContextPipelineTests {

    @Test func max_tokens_equals_o_wire() async throws {
        // W=16000, model maxOutputTokens=8192 -> O=8192 is capped at half of W, oWire=8000.
        let body = try await sendThroughAnthropicRelay(contextLength: 16_000, maxOutputTokens: 8_192)
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 8_000)
    }

    @Test func max_tokens_model_default_8192() async throws {
        let body = try await sendThroughAnthropicRelay(contextLength: 128_000, maxOutputTokens: nil)
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 8_192)
    }

    @Test func max_tokens_thinking_guard() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-15T00:00:00Z",
          "profiles": {
            "reasoning": {
              "context_pipeline_thinking": {
                "transport": "anthropic_messages",
                "levels": ["fast", "balanced"],
                "params": { "fast": {}, "balanced": {} }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "context-pipeline-thinking-etag")

        // W=16000, model 8192 -> oWire=8000. Thinking budget (balanced 8192) >= oWire -> budget + 4096.
        let balanced = try await sendThroughAnthropicRelay(
            contextLength: 16_000, maxOutputTokens: 8_192,
            reasoningProfile: "context_pipeline_thinking", reasoningMode: .balanced
        )
        let balancedBudget = try #require(
            ((balanced["thinking"] as? [String: Any])?["budget_tokens"] as? NSNumber)?.intValue,
            "request carried no thinking budget"
        )
        #expect(balancedBudget == 8_192)
        #expect((balanced["max_tokens"] as? NSNumber)?.intValue == 8_192 + 4_096)

        // Thinking budget (fast 2048) < oWire -> send oWire as is.
        let fast = try await sendThroughAnthropicRelay(
            contextLength: 16_000, maxOutputTokens: 8_192,
            reasoningProfile: "context_pipeline_thinking", reasoningMode: .fast
        )
        let fastBudget = try #require(
            ((fast["thinking"] as? [String: Any])?["budget_tokens"] as? NSNumber)?.intValue,
            "request carried no thinking budget"
        )
        #expect(fastBudget == 2_048)
        #expect((fast["max_tokens"] as? NSNumber)?.intValue == 8_000)
    }

    @Test func max_tokens_user_setting_wins() async throws {
        let body = try await sendThroughAnthropicRelay(
            contextLength: 128_000, maxOutputTokens: 8_192,
            connectionDefaults: ["max_output_tokens": .init(state: .value, value: .number(4_000))]
        )
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 4_000)
    }

    @Test func max_tokens_user_setting_budgeted() async throws {
        // User sets 4000, model 8192, W=16000: the user value becomes the budget's O (user > recipe > model), oWire = min(O, R) = 4000.
        var window: ContextWindowInput?
        var budget: ContextPlanBudget?
        let body = try await sendThroughAnthropicRelay(
            contextLength: 16_000, maxOutputTokens: 8_192,
            connectionDefaults: ["max_output_tokens": .init(state: .value, value: .number(4_000))],
            inspect: {
                window = $0.chatManager.debugLastContextWindowForTesting
                budget = $0.chatManager.debugLastContextBudgetForTesting
            }
        )
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 4_000)
        // plan.budget only carries oWire; O is derived from the window parameters the send chain actually hands to ContextAssembler.
        let assemblyWindow = try #require(window, "send pipeline assembled no context window")
        #expect(assemblyWindow.maxOutput.user == 4_000)
        #expect(ContextBudget.window(assemblyWindow).O == 4_000)
        let planBudget = try #require(budget, "send pipeline produced no plan budget")
        #expect(planBudget.oWire == 4_000)
    }

    @Test func max_tokens_responses_o_wire() async throws {
        // Responses relay: W=16000, model 8192 -> oWire=8000, and the request body's max_output_tokens uses it rather than the 16384 fallback.
        let body = try await sendThroughAnthropicRelay(
            contextLength: 16_000, maxOutputTokens: 8_192, transport: .openaiResponses
        )
        #expect((body["max_output_tokens"] as? NSNumber)?.intValue == 8_000)
    }

    // MARK: Fixtures

    private static let relayModelID = "relay-claude"

    private static func windowedModel(contextLength: Int?, maxOutputTokens: Int?) -> AIModel {
        var model = TestFactories.makeModel(id: relayModelID, capabilities: [.text], isDefault: true)
        model.contextLength = contextLength
        model.maxOutputTokens = maxOutputTokens
        return model
    }

    private func sendThroughAnthropicRelay(
        contextLength: Int?,
        maxOutputTokens: Int?,
        reasoningProfile: String? = nil,
        reasoningMode: ReasoningMode = .automatic,
        connectionDefaults: [String: GenerationParameterOverride] = [:],
        transport: RelayTransport = .anthropicMessages,
        inspect: ((AppState) -> Void)? = nil
    ) async throws -> [String: Any] {
        let providerID = UUID()
        var model = Self.windowedModel(contextLength: contextLength, maxOutputTokens: maxOutputTokens)
        if let reasoningProfile {
            model.reasoningModeAvailable = true
            model.reasoningProfile = reasoningProfile
        }
        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            connectionDefaults.isEmpty ? nil : GenerationParameterOverrides(values: connectionDefaults),
            providerID: providerID
        )
        defer { GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MaxTokensURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "context-pipeline-max-tokens-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .relay,
            modelID: Self.relayModelID,
            messages: []
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        MaxTokensURLProtocol.capturedBody = nil
        defer { MaxTokensURLProtocol.capturedBody = nil }
        _ = await state.sendMessage(
            "Hello",
            in: conversation.id,
            capabilitySelection: ChatCapabilitySelection(reasoningMode: reasoningMode, webSearchEnabled: false)
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while MaxTokensURLProtocol.capturedBody == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let body = try #require(MaxTokensURLProtocol.capturedBody, "send pipeline issued no request")
        try? await Task.sleep(nanoseconds: 300_000_000)
        inspect?(state)
        return body
    }
}
