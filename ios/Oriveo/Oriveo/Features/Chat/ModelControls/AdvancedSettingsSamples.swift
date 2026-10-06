#if DEBUG
import SwiftUI

/// Deterministic samples of the advanced settings page and the additional request body editor. They exist in DEBUG builds only.
///
/// Every sample uses a fixed parameter table and a separate local store (no real settings, no network, no conversation),
/// so the same name always produces the same picture. The caller places the returned view in a `NavigationStack`
/// (the page draws its own header and hides the system navigation bar) and wraps that in a sheet.
@MainActor
enum AdvancedSettingsSamples {
    enum Name: String, CaseIterable {
        /// Overview: one row for each of the three sources, the "More" group, additional request body not used.
        case advanced
        /// Editing: max tokens out of range, temperature expanded, two stop sequences.
        case advancedEdit = "advanced-edit"
        /// The long llama.cpp page: Mirostat v2 on, Top K / Top P taken over.
        case localAdvanced = "local-advanced"
        /// Additional request body: two fields that will be added, one protected field.
        case extraBody = "extra-body"
    }

    static func view(_ name: Name) -> AnyView {
        let store = makeStore()
        switch name {
        case .advanced:
            seedCloud(store, maxTokens: 4096, temperature: nil)
            return AnyView(AdvancedSettingsPage(
                provider: cloudProvider, initialModelID: cloudModel.id, conversationID: conversationID,
                store: store, fixtureCatalog: .fixture(profile: cloudProfile)
            ))
        case .advancedEdit:
            seedCloud(store, maxTokens: 90_000, temperature: 0.7)
            return AnyView(AdvancedSettingsPage(
                provider: cloudProvider, initialModelID: cloudModel.id, conversationID: conversationID,
                store: store, fixtureCatalog: .fixture(profile: cloudProfile),
                expandedRows: ["max_output_tokens", "temperature", "stop"]
            ))
        case .localAdvanced:
            seedLocal(store)
            return AnyView(AdvancedSettingsPage(
                provider: localProvider, initialModelID: localModel.id, conversationID: conversationID,
                store: store, fixtureCatalog: localCatalog
            ))
        case .extraBody:
            store.setAdditionalRequestBody(
                .init(rawJSON: extraBodyDraft, sendsWithRequest: true),
                providerID: localProvider.id, modelID: localStorageModelID, conversationID: conversationID
            )
            return AnyView(AdditionalRequestBodyPage(
                provider: localProvider, model: localModel, conversationID: conversationID,
                transportIdentity: "", store: store
            ))
        }
    }

    // MARK: - Fixtures

    static let conversationID = UUID(uuidString: "5A3D0C1E-0000-4000-8000-000000000001")!

    static let extraBodyDraft = """
    {
      "chat_template_kwargs": {
        "enable_thinking": false
      },
      "cache_prompt": true,
      "messages": []
    }
    """

