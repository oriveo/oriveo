import Foundation
import Testing
@testable import Oriveo

@Suite("Recipe execution fixtures")
struct CapabilityRecipeExecutionTests {
    @Test("continuation fixture maps to protocol-specific wire locations")
    func continuations() throws {
        let fixture = try Self.fixture()
        for item in fixture.continuationCases {
            guard let targetProtocol = item.targetProtocol, let expectedWire = item.expectedWire else { continue }
            let state = item.state?.foundationValue as? [String: Any]
            let actual: [String: Any]
            switch targetProtocol {
            case "openai_responses": let body = CapabilityRecipeExecution.openAIResponsesPreviousID(state?["previousResponseId"] as? String); actual = body.isEmpty ? [:] : ["bodyDelta": body]
            case "gemini_interactions": let body = CapabilityRecipeExecution.geminiInteractionsPreviousID(state?["previousResponseId"] as? String); actual = body.isEmpty ? [:] : ["bodyDelta": body]
            case "anthropic_messages": let blocks = CapabilityRecipeExecution.anthropicReplayContentBlocks(state?["blocks"] as? [[String: Any]]); actual = blocks.isEmpty ? [:] : ["messageAppend": [["role": "assistant", "content": blocks]]]
            case "gemini_generate_content": actual = (state?["blocks"] == nil) ? [:] : ["contentsAppend": state?["blocks"] ?? []]
            case "openai_chat":
                if item.kind == "tool_loop", let messages = state?["completedMessages"] as? [[String: Any]] {
                    actual = ["messageAppend": messages]
                } else if let messages = state?["assistantMessages"] as? [[String: Any]] {
                    // Protocol/parser-specific opaque assistant blocks are replayed unchanged:
                    // OpenRouter reasoning_details and Moonshot/DeepSeek reasoning_content must
                    // never be widened into a common continuation root.
                    actual = ["messageAppend": messages]
                } else {
                    actual = ["messageAppend": [["role": "assistant"]].map { entry in
                        var copy = entry; copy.merge(CapabilityRecipeExecution.openRouterReplayReasoningDetails(state?["reasoningDetails"] as? [[String: Any]])) { _, latest in latest }; return copy
                    }]
                }
            default: actual = [:]
            }
            #expect(Self.json(actual) == Self.json(expectedWire.mapValues { $0.foundationValue }))
        }
    }

