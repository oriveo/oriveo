import Foundation
import Testing
@testable import Oriveo

private final class RelayGenerationProfileURLProtocol: URLProtocol, @unchecked Sendable {
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

private func relayGenerationProfileSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RelayGenerationProfileURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("ChatManager relay generation profile", .serialized)
@MainActor
struct ChatManagerRelayGenerationProfileTests {

    @Test("Relay Send Resolves Generation Profile From Connection")
    func relaySendResolvesGenerationProfileFromConnection() async throws {
        RelayGenerationProfileURLProtocol.capturedBody = nil
        let providerID = UUID()
        defer {
            RelayGenerationProfileURLProtocol.capturedBody = nil
            GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID)
        }

        let model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        #expect(model.generationProfile == nil)

        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )

        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: [
                "temperature": GenerationParameterOverride(state: .value, value: .number(0.31)),
                "max_output_tokens": GenerationParameterOverride(state: .value, value: .number(512)),
            ]),
            providerID: providerID
        )

        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-generation-\(UUID().uuidString)",
            providerSession: relayGenerationProfileSession()
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .relay,
            modelID: "relay-model"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage("Hello", in: conversation.id)

        let deadline = ContinuousClock.now + .seconds(5)
        while RelayGenerationProfileURLProtocol.capturedBody == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let body = try #require(
            RelayGenerationProfileURLProtocol.capturedBody,
            "relay send chain never issued a request"
        )
        #expect(body["temperature"] as? Double == 0.31)
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 512)
        #expect(body["max_output_tokens"] == nil)

        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test("Connection Reasoning Default Reaches The Wire")
    func connectionReasoningDefaultReachesTheWire() async throws {
        let body = try await Self.sendWithConnectionReasoning(reasoningMode: .automatic)
        #expect(body["reasoning_effort"] as? String == "low")
        #expect(body["temperature"] as? Double == 0.31)
    }

    @Test("Explicit Chip Yields Over Connection Default")
    func explicitChipYieldsOverConnectionDefault() async throws {
        let body = try await Self.sendWithConnectionReasoning(reasoningMode: .deep)
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["temperature"] as? Double == 0.31)
    }

    private static func sendWithConnectionReasoning(
        reasoningMode: ReasoningMode
    ) async throws -> [String: Any] {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-08-09T00:00:00Z",
          "profiles": {
            "reasoning": {
              "relay_reasoning_test": {
                "transport": "openai_chat",
                "levels": ["deep"],
                "params": { "deep": { "reasoning_effort": "high" } }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {}
        }
        """, metadataETag: "relay-reasoning-test-etag")
        RelayGenerationProfileURLProtocol.capturedBody = nil
        let providerID = UUID()
        defer {
            RelayGenerationProfileURLProtocol.capturedBody = nil
            GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID)
        }

        var model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        model.reasoningModeAvailable = true
        model.reasoningProfile = "relay_reasoning_test"

        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )

        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: [
                "reasoning_effort": GenerationParameterOverride(state: .value, value: .string("low")),
                "temperature": GenerationParameterOverride(state: .value, value: .number(0.31)),
            ]),
            providerID: providerID
        )

        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-reasoning-\(UUID().uuidString)",
            providerSession: relayGenerationProfileSession()
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .relay,
            modelID: "relay-model"
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage(
            "Hello",
            in: conversation.id,
            capabilitySelection: ChatCapabilitySelection(
                reasoningMode: reasoningMode,
                webSearchEnabled: false
            )
        )

        let deadline = ContinuousClock.now + .seconds(5)
        while RelayGenerationProfileURLProtocol.capturedBody == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let body = try #require(RelayGenerationProfileURLProtocol.capturedBody, "relay send chain never issued a request")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MetadataClient.shared.resetForTesting()
        return body
    }
}
