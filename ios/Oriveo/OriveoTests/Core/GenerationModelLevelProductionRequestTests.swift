import Foundation
import Testing
@testable import Oriveo

/// End-to-end coverage for model-level parameter facts. Every assertion is made on the
/// `URLRequest` the production send path really emits (AppState → ChatManager → provider service
/// builder → URLSession). The metadata is catalog-shaped JSON parsed by the production
/// `MetadataClient`, and the values are read back through the production settings store.
@Suite("generation model-level production requests", .serialized)
@MainActor
struct GenerationModelLevelProductionRequestTests {
    private static let schema: GenerationParameterValue = .object([
        "type": .string("object"),
        "properties": .object(["answer": .object(["type": .string("string")])]),
        "required": .stringList(["answer"]),
    ])

    @Test("Anthropic: the JSON schema goes to output_config.format without name / strict, and no top-level output_format")
    func anthropicStructuredOutputGoesToOutputConfigFormat() async throws {
        let body = try await Self.send(
            providerKind: .anthropic, providerKey: "anthropic", modelTransport: "anthropic_messages",
            template: "anthropic_messages", recipeRef: "anthropic.messages.generation.v1",
            templateWire: ["max_output_tokens": "max_tokens", "json_schema": "output_config.format"],
            modelParameters: [
                ["id": "max_output_tokens", "support": "supported", "source": "authoritative_metadata"],
                ["id": "json_schema", "support": "supported", "source": "provider_metadata"],
            ],
            defaults: ["json_schema": .init(state: .value, value: Self.schema)]
        )
        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any], "request body keys: \(body.keys.sorted())")
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["required"] as? [String] == ["answer"])
        #expect(Set(format.keys) == ["type", "schema"], "format should hold only type and schema: \(format.keys.sorted())")
        #expect(body["output_format"] == nil, "the deprecated top-level output_format is still in the request body")
        #expect((body["max_tokens"] as? NSNumber)?.intValue ?? 0 > 0)
    }

    @Test("OpenAI Chat: a model-level wire writes max tokens to max_completion_tokens without max_tokens, and strict=true writes strict")
    func openAIChatUsesModelLevelWireAndStrict() async throws {
        let body = try await Self.send(
            providerKind: .openAI, providerKey: "openAI", modelTransport: "openai_chat",
            template: "openai_chat_completions", recipeRef: "openai.chat.generation.v1",
            templateWire: ["max_output_tokens": "max_tokens", "json_schema": "response_format"],
            modelParameters: [
                ["id": "max_output_tokens", "support": "supported", "source": "authoritative_metadata", "wire": "max_completion_tokens"],
                ["id": "json_schema", "support": "supported", "source": "provider_metadata", "strict": true],
            ],
            defaults: [
                "max_output_tokens": .init(state: .value, value: .number(2_048)),
                "json_schema": .init(state: .value, value: Self.schema),
            ]
        )
        #expect((body["max_completion_tokens"] as? NSNumber)?.intValue == 2_048)
        #expect(body["max_tokens"] == nil, "only one of the two names may be sent")
        let named = try #require((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        #expect(named["strict"] as? Bool == true)
        #expect(named["name"] as? String == "oriveo_response")
    }

    @Test("OpenAI Chat: without a model-level wire or strict, max_tokens is written and structured output has no strict key")
    func openAIChatWithoutModelLevelFieldsKeepsDefaults() async throws {
        let body = try await Self.send(
            providerKind: .openAI, providerKey: "openAI", modelTransport: "openai_chat",
            template: "openai_chat_completions", recipeRef: "openai.chat.generation.v1",
            templateWire: ["max_output_tokens": "max_tokens", "json_schema": "response_format"],
            modelParameters: [
                ["id": "max_output_tokens", "support": "supported", "source": "authoritative_metadata"],
                ["id": "json_schema", "support": "supported", "source": "provider_metadata"],
            ],
            defaults: [
                "max_output_tokens": .init(state: .value, value: .number(2_048)),
                "json_schema": .init(state: .value, value: Self.schema),
            ]
        )
        #expect((body["max_tokens"] as? NSNumber)?.intValue == 2_048)
        #expect(body["max_completion_tokens"] == nil)
        let named = try #require((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        #expect(named["strict"] == nil, "a model that does not declare strict should not carry the key")
        #expect(named["schema"] != nil)
    }

    // MARK: - Fixture

    private static let modelID = "fixture-model-level"

    private static func send(
        providerKind: ProviderKind, providerKey: String, modelTransport: String,
        template: String, recipeRef: String, templateWire: [String: String],
        modelParameters: [[String: Any]],
        defaults: [String: GenerationParameterOverride]
    ) async throws -> [String: Any] {
        let document: [String: Any] = [
            "version": 1,
            "contractVersion": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "profiles": ["generation": [
                "version": 1,
                "parameters": [
                    "max_output_tokens": ["group": "budget", "valueSchema": "integer", "range": ["min": 1, "step": 1]],
                    "json_schema": [
                        "group": "output_contract", "valueSchema": "json-schema",
                        "conflictsWith": ["tools", "response_format"],
                    ],
                ],
                "templates": [template: ["transport": template, "wire": templateWire]],
            ]],
            "providers": [providerKey: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": modelTransport,
                    "supportsTemperature": true,
                    "capabilityControls": CapabilityRuntimeFixtures.controls(
                        .init(capability: "generation", recipeRef: recipeRef)
                    ),
                    "profiles": ["generation": [
                        "template": template,
                        "revision": "model-level-production-v1",
                        "parameters": modelParameters,
                    ]],
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self),
            metadataETag: "model-level-production-etag"
        )
        GenerationOutboundCaptureURLProtocol.captured = nil
        let providerID = UUID()
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.canonicalModelId = modelID
        let provider = TestFactories.makeProvider(
            id: providerID, kind: providerKind, models: [model], apiKey: "sk-test-model-level-0123456789"
        )
        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: defaults), providerID: providerID
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationOutboundCaptureURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "generation-model-level-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID, providerKind: providerKind, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        _ = await state.sendMessage(
            "Hello", in: conversation.id,
            capabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: false)
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while GenerationOutboundCaptureURLProtocol.captured == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let captured = GenerationOutboundCaptureURLProtocol.captured
        try? await Task.sleep(nanoseconds: 300_000_000)
        GenerationOutboundCaptureURLProtocol.captured = nil
        GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: providerID)
        await MetadataClient.shared.resetForTesting()
        let failure = state.conversation(for: conversation.id)?.messages.last
        return try #require(captured, "the send path emitted no request: \(failure?.errorTitle ?? "") \(failure?.errorDetail ?? "")").body
    }
}
