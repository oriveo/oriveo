import Foundation
import Testing
@testable import Oriveo

/// The Anthropic and Gemini generation wire tables have no write path for the reasoning group
/// (reasoning_effort / reasoning_budget / reasoning_mode); thinking on these two goes out only through
/// the capability recipe (Thinking). This suite locks two things:
/// 1. The parameter defaults page says plainly that these rows don't apply here and where thinking is set,
///    instead of showing an unexplained grey row.
/// 2. "This row isn't sent" matches the URLRequest the production send chain actually emits, the Thinking
///    control the note points to really goes out, and the Anthropic thinking guards (temperature, Top K,
///    max tokens) still hold.
@Suite("connection reasoning defaults on anthropic / gemini", .serialized)
@MainActor
struct ConnectionReasoningDefaultsProductionRequestTests {
    private static let modelID = "fixture-reasoning-defaults"
    /// A value no recipe tier uses, so the whole body can be searched for a leak.
    private static let storedBudget = 1_234

    // MARK: - Page note

    @Test("Anthropic / Gemini: reasoning rows are read-only and say thinking is set under Thinking")
    func reasoningRowsWithoutWireExplainWhereThinkingLives() async throws {
        for fixture in [Fixture.anthropic, .gemini] {
            let (provider, model) = try await Self.load(fixture)
            let catalog = AdvancedSettingsCatalog.production(
                provider: provider, model: model, scope: .connectionDefaults,
                identity: nil, isReadOnly: false
            )
            let ids = catalog.parameters.compactMap(\.id)
            #expect(ids.contains("reasoning_budget"), "\(fixture.providerKey) lost its reasoning rows: \(ids)")
            for id in ["reasoning_budget", "reasoning_mode"] where ids.contains(id) {
                let facts = try #require(catalog.facts[id])
                #expect(!facts.isEditable, "\(fixture.providerKey).\(id) is editable without a write path")
                #expect(
                    facts.statusNote == AdvancedSettingsCatalog.reasoningSetByThinkingNoteText,
                    "\(fixture.providerKey).\(id) does not say where thinking is set: \(facts.statusNote ?? "nil")"
                )
            }
            // Parameters with a write path are unaffected.
            #expect(catalog.facts["temperature"]?.isEditable == true)
            #expect(catalog.facts["temperature"]?.statusNote == nil)
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("OpenAI Chat: reasoning rows have a write path, stay editable and carry no such note")
    func reasoningRowsWithWireStayEditable() async throws {
        let (provider, model) = try await Self.load(.openAIChat)
        let catalog = AdvancedSettingsCatalog.production(
            provider: provider, model: model, scope: .connectionDefaults,
            identity: nil, isReadOnly: false
        )
        let facts = try #require(catalog.facts["reasoning_budget"])
        #expect(facts.isEditable)
        #expect(facts.statusNote != AdvancedSettingsCatalog.reasoningSetByThinkingNoteText)
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Production send chain

    @Test("Anthropic: stored reasoning defaults never go out; a Thinking model default goes out via the recipe with the guards in place")
    func anthropicStoredReasoningNeverLeaksAndThinkingCarriesTheGuards() async throws {
        let defaults: [String: GenerationParameterOverride] = [
            "reasoning_budget": .init(state: .value, value: .number(Double(Self.storedBudget))),
            "reasoning_mode": .init(state: .value, value: .string("enabled")),
            "temperature": .init(state: .value, value: .number(0.3)),
            "top_k": .init(state: .value, value: .number(40)),
            "max_output_tokens": .init(state: .value, value: .number(4_000)),
        ]

        let automatic = try await Self.send(.anthropic, defaults: defaults, thinkingDefault: nil)
        Self.expectNoStoredReasoning(in: automatic)
        #expect(automatic["thinking"] == nil, "thinking present while Thinking is automatic: \(automatic.keys.sorted())")
        #expect((automatic["temperature"] as? NSNumber)?.doubleValue == 0.3, "a parameter unrelated to thinking was dropped")
        #expect((automatic["max_tokens"] as? NSNumber)?.intValue == 4_000)

        let deep = try await Self.send(.anthropic, defaults: defaults, thinkingDefault: "deep")
        Self.expectNoStoredReasoning(in: deep)
        let expected = try #require(try CapabilityRuntimeFixtures.recipeValue(
            recipeRef: "anthropic.messages.reasoning.v1", intent: "deep", pointer: "/thinking"
        ) as? [String: Any])
        let thinking = try #require(deep["thinking"] as? [String: Any], "Thinking default is deep but the request has no thinking")
        let budget = try #require((thinking["budget_tokens"] as? NSNumber)?.intValue)
        #expect(budget == (expected["budget_tokens"] as? NSNumber)?.intValue, "thinking budget is not the recipe value")
        #expect(deep["temperature"] == nil, "temperature sent while thinking is on")
        #expect(deep["top_k"] == nil, "Top K sent while thinking is on")
        let maxTokens = try #require((deep["max_tokens"] as? NSNumber)?.intValue)
        #expect(maxTokens > budget, "max_tokens (\(maxTokens)) is not above the thinking budget (\(budget))")
    }