    private static func makeStore() -> GenerationParameterSettingsStore {
        let suite = "oriveo.model-options-sample"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return GenerationParameterSettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    static let cloudModel = AIModel(
        id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "",
        summary: nil, groupKey: nil, groupName: nil
    )

    static let cloudProvider = Provider(
        id: UUID(uuidString: "5A3D0C1E-0000-4000-8000-0000000000A1")!, kind: .deepseek, status: .connected,
        models: [cloudModel], catalogModels: [cloudModel], lastCheckedAt: nil, apiKey: "",
        apiKeyPreview: "", lastError: nil, baseURLText: nil
    )

    static let cloudProfile: GenerationProfileRef = {
        func parameter(
            _ id: String, _ schema: String, _ group: String, range: GenerationParameterRange? = nil,
            enumValues: [GenerationParameterValue]? = nil,
            constraints: [[String: GenerationParameterValue]]? = nil
        ) -> GenerationParameterRef {
            GenerationParameterRef(
                id: id, support: "supported", source: "authoritative_metadata", group: group,
                valueSchema: schema, range: range, enumValues: enumValues, constraints: constraints
            )
        }
        let parameters = [
            parameter("max_output_tokens", "integer", "budget", range: .init(min: 1, max: 8192)),
            parameter("stop", "string-list", "budget", constraints: [["maxItems": .number(4)]]),
            parameter("temperature", "number", "sampling", range: .init(min: 0, max: 2)),
            parameter("top_p", "number", "sampling", range: .init(min: 0, max: 1)),
            parameter("frequency_penalty", "number", "repetition", range: .init(min: -2, max: 2)),
            parameter("presence_penalty", "number", "repetition", range: .init(min: -2, max: 2)),
            parameter("seed", "integer", "reproducibility"),
            parameter("response_format", "enum", "output_contract", enumValues: [.string("text"), .string("json")]),
            parameter("json_schema", "json-schema", "output_contract"),
        ]
        return GenerationProfileRef(
            template: "openai_chat_completions",
            parameters: parameters,
            wire: [
                "max_output_tokens": "max_tokens", "stop": "stop", "temperature": "temperature",
                "top_p": "top_p", "frequency_penalty": "frequency_penalty",
                "presence_penalty": "presence_penalty", "seed": "seed",
                "response_format": "response_format", "json_schema": "response_format",
            ],
            transport: "openai_chat_completions"
        )
    }()

    private static func seedCloud(_ store: GenerationParameterSettingsStore, maxTokens: Double, temperature: Double?) {
        store.setModelDefaults(
            .init(values: ["temperature": .init(state: .value, value: .number(0.2))]),
            providerID: cloudProvider.id, modelID: cloudModel.id
        )
        var session: [String: GenerationParameterOverride] = [
            "max_output_tokens": .init(state: .value, value: .number(maxTokens)),
            "stop": .init(state: .value, value: .stringList(["###", "\n\n"])),
            "frequency_penalty": .init(state: .value, value: .number(0.3)),
        ]
        if let temperature {
            session["temperature"] = .init(state: .value, value: .number(temperature))
        }
        store.setSessionOverrides(
            .init(values: session), providerID: cloudProvider.id, modelID: cloudModel.id,
            conversationID: conversationID
        )
    }

    static let localModel = AIModel(
        id: "qwen3-8b-instruct-q4", name: "qwen3-8b-instruct-q4", capabilities: [.text],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "",
        summary: nil, groupKey: nil, groupName: nil
    )

    static let localProvider: Provider = {
        var provider = Provider(
            id: UUID(uuidString: "5A3D0C1E-0000-4000-8000-0000000000B1")!, kind: .relay, status: .connected,
            models: [localModel], catalogModels: [localModel], lastCheckedAt: nil, apiKey: "",
            apiKeyPreview: "", lastError: nil, baseURLText: "http://127.0.0.1:8080"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions, securityMode: .localHTTP, engineProfile: "llamacpp"
        )
        return provider
    }()

    /// The same llama.cpp parameter table as the production path.
    static var localProfile: GenerationProfileRef {
        LocalEngineGenerationProfiles.profile(for: "llamacpp", transport: .openaiChatCompletions)
            ?? GenerationProfileRef()
    }

    /// On a real llama.cpp connection this table is inferred from the protocol and not verified: the sample carries the same state
    /// and goes through the same annotation decision as production (the header says "unverified" once, rows do not repeat it).
    /// Production assembly is not called directly: it needs the runtime catalog to be ready before it yields rows, and a sample must look the same every time.
    static var localCatalog: AdvancedSettingsCatalog {
        .fixture(profile: localProfile, engineProfile: "llamacpp", inferredFromProtocol: true)
    }

    private static var localStorageModelID: String {
        CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: localProvider, model: localModel)
    }

    private static func seedLocal(_ store: GenerationParameterSettingsStore) {
        store.setSessionOverrides(
            .init(values: [
                "temperature": .init(state: .value, value: .number(0.7)),
                "min_p": .init(state: .value, value: .number(0.1)),
                "mirostat": .init(state: .value, value: .number(2)),
                "mirostat_tau": .init(state: .value, value: .number(4)),
                "repeat_penalty": .init(state: .value, value: .number(1.15)),
                "json_schema": .init(state: .value, value: .object([
                    "type": .string("object"),
                    "properties": .object(["answer": .object(["type": .string("string")])]),
                ])),
            ]),
            providerID: localProvider.id, modelID: localModel.id, conversationID: conversationID
        )
        store.setAdditionalRequestBody(
            .init(
                rawJSON: "{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": false\n  },\n  \"cache_prompt\": true\n}",
                sendsWithRequest: true
            ),
            providerID: localProvider.id, modelID: localStorageModelID, conversationID: conversationID
        )
    }
}
#endif