    @Test("safe custom fragment fixture rejects losslessly before Foundation decoding")
    func safeCustomFragments() throws {
        let fixture = try Self.fixture()
        let definitionData = try Data(contentsOf: Self.findFile([
            "shared", "capabilityrecipe",
            "capability_custom_controls.v2.json",
        ]))
        let definitions = try #require(
            try JSONSerialization.jsonObject(with: definitionData) as? [String: [String: Any]]
        )
        for item in fixture.safeCustomCases {
            let raw: String
            if let explicit = item.raw { raw = explicit }
            else if let bytes = item.generatedUtf8Bytes { raw = "{\"x\":\"" + String(repeating: "x", count: bytes) + "\"}" }
            else if let depth = item.generatedDepth { raw = "{\"nested\":" + String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth) + "}" }
            else if let nodes = item.generatedNodes { raw = "{\"x\":[" + Array(repeating: "0", count: nodes).joined(separator: ",") + "]}" }
            else { Issue.record("missing raw generator for \(item.caseId)"); continue }
            var declaredOwners = item.declaredOwners ?? [:]
            for ref in item.controlRefs ?? [] {
                if let pointer = definitions[ref]?["targetPointer"] as? String,
                   let owner = definitions[ref]?["owner"] as? String {
                    declaredOwners[pointer] = owner
                }
            }
            let result = SafeCustomFragmentCompiler.compile(
                raw: raw, owner: item.owner, declaredOwners: declaredOwners
            )
            if let expected = item.expectReason {
                #expect(result.failureReason?.rawValue == expected)
            } else {
                #expect(Self.json(result.successValue ?? [:]) == Self.json(item.expectedDelta?.mapValues { $0.foundationValue } ?? [:]))
            }
        }
    }

    @Test("fixture drives owner-local Auto/Custom mutual exclusion")
    func customConfigurationModeMutualExclusion() throws {
        for item in try Self.fixture().safeCustomCases where item.configurationMode != nil {
            var options = ChatRequestOptions(
                generationParameters: .init(values: [
                    "temperature": .init(state: .value, value: .number(0.8)),
                ])
            )
            options.capabilityPreferences = .init(web: .force, reasoningIntent: "deep")
            if item.configurationMode == "custom", let raw = item.raw {
                options.selectLocalCustomBodyFragments([.init(
                    raw: raw, owner: item.owner, declaredOwners: item.declaredOwners ?? [:]
                )])
            } else {
                options.selectLocalCustomBodyFragments([])
            }

            let customSelected = options.localCustomOwnerSet.contains(item.owner)
            #expect(customSelected == (item.expectCustomApplied ?? false), "\(item.caseId) custom")
            #expect(!customSelected == (item.expectRecipeSelected ?? false), "\(item.caseId) recipe")
            let typedOwnerOmitted: Bool
            switch item.owner {
            case "web": typedOwnerOmitted = options.capabilityPreferences?.web == .off
            case "reasoning": typedOwnerOmitted = options.capabilityPreferences?.reasoningIntent == nil
            case "generation": typedOwnerOmitted = options.generationParameters == nil
            default: typedOwnerOmitted = false
            }
            #expect(typedOwnerOmitted == (item.expectTypedOwnerOmitted ?? false), "\(item.caseId) typed")
        }
    }

    @Test("developer preview uses the production Relay schema and never exposes values")
    func developerPreviewUsesProductionRelaySchema() {
        let preview = CapabilityRecipeExecution.redactedSafeCustomPreview(
            raw: #"{"temperature":0.7,"top_p":0.9}"#,
            providerKind: .relay,
            modelID: "user-owned-model",
            transport: "openai_chat_completions"
        )
        #expect(preview.redactedPointers == ["/temperature", "/top_p"])

        let forbidden = CapabilityRecipeExecution.redactedSafeCustomPreview(
            raw: #"{"model":"other-model"}"#,
            providerKind: .relay,
            modelID: "user-owned-model",
            transport: "openai_chat_completions"
        )
        #expect(forbidden.failureReason == .forbiddenRoot)
    }

    @Test("documentation follows the exact runtime recipe source and has no provider fallback")
    func developerDocumentationUsesExactRuntimeEvidence() throws {
        let runtime = try JSONDecoder().decode(MetadataClient.CapabilityRuntimeEnvelope.self, from: Data("""
        {"schemaVersion":2,"revision":"test","generatedAt":"2026-08-12T00:00:00Z",
         "recipes":{"openai.chat.generation.v1":{"id":"openai.chat.generation.v1","providerKind":"openAI","transport":{"protocol":"openai_chat"},"capability":"generation","executionKind":"request_overlay","requestOps":[],"sourceRefs":["openai.generation"]}},
         "controlDefinitions":{},"sourceIndex":{"openai.generation":{"kind":"official_doc","url":"https://developers.example.test/generation","reviewedAt":"2026-08-12"}}}
        """.utf8))
        let control = try JSONDecoder().decode(MetadataClient.CapabilityControl.self, from: Data("""
        {"state":"auto_available","recipeRef":"openai.chat.generation.v1"}
        """.utf8))
        #expect(CapabilityRecipeExecution.officialGenerationDocumentationURL(
            runtime: runtime, control: control
        )?.absoluteString == "https://developers.example.test/generation")

        let missingRecipe = try JSONDecoder().decode(MetadataClient.CapabilityControl.self, from: Data("""
        {"state":"auto_available","recipeRef":"missing.recipe"}
        """.utf8))
        #expect(CapabilityRecipeExecution.officialGenerationDocumentationURL(
            runtime: runtime, control: missingRecipe
        ) == nil)
    }

    @Test("control presentation maps catalog reasons without exposing provenance")
    func controlStatusPresentation() {
        let reasonCases: [(String, CapabilityControlPresentation)] = [
            ("endpoint_route_pending", .pending),
            ("model_route_pending", .pending),
            ("official_source_insufficient", .pending),
            ("source_review_expired", .pending),
            ("provider_kill_switch", .pending),
            // reasonCode is an open set: it may only refine the same state, never reclassify unknown as unavailable.
            ("relay_user_directory", .unknown),
            ("external_connector_only", .unknown),
            ("transport_not_supported", .unknown),
            ("model_capability_absent", .unknown),
            ("retired_model_alias", .unknown),
            ("upstream_parameter_not_declared", .unknown),
            ("opaque_server_reason", .unknown),
        ]
        for item in reasonCases {
            #expect(CapabilityControlPresentation.status(
                state: "unknown", reasonCode: item.0, exactTransportMatches: false
            ) == item.1)
        }

        #expect(CapabilityControlPresentation.status(
            state: "custom_only", reasonCode: "transport_not_supported", exactTransportMatches: false
        ) == .customOnly)
        #expect(CapabilityControlPresentation.status(
            state: "unavailable", reasonCode: nil, exactTransportMatches: false
        ) == .unsupported)

        // Reverse assertion: external_connector_only only changes the "why"; unavailable stays unavailable.
        // It is never promoted to automatic (even on an exact transport match) and never degraded to pending review.
        for exactTransportMatches in [false, true] {
            #expect(CapabilityControlPresentation.status(
                state: "unavailable", reasonCode: "external_connector_only",
                exactTransportMatches: exactTransportMatches
            ) == .externalConnectorOnly)
        }
    }

    @Test("exact transport gate applies symmetrically only to automatic controls")
    func exactTransportOnlyGatesAutomaticPresentation() {
        #expect(CapabilityControlPresentation.status(
            state: "auto_available", reasonCode: nil, exactTransportMatches: true
        ) == .automaticAvailable)
        #expect(CapabilityControlPresentation.status(
            state: "auto_available", reasonCode: nil, exactTransportMatches: false
        ) == .unknown)
        #expect(CapabilityControlPresentation.status(
            state: "auto_available", reasonCode: nil, exactTransportMatches: true, forceRequested: true
        ) == .forceUnsupported)
        #expect(CapabilityControlPresentation.status(
            state: "custom_only", reasonCode: "relay_user_directory", exactTransportMatches: false
        ) == .customOnly)
        #expect(CapabilityControlPresentation.status(
            state: "unknown", reasonCode: "transport_not_supported", exactTransportMatches: false
        ) == .unknown)
    }

    @Test("DeepSeek and OpenRouter replay frames preserve provider-owned opaque fields")
    func replayReasoningFramesStayOpaque() throws {
        let deepSeek = CapabilityRecipeExecution.deepSeekReplayAssistant(
            content: "answer", reasoningContent: "private chain",
            toolCalls: [[
                "id": "call_1", "type": "function",
                "function": ["name": "search", "arguments": #"{"q":"news"}"#],
            ]]
        )
        #expect(Self.json(deepSeek) == Self.json([
            "role": "assistant", "content": "answer", "reasoning_content": "private chain",
            "tool_calls": [[
                "id": "call_1", "type": "function",
                "function": ["name": "search", "arguments": #"{"q":"news"}"#],
            ]],
        ]))

        let openRouter = try #require(CapabilityRecipeExecution.openRouterReplayAssistant(
            content: "answer",
            reasoningDetails: [["type": "reasoning.encrypted", "data": "opaque-bytes"]],
            toolCalls: [[
                "id": "call_or", "type": "function",
                "function": ["name": "lookup", "arguments": #"{"q":"news"}"#],
            ]]
        ))
        #expect(Self.json(openRouter) == Self.json([
            "role": "assistant", "content": "answer",
            "reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-bytes"]],
            "tool_calls": [[
                "id": "call_or", "type": "function",
                "function": ["name": "lookup", "arguments": #"{"q":"news"}"#],
            ]],
        ]))

        #expect(CapabilityRecipeExecution.openRouterReplayAssistant(
            content: "answer", reasoningDetails: [], toolCalls: nil
        ) == nil)
        #expect(CapabilityRecipeExecution.openRouterReplayAssistant(
            content: "answer",
            reasoningDetails: [["type": "reasoning.encrypted", "index": -1, "data": "bad"]],
            toolCalls: nil
        ) == nil)
        #expect(CapabilityRecipeExecution.openRouterReplayAssistant(
            content: "answer",
            reasoningDetails: [["type": "reasoning.encrypted", "data": "opaque"]],
            toolCalls: [[
                "type": "function",
                "function": ["name": "lookup", "arguments": "{}"],
            ]]
        ) == nil)

        var crossedShape = openRouter
        crossedShape["reasoning_content"] = "must-not-cross"
        #expect(CapabilityRecipeExecution.openRouterReplayAssistantMessages([crossedShape]) == nil)

        let invalidState = RequestContinuationIntent(
            kind: "replay_reasoning", variant: nil, step: 1,
            state: ["assistantMessages": .array([.object([
                "role": .string("assistant"),
                "content": .string("answer"),
                "reasoning_details": .array([.object([
                    "type": .string("reasoning.encrypted"),
                    "index": .double(0.5),
                    "data": .string("bad"),
                ])]),
            ])])]
        )
        #expect(RequestPreferenceResolver.validateContinuation(invalidState).reason
            == .invalidReplayReasoningState)
    }

    @Test("MiniMax replay accepts only the exact content + reasoning_details + tool_calls shape")
    func miniMaxReplayFrameValidation() throws {
        let details: [[String: Any]] = [[
            "index": 0, "type": "reasoning.encrypted", "data": "opaque",
        ]]
        let calls: [[String: Any]] = [[
            "id": "call_1", "type": "function",
            "function": ["name": "lookup", "arguments": #"{"q":"news"}"#],
        ]]
        let frame = try #require(CapabilityRecipeExecution.miniMaxReplayAssistant(
            content: NSNull(), reasoningDetails: details, toolCalls: calls
        ))
        #expect(frame["content"] is NSNull)
        #expect(Self.json(["value": frame["reasoning_details"] as Any])
            == Self.json(["value": details]))

        var extraTopLevel = frame
        extraTopLevel["reasoning_content"] = "must-not-cross"
        #expect(CapabilityRecipeExecution.miniMaxReplayAssistantMessages([extraTopLevel]) == nil)
        #expect(CapabilityRecipeExecution.miniMaxReplayAssistant(
            content: "answer", reasoningDetails: [["index": "0", "data": "bad"]],
            toolCalls: nil
        ) == nil)
        #expect(CapabilityRecipeExecution.miniMaxReplayAssistant(
            content: "answer", reasoningDetails: details,
            toolCalls: [[
                "id": "call_1", "type": "function", "future": true,
                "function": ["name": "lookup", "arguments": "{}"],
            ]]
        ) == nil)

        let nullContentState = RequestContinuationIntent(
            kind: "replay_reasoning", variant: nil, step: 1,
            state: ["assistantMessages": .array([.object([
                "role": .string("assistant"),
                "content": .null,
                "reasoning_details": .array([.object([
                    "type": .string("reasoning.encrypted"), "data": .string("opaque"),
                ])]),
            ])])]
        )
        #expect(RequestPreferenceResolver.validateContinuation(nullContentState).accepted)
    }

    @Test("Mistral replay frame accepts only a string or complete thinking/text blocks; unknown blocks fail closed")
    func mistralReplayFrameValidation() throws {
        let blocks: [[String: Any]] = [
            [
                "type": "thinking",
                "thinking": [["type": "text", "text": "opaque"]],
                "closed": true,
            ],
            ["type": "text", "text": "answer"],
        ]
        let calls: [[String: Any]] = [[
            "id": "call_1", "type": "function",
            "function": ["name": "lookup", "arguments": #"{"q":"news"}"#],
        ]]
        let frame = try #require(CapabilityRecipeExecution.mistralReplayAssistant(
            content: blocks, toolCalls: calls
        ))
        #expect(Self.json(["value": frame["content"] as Any]) == Self.json(["value": blocks]))
        #expect(Self.json(["value": frame["tool_calls"] as Any]) == Self.json(["value": calls]))

        #expect(CapabilityRecipeExecution.mistralReplayAssistant(
            content: [["type": "future_opaque", "data": "must-not-guess"]],
            toolCalls: nil
        ) == nil)
        #expect(CapabilityRecipeExecution.mistralReplayAssistant(
            content: [["type": "thinking", "thinking": [["type": "text", "text": 42]]]],
            toolCalls: nil
        ) == nil)

        let invalidState = RequestContinuationIntent(
            kind: "replay_reasoning", variant: nil, step: 1,
            state: ["assistantMessages": .array([.object([
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("future_opaque"), "data": .string("must-not-guess"),
                ])]),
            ])])]
        )
        let decision = RequestPreferenceResolver.validateContinuation(invalidState)
        #expect(!decision.accepted)
        #expect(decision.reason == .invalidReplayReasoningState)
    }

    @Test("provider coverage and execution cases are consumed from the shared registry")
    func providerCoverageAndExecution() throws {
        let fixture = try Self.fixture()
        let registryData = try Data(contentsOf: Self.findFile(
            fixture.registryPath.split(separator: "/").map(String.init)
        ))
        let registry = try #require(JSONSerialization.jsonObject(with: registryData) as? [String: Any])
        let recipes = try #require(registry["recipes"] as? [String: Any])

        // All 15 rows are checked against the published capability registry, including Gemini's selector
        // transport alias; no test-owned provider map may hide an unimplemented row.
        #expect(fixture.providerCoverage.count == 17)
        #expect(Set(fixture.providerCoverage.map(\.providerKind)).count == 15)
        for row in fixture.providerCoverage {
            let recipe = try #require(recipes[row.recipeRef] as? [String: Any])
            #expect(recipe["providerKind"] as? String == row.providerKind)
            let transport = try #require(recipe["transport"] as? [String: Any])
            #expect(transport["protocol"] as? String == row.transport)
            let selector = row.selectorTransport ?? row.transport
            #expect(CapabilityRecipeRequestCompiler.canonicalTransport(selector) == row.transport)
        }
        for item in fixture.executionCases {
            if item.executionKind == "external_connector" {
                #expect(item.expected.noExecute == true)
                continue
            }
            let recipe = try #require(recipes[item.recipeRef ?? ""] as? [String: Any])
            #expect(recipe["executionKind"] as? String == item.executionKind)
        }
    }

    @Test("Gemini Interactions GA builder uses origin route and Content wire for both modes")
    func geminiInteractionsProductionBuilder() throws {
        let fixture = try Self.fixture()
        let registryData = try Data(contentsOf: Self.findFile(
            fixture.registryPath.split(separator: "/").map(String.init)
        ))
        let registry = try #require(JSONSerialization.jsonObject(with: registryData) as? [String: Any])
        let recipes = try #require(registry["recipes"] as? [String: Any])
        let rawRecipe = try #require(recipes["gemini.interactions.web.v1"])
        let recipeData = try JSONSerialization.data(withJSONObject: rawRecipe)
        let recipe = try JSONDecoder().decode(MetadataClient.CapabilityRecipe.self, from: recipeData)
        let userMessage = ChatMessage(
            id: UUID(), role: .user, text: "news", providerKind: .gemini,
            providerName: "Gemini", modelName: "gemini-3-flash", state: .delivered
        )
        let assistantMessage = ChatMessage(
            id: UUID(), role: .assistant, text: "prior answer", providerKind: .gemini,
            providerName: "Gemini", modelName: "gemini-3-flash", state: .delivered
        )
        for stream in [false, true] {
            let request = try GeminiService().buildInteractionsRequest(
                modelID: "gemini-3-flash", messages: [userMessage, assistantMessage], apiKey: "fixture-key",
                stream: stream, recipe: recipe, systemPrompt: "be brief"
            )
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1/interactions")
            let bodyData = try #require(request.httpBody)
            let body = try #require(
                try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            #expect(body["stream"] as? Bool == stream)
            #expect((body["input"] as? [[String: Any]])?.first?["parts"] != nil)
            #expect((body["input"] as? [[String: Any]])?.map { $0["role"] as? String } == ["user", "model"])
            #expect(body["system_instruction"] as? String == "be brief")
            #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "google_search")
        }
    }

    @Test("production recipe body uses actual delta, never its redacted preview")
    func compilerSeparatesProductionDeltaFromPreview() throws {
        let raw = """
        {"id":"fixture.preview.separation","providerKind":"gemini",
         "transport":{"protocol":"gemini_interactions"},"capability":"web",
         "executionKind":"endpoint_route",
         "requestOps":[{"op":"append","pointer":"/tools/-",
           "value":{"type":"google_search","authorization":"opaque-wire-value"}}]}
        """
        let recipe = try JSONDecoder().decode(
            MetadataClient.CapabilityRecipe.self, from: Data(raw.utf8)
        )
        var body: [String: Any] = ["tools": []]
        let compilation = CapabilityRecipeRequestCompiler.compile(
            recipe: recipe, to: &body, providerKind: "gemini",
            transport: "gemini_interactions", capability: "web", selectedIntent: nil
        )
        #expect(compilation.applied)
        #expect(((body["tools"] as? [[String: Any]])?.first?["authorization"] as? String) == "opaque-wire-value")
        #expect(((compilation.redactedPreview["tools"] as? [[String: Any]])?.first?["authorization"] as? String) == "[REDACTED]")
    }

    @Test("user copy has 16-locale parity and no English placeholder translations")
    func customEditorLocalizationParity() throws {
        let data = try Data(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Chat.xcstrings",
        ]))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let locales = Set([
            "en", "zh-Hans", "zh-Hant", "ar", "de", "es", "fr", "hi", "id", "ja", "ko",
            "pt-BR", "ru", "th", "tr", "vi",
        ])
        // The editor is a single multi-owner page with no master switch: non-empty content
        // simply takes effect. This list pins the copy production actually renders, so a
        // string that stops being used has to be removed from here too.
        let keys = [
            "Custom request fields", "Custom request fields JSON",
            "Scope: this conversation, connection, model, and transport.",
            "Fields are added to the request exactly as written. Only fields this provider officially declares are supported; mistakes can make requests fail. Drafts stay on this device.",
            "Open official provider documentation",
            "For a Relay, use the documentation supplied by its administrator.",
            "Enter a JSON object to preview its allowed field paths.",
            "Redacted request delta preview", "Enter valid JSON with no duplicate keys.",
            "This field conflicts with the managed request schema or is not allowed for this connection.",
            "This field isn’t allowed. Fields this model accepts: %@",
            "This JSON fragment is too large or complex to apply.",
            "Remove custom request fields?", "Keep custom fields", "Remove custom fields",
            "This removes the custom fields for %@ on this conversation, connection, model and transport. This cannot be undone.",
            "Custom fields need an official field schema for this exact model and transport.",
            "This connection declares no custom fields for this control.",
            "Custom is selected but empty, so messages using this control will fail to send.",
            "Switch back to automatic",
            // External-connector and MCP type-and-boundary copy is also user-visible and must cover all 16 locales.
            "This capability is provided by a separate external service, outside this connection's chat request.",
            // The fee and privacy notices driven by the server-issued riskTier are user-visible too,
            // so they need all 16 locales as well.
            "This field can send your data to a third-party service.",
            "This field can increase what the provider charges.",
        ]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == locales, "locale parity: \(key)")
            let english = try #require(Self.localizedValue(localizations, locale: "en"))
            for locale in locales where locale != "en" {
                let value = try #require(Self.localizedValue(localizations, locale: locale))
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(value != english, "English placeholder: \(locale) / \(key)")
            }
        }

        // "Has a translation, and it is not the English source" is too weak on its own: a
        // locale can pass it while collapsing several distinct sentences onto one generic
        // line, which quietly erases the categories for everyone but English readers. So
        // sentences that mean different things must also differ from each other per locale.
        let mustDifferPerLocale = [
            "Enter valid JSON with no duplicate keys.",
            "This JSON fragment is too large or complex to apply.",
            "This field conflicts with the managed request schema or is not allowed for this connection.",
            "Enter a JSON object to preview its allowed field paths.",
        ]
        for locale in locales {
            var seen: [String: String] = [:]
            for key in mustDifferPerLocale {
                let entry = try #require(strings[key] as? [String: Any])
                let localizations = try #require(entry["localizations"] as? [String: Any])
                let value = try #require(Self.localizedValue(localizations, locale: locale))
                #expect(seen[value] == nil, "\(locale): \(key) shares a translation with \(seen[value] ?? ""); the categories are invisible")
                seen[value] = key
            }
        }
    }

    /// There is no global developer switch: a switch that belongs to no model cannot explain
    /// "I turned it on, why is nothing here?". The only gate is whether a schema was issued.
    /// Two invariants follow — the panel never reads a master switch, and an overridden
    /// preference is shown in place with a way back. Rewriting a preference silently would be
    /// the UI lying about what it is going to send.
    @Test("Model Controls surfaces an overridden owner in place, with no global gate left")
    func customEditorStructureIsGatedAndAccessible() throws {
        let page = try Self.customFieldsPageSource()
        let sheet = try Self.modelControlsSheetSource()
        for gate in [
            "localCustomDeveloperModeDefaultsKey", "customDeveloperModeEnabled",
            "setLocalCustomDeveloperModeEnabled(",
        ] {
            #expect(!sheet.contains(gate), "panel reads a global master switch again: \(gate)")
        }
        // Same predicate as the outbound gate: outbound treats `mode == .custom` as selected.
        #expect(sheet.contains("customModes[owner, default: .automatic] == .custom"))
        // When overridden, the in-card warning and the path back to the editor are both required.
        #expect(sheet.contains("showsAdvancedSettingsAction: overridden"))
        #expect(page.contains("design: .monospaced"))
        #expect(page.contains(".accessibilityLabel"))
        // The editor sizes itself; do not hard-code frame(width:).
        #expect(!page.contains(".frame(width:"))
        // Missing managed state or identity still allows opening the main panel to inspect status, but never a write page.
        #expect(sheet.contains("guard editability.canPersist"))
        #expect(sheet.contains("isReadOnly: !editability.canPersist"))
    }

    /// The editor is reached through Advanced Settings → Developer → Custom request fields and
    /// carries every owner on one page. Sectioning by owner is only safe because the page above
    /// is the parameter table: repeating the previous page's own cards here would invert the
    /// hierarchy rather than describe it.
    @Test("Custom request fields page carries every owner in one page, entered from Advanced Settings")
    func customFieldsPageCarriesEveryOwner() throws {
        let page = try Self.customFieldsPageSource()
        // The page resolves owner and schema itself; callers no longer pass owner/binding.
        // Two separate predicates at entry vs content is what made the old UI "openable but not editable".
        #expect(!page.contains("let owner: String"))
        #expect(!page.contains("@Binding var mode:"))
        #expect(page.contains("ownerNamespaces"))
        for owner in ["\"web\"", "\"reasoning\"", "\"generation\""] {
            #expect(page.contains(owner), "editor page is missing owner \(owner)")
        }
        // Section titles use user-facing words, not the raw web/reasoning/generation tokens.
        #expect(page.contains("L10n.tr(\"Web Search\", table: .chat)"))
        #expect(page.contains("L10n.tr(\"Thinking Mode\", table: .chat)"))
        #expect(page.contains("L10n.tr(\"Parameters\", table: .providers)"))
        // The "configuration method Auto/Custom" two-step picker is gone: mode is derived from content, no second switch.
        #expect(!page.contains("ModelControlIntentPicker"))
        #expect(!page.contains("Configuration method"))
        // Rejecting a path-class field must list the allowed set, otherwise the user knows it is wrong but not how to fix it.
        #expect(page.contains("safeCustomAllowedPaths("))
        #expect(page.contains("This field isn’t allowed. Fields this model accepts: %@"))
        // Footer copy is merged into one sentence; the old privacy-only sentence must not appear on its own.
        #expect(page.contains("Fields are added to the request exactly as written."))
        #expect(!page.contains("They are not synced, logged, sent to telemetry"))

        // There is a single entry, on the Advanced Settings page; the capability panel no longer routes to customFields.
        let advanced = try String(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Providers",
            "GenerationParameterDefaultsSheet.swift",
        ]), encoding: .utf8)
        #expect(advanced.contains("CustomRequestFieldsPage("))
        let sheet = try Self.modelControlsSheetSource()
        #expect(!sheet.contains("ModelControlsRoute.customFields"), "panel grew a custom-fields route again")
        #expect(!sheet.contains("CustomRequestFieldsPage("), "panel hosts the editor page directly again")
    }

    @Test("Model Controls never offers a dead control, and never strands a subpage")
    func modelControlsKeepsTiersVisibleAndReachable() throws {
        let sheet = try Self.modelControlsSheetSource()
        // Shape is not assembled inline in the panel; two pure functions decide it.
        // "Unavailable degrades to a tappable status row / only render tiers the recipe
        // actually issued / every exit points at the root cause" are asserted directly
        // against those functions in `ModelControlCapabilityLayoutTests` (stronger than a
        // source grep). This test only keeps the structural constraint that the panel
        // actually consumes them.
        #expect(sheet.contains("ModelControlReasoningLayout.layout("))
        #expect(sheet.contains("ModelControlWebLayout.layout("))
        // Writability only affects shape — interactive control vs read-only status row. It
        // never produces a disabled control, which explains nothing to the reader.
        #expect(sheet.contains("isEditable: editability.canPersist && !overridden"))
        #expect(sheet.contains("var isConfigurable: Bool"))
        // The force reason stays visible; it is no longer gated on "a selected-but-unselectable tier", which is unreachable.
        #expect(!sheet.contains("forceRequested"))
        // Subpages always push. Dismissing this sheet to open another loses the reader's place.
        #expect(sheet.contains("NavigationLink(value: ModelControlsRoute.modelBehavior)"))
        #expect(!sheet.contains("opensModelBehavior"))
        // Detents belong to the panel. The composer **must not declare another copy**:
        // presentation preferences let the outer sheet override the inner one, and the
        // composer's copy silently kills the panel's own declaration.
        let composer = try String(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ]), encoding: .utf8)
        #expect(!composer.contains(".presentationDetents("))
        // Keep only the `.large` detent. Extra detents let the sheet's expand recognizer
        // swallow an upward drag inside the content area and fight the ScrollView, which
        // clips the bottom of the page and makes it unreachable.
        #expect(sheet.contains(".presentationDetents([.large])"))
        #expect(!sheet.contains(".fraction("), "multi-detent came back; upward drags will be eaten by the expand gesture")
    }

    /// Visual rule: panel hierarchy comes only from background contrast, spacing, and a very
    /// light shadow. Stacking card strokes, pill strokes and callout fills turns the page into
    /// a grid.
    @Test("Model Controls surfaces carry no borders")
    func modelControlSurfacesAreBorderless() throws {
        for name in ["ModelControlsSheet", "ModelControlsComponents", "CustomRequestFieldsPage",
                     "CapabilitySupportedModelsPage"] {
            let source = try String(contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
                "\(name).swift",
            ]), encoding: .utf8)
            #expect(!source.contains("strokeBorder"), "\(name) drew a stroke again")
            #expect(!source.contains(".stroke("), "\(name) drew a stroke again")
        }
    }

    private static func customFieldsPageSource() throws -> String {
        try String(contentsOf: findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "CustomRequestFieldsPage.swift",
        ]), encoding: .utf8)
    }

    private static func modelControlsSheetSource() throws -> String {
        try String(contentsOf: findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ]), encoding: .utf8)
    }

    private static func fixture() throws -> Fixture {
        let file = findFile(["shared", "model-contracts", "provider_recipe_execution.v1.json"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }
    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("fixture not found")
    }
    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(); return String(decoding: data, as: UTF8.self)
    }
    private static func localizedValue(_ localizations: [String: Any], locale: String) -> String? {
        guard let localization = localizations[locale] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }
    private struct Fixture: Decodable {
        let registryPath: String
        let providerCoverage: [Coverage]
        let executionCases: [Execution]
        let continuationCases: [Continuation]
        let safeCustomCases: [Safe]
    }
    private struct Coverage: Decodable {
        let providerKind: String; let transport: String; let selectorTransport: String?
        let recipeRef: String; let modelId: String
    }
    private struct Execution: Decodable {
        let recipeRef: String?; let executionKind: String; let expected: Expected
    }
    private struct Expected: Decodable { let noExecute: Bool? }
    private struct Continuation: Decodable { let kind: String; let targetProtocol: String?; let state: MetadataClient.JSONValue?; let expectedWire: [String: MetadataClient.JSONValue]? }
    private struct Safe: Decodable {
        let caseId: String; let owner: String; let configurationMode: String?; let raw: String?
        let declaredOwners: [String: String]?; let controlRefs: [String]?
        let expectedDelta: [String: MetadataClient.JSONValue]?
        let expectRecipeSelected: Bool?; let expectCustomApplied: Bool?; let expectTypedOwnerOmitted: Bool?
        let expectReason: String?; let generatedUtf8Bytes: Int?; let generatedDepth: Int?; let generatedNodes: Int?
    }
}

private extension Result where Success == [String: Any], Failure == SafeCustomFragmentCompiler.Rejection {
    var successValue: Success? { if case let .success(value) = self { return value }; return nil }
    var failureReason: Failure? { if case let .failure(value) = self { return value }; return nil }
}

private extension Result where Success == [String], Failure == SafeCustomFragmentCompiler.Rejection {
    var redactedPointers: Success? { if case let .success(value) = self { return value }; return nil }
    var failureReason: Failure? { if case let .failure(value) = self { return value }; return nil }
}