    @Test("Gemini: stored reasoning defaults never go out; a Thinking model default sends the recipe thinkingBudget")
    func geminiStoredReasoningNeverLeaksAndThinkingComesFromRecipe() async throws {
        let defaults: [String: GenerationParameterOverride] = [
            "reasoning_budget": .init(state: .value, value: .number(Double(Self.storedBudget))),
            "temperature": .init(state: .value, value: .number(0.3)),
        ]

        let automatic = try await Self.send(.gemini, defaults: defaults, thinkingDefault: nil)
        Self.expectNoStoredReasoning(in: automatic)
        let config = try #require(automatic["generationConfig"] as? [String: Any])
        #expect(config["thinkingConfig"] == nil, "thinkingConfig present while Thinking is automatic")
        #expect((config["temperature"] as? NSNumber)?.doubleValue == 0.3)

        let deep = try await Self.send(.gemini, defaults: defaults, thinkingDefault: "deep")
        Self.expectNoStoredReasoning(in: deep)
        let expected = try #require(try CapabilityRuntimeFixtures.recipeValue(
            recipeRef: "gemini.generate_content.reasoning.v1", intent: "deep",
            pointer: "/generationConfig/thinkingConfig/thinkingBudget"
        ) as? NSNumber)
        let thinkingConfig = try #require(
            (deep["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        )
        #expect((thinkingConfig["thinkingBudget"] as? NSNumber)?.intValue == expected.intValue)
    }

    // MARK: - Fixture

    struct Fixture {
        let providerKind: ProviderKind
        let providerKey: String
        let modelTransport: String
        let template: String
        let templateWire: [String: String]
        let generationRecipe: String
        let reasoningRecipe: String?

        static let anthropic = Fixture(
            providerKind: .anthropic, providerKey: "anthropic", modelTransport: "anthropic_messages",
            template: "anthropic_messages",
            templateWire: [
                "max_output_tokens": "max_tokens", "temperature": "temperature", "top_k": "top_k",
            ],
            generationRecipe: "anthropic.messages.generation.v1",
            reasoningRecipe: "anthropic.messages.reasoning.v1"
        )
        static let gemini = Fixture(
            providerKind: .gemini, providerKey: "gemini", modelTransport: "gemini_generate",
            template: "gemini_generate_content",
            templateWire: [
                "max_output_tokens": "generationConfig.maxOutputTokens",
                "temperature": "generationConfig.temperature", "top_k": "generationConfig.topK",
            ],
            generationRecipe: "gemini.generate_content.generation.v1",
            reasoningRecipe: "gemini.generate_content.reasoning.v1"
        )
        static let openAIChat = Fixture(
            providerKind: .openAI, providerKey: "openAI", modelTransport: "openai_chat",
            template: "openai_chat_completions",
            templateWire: [
                "max_output_tokens": "max_tokens", "temperature": "temperature", "top_k": "top_k",
                "reasoning_budget": "reasoning_budget", "reasoning_mode": "reasoning_mode",
            ],
            generationRecipe: "openai.chat.generation.v1",
            reasoningRecipe: nil
        )
    }

    /// Metadata in the shape the service delivers: reasoning entries are derived from the model's thinking
    /// tiers, and the template wire table has no path for them.
    private static func load(_ fixture: Fixture) async throws -> (Provider, AIModel) {
        var specs: [CapabilityRuntimeFixtures.ControlSpec] = [
            .init(capability: "generation", recipeRef: fixture.generationRecipe),
        ]
        if let reasoningRecipe = fixture.reasoningRecipe {
            specs.append(.init(
                capability: "reasoning", recipeRef: reasoningRecipe,
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(ofRecipe: reasoningRecipe)
            ))
        }
        let document: [String: Any] = [
            "version": 1,
            "contractVersion": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "profiles": ["generation": [
                "version": 1,
                "parameters": [
                    "max_output_tokens": ["group": "budget", "valueSchema": "integer", "range": ["min": 1, "step": 1]],
                    "temperature": ["group": "sampling", "valueSchema": "number", "range": ["min": 0, "max": 2, "step": 0.01]],
                    "top_k": ["group": "sampling", "valueSchema": "integer", "range": ["min": 0]],
                    "reasoning_budget": ["group": "reasoning", "valueSchema": "integer", "range": ["min": 1, "step": 1]],
                    "reasoning_mode": ["group": "reasoning", "valueSchema": "enum", "enumValues": ["enabled", "disabled"]],
                ],
                "templates": [fixture.template: ["transport": fixture.template, "wire": fixture.templateWire]],
            ]],
            "providers": [fixture.providerKey: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "capabilities": ["text", "reasoning"],
                    "transport": fixture.modelTransport,
                    "supportsTemperature": true,
                    "capabilityControls": CapabilityRuntimeFixtures.controls(specs),
                    "profiles": ["generation": [
                        "template": fixture.template,
                        "revision": "reasoning-defaults-v1",
                        "parameters": [
                            ["id": "max_output_tokens", "support": "supported", "source": "authoritative_metadata"],
                            ["id": "temperature", "support": "supported", "source": "provider_metadata"],
                            ["id": "top_k", "support": "supported", "source": "provider_metadata"],
                            ["id": "reasoning_budget", "support": "supported", "source": "authoritative_metadata"],
                            [
                                "id": "reasoning_mode", "support": "supported", "source": "authoritative_metadata",
                                "enumValues": ["enabled"],
                            ],
                        ],
                    ]],
                ]],
            ]],
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self),
            metadataETag: "reasoning-defaults-\(fixture.providerKey)"
        )
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text, .reasoning], isDefault: true)
        model.canonicalModelId = modelID
        let provider = TestFactories.makeProvider(
            id: UUID(), kind: fixture.providerKind, models: [model], apiKey: "sk-test-reasoning-defaults-0123456789"
        )
        return (provider, model)
    }

    private static func send(
        _ fixture: Fixture,
        defaults: [String: GenerationParameterOverride],
        thinkingDefault: String?
    ) async throws -> [String: Any] {
        let (provider, model) = try await load(fixture)
        let store = GenerationParameterSettingsStore.shared
        let identity = try #require(CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model))
        // The route the page note points to: pick a level under Thinking, then Set as default for this model,
        // which lands in the connection × model scope.
        if let thinkingDefault {
            store.setCapabilityPreferences(
                .init(web: .inherit, reasoningIntent: thinkingDefault),
                providerID: provider.id, modelID: identity.canonicalModelID,
                conversationID: nil, transportIdentity: identity.wireValue
            )
        }
        GenerationOutboundCaptureURLProtocol.captured = nil
        // Store the values at both the connection and the connection × model layer; neither may leak.
        GenerationParameterSettingsStore.shared.setConnectionDefaults(
            GenerationParameterOverrides(values: defaults), providerID: provider.id
        )
        GenerationParameterSettingsStore.shared.setModelDefaults(
            GenerationParameterOverrides(values: defaults), providerID: provider.id, modelID: modelID
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationOutboundCaptureURLProtocol.self]
        let state = AppState(
            seedDemoData: false,
            sessionUID: "reasoning-defaults-\(UUID().uuidString)",
            providerSession: URLSession(configuration: configuration)
        )
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: fixture.providerKind, modelID: modelID
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
        GenerationParameterSettingsStore.shared.setConnectionDefaults(nil, providerID: provider.id)
        GenerationParameterSettingsStore.shared.setModelDefaults(nil, providerID: provider.id, modelID: modelID)
        store.setCapabilityPreferences(
            nil, providerID: provider.id, modelID: identity.canonicalModelID,
            conversationID: nil, transportIdentity: identity.wireValue
        )
        await MetadataClient.shared.resetForTesting()
        let failure = state.conversation(for: conversation.id)?.messages.last
        return try #require(
            captured, "the send chain issued no request: \(failure?.errorTitle ?? "") \(failure?.errorDetail ?? "")"
        ).body
    }

    /// Searches the whole body: no reasoning-group key and no stored budget value may appear at any depth.
    private static func expectNoStoredReasoning(in body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        for key in ["reasoning_budget", "reasoning_mode", "reasoning_effort"] {
            #expect(!text.contains("\"\(key)\""), "\(key) appears in the request body: \(text)")
        }
        #expect(!text.contains(String(storedBudget)), "the stored reasoning budget leaked into the request body: \(text)")
    }
}
