import Foundation
import CoreFoundation

enum CapabilityRecipeExecution {
    /// Responses and Interactions are deliberately separate even though this revision uses the same
    /// field spelling. Keeping the adapters split prevents a future protocol change from becoming a
    /// silent cross-provider root spread.
    static func openAIResponsesPreviousID(_ id: String?) -> [String: Any] { id.map { ["previous_response_id": $0] } ?? [:] }
    static func geminiInteractionsPreviousID(_ id: String?) -> [String: Any] { id.map { ["previous_interaction_id": $0] } ?? [:] }
    static func anthropicReplayContentBlocks(_ blocks: [[String: Any]]?) -> [[String: Any]] { blocks ?? [] }
    static func openRouterReplayReasoningDetails(_ details: [[String: Any]]?) -> [String: Any] { details.map { ["reasoning_details": $0] } ?? [:] }
    /// These are wire frames, not display models. Keep every opaque field in the
    /// assistant message until the provider has accepted the next turn.
    static func deepSeekReplayAssistant(
        content: String, reasoningContent: String, toolCalls: [[String: Any]]
    ) -> [String: Any] {
        var message: [String: Any] = [
            "role": "assistant", "content": content,
            "reasoning_content": reasoningContent,
        ]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        return message
    }

    static func openRouterReplayAssistant(
        content: String,
        reasoningDetails: [[String: Any]]?,
        toolCalls: [[String: Any]]?
    ) -> [String: Any]? {
        guard let reasoningDetails, validOpenRouterReasoningDetails(reasoningDetails) else {
            return nil
        }
        if let toolCalls,
           (toolCalls.isEmpty || !validOpenAIToolCalls(toolCalls)) {
            return nil
        }
        var message: [String: Any] = ["role": "assistant", "content": content]
        message["reasoning_details"] = reasoningDetails
        if let toolCalls { message["tool_calls"] = toolCalls }
        return message
    }

    /// OpenRouter owns `reasoning_details`; never let another openai_chat replay shape cross this
    /// boundary. Detail objects remain opaque, but their protocol envelope and any tool calls must
    /// be complete before they can be sent back upstream.
    static func openRouterReplayAssistantMessages(
        _ messages: [[String: Any]]?
    ) -> [[String: Any]]? {
        guard let messages, !messages.isEmpty else { return nil }
        let allowedKeys: Set<String> = ["role", "content", "reasoning_details", "tool_calls"]
        guard messages.allSatisfy({ message in
            Set(message.keys).isSubset(of: allowedKeys)
                && message["role"] as? String == "assistant"
                && message["content"] is String
                && (message["reasoning_details"] as? [[String: Any]])
                    .map(validOpenRouterReasoningDetails) == true
                && (message["tool_calls"] == nil
                    || ((message["tool_calls"] as? [[String: Any]])
                        .map { !$0.isEmpty && validOpenAIToolCalls($0) } == true))
        }) else { return nil }
        return messages
    }

    /// MiniMax `reasoning_split` returns a provider-owned assistant frame. `content: null` is a
    /// valid tool-call turn and must remain distinct from a missing content field.
    static func miniMaxReplayAssistant(
        content: Any?, reasoningDetails: [[String: Any]]?, toolCalls: [[String: Any]]?
    ) -> [String: Any]? {
        guard let content,
              content is String || content is NSNull,
              let reasoningDetails,
              validMiniMaxReasoningDetails(reasoningDetails) else { return nil }
        if let toolCalls,
           (toolCalls.isEmpty || !validExactMiniMaxToolCalls(toolCalls)) { return nil }
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
            "reasoning_details": reasoningDetails,
        ]
        if let toolCalls { message["tool_calls"] = toolCalls }
        return message
    }

    static func miniMaxReplayAssistantMessages(
        _ messages: [[String: Any]]?
    ) -> [[String: Any]]? {
        guard let messages, !messages.isEmpty else { return nil }
        let allowedKeys: Set<String> = ["role", "content", "reasoning_details", "tool_calls"]
        guard messages.allSatisfy({ message in
            Set(message.keys).isSubset(of: allowedKeys)
                && message["role"] as? String == "assistant"
                && message["content"] != nil
                && (message["content"] is String || message["content"] is NSNull)
                && (message["reasoning_details"] as? [[String: Any]])
                    .map(validMiniMaxReasoningDetails) == true
                && (message["tool_calls"] == nil
                    || (message["tool_calls"] as? [[String: Any]])
                        .map { !$0.isEmpty && validExactMiniMaxToolCalls($0) } == true)
        }) else { return nil }
        return messages
    }

    static func validMiniMaxReasoningDetails(_ details: [[String: Any]]) -> Bool {
        guard !details.isEmpty else { return false }
        return details.allSatisfy { detail in
            guard !detail.isEmpty, JSONSerialization.isValidJSONObject(detail) else { return false }
            if let index = detail["index"], nonnegativeInteger(index) == nil { return false }
            for key in ["text", "summary", "data"] where detail[key] != nil {
                guard detail[key] is String else { return false }
            }
            return true
        }
    }

    static func validExactMiniMaxToolCalls(_ calls: [[String: Any]]) -> Bool {
        let callKeys: Set<String> = ["id", "type", "function"]
        let functionKeys: Set<String> = ["name", "arguments"]
        return !calls.isEmpty && calls.allSatisfy { call in
            guard Set(call.keys).isSubset(of: callKeys),
                  let id = call["id"] as? String, !id.isEmpty,
                  call["type"] as? String == "function",
                  let function = call["function"] as? [String: Any],
                  Set(function.keys).isSubset(of: functionKeys),
                  let name = function["name"] as? String, !name.isEmpty,
                  function["arguments"] is String else { return false }
            return true
        }
    }

    static func validOpenRouterReasoningDetails(_ details: [[String: Any]]) -> Bool {
        guard !details.isEmpty else { return false }
        return details.allSatisfy { detail in
            guard !detail.isEmpty,
                  let type = detail["type"] as? String, !type.isEmpty,
                  JSONSerialization.isValidJSONObject(detail) else { return false }
            if let index = detail["index"], nonnegativeInteger(index) == nil { return false }
            for key in ["text", "summary", "data"] where detail[key] != nil {
                guard detail[key] is String else { return false }
            }
            return true
        }
    }

    private static func nonnegativeInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0, raw.rounded(.towardZero) == raw,
              raw <= Double(Int.max) else { return nil }
        return Int(raw)
    }

    /// Mistral continuation replays the provider-owned assistant `content` shape, not the UI's
    /// flattened reasoning/text strings. A plain string and a validated thinking/text block array
    /// are both native wire forms. Unknown or malformed blocks reject the whole frame so a future
    /// provider block type can never be silently rewritten into a different protocol message.
    static func mistralReplayAssistant(
        content: Any?, toolCalls: [[String: Any]]?
    ) -> [String: Any]? {
        guard let content, validMistralContent(content) else { return nil }
        if let toolCalls, !validOpenAIToolCalls(toolCalls) { return nil }
        var message: [String: Any] = ["role": "assistant", "content": content]
        // Preserve present-but-empty exactly; absence and an empty upstream array are different
        // opaque response facts even though both produce no local tool proposal.
        if let toolCalls { message["tool_calls"] = toolCalls }
        return message
    }

    /// Exact Mistral consumer gate used after generic replay_reasoning sidecar validation. It keeps
    /// a DeepSeek/OpenRouter frame from being inserted into a Mistral request if local state is
    static func mistralReplayAssistantMessages(
        _ messages: [[String: Any]]?
    ) -> [[String: Any]]? {
        guard let messages, !messages.isEmpty else { return nil }
        let allowedKeys: Set<String> = ["role", "content", "tool_calls"]
        guard messages.allSatisfy({ message in
            Set(message.keys).isSubset(of: allowedKeys)
                && message["role"] as? String == "assistant"
                && message["content"].map(validMistralContent) == true
                && (message["tool_calls"] == nil
                    || (message["tool_calls"] as? [[String: Any]]).map(validOpenAIToolCalls) == true)
        }) else { return nil }
        return messages
    }

    static func validMistralContent(_ content: Any) -> Bool {
        if content is String { return true }
        guard let blocks = content as? [[String: Any]], !blocks.isEmpty else { return false }
        return blocks.allSatisfy { block in
            guard let type = block["type"] as? String else { return false }
            switch type {
            case "text":
                return block["text"] is String
            case "thinking":
                guard let parts = block["thinking"] as? [[String: Any]] else { return false }
                return parts.allSatisfy {
                    $0["type"] as? String == "text" && $0["text"] is String
                }
            default:
                return false
            }
        }
    }

    static func validOpenAIToolCalls(_ calls: [[String: Any]]) -> Bool {
        calls.allSatisfy { call in
            guard let id = call["id"] as? String, !id.isEmpty,
                  call["type"] as? String == "function",
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty,
                  function["arguments"] is String else { return false }
            return true
        }
    }
    static func formulaToolResult(callID: String, name: String, output: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": callID, "name": name, "content": output]
    }

    static func mayExecute(_ recipe: MetadataClient.CapabilityRecipe) -> Bool {
        recipe.executionKind != "external_connector" && recipe.executionKind != "unavailable"
    }

    /// Applies only a validated, owner-scoped body fragment to the already-built production body.
    /// Builder-owned roots are rejected by the lossless compiler, so this cannot alter model,
    /// messages, auth, endpoint, or stream selection. The caller receives the same error that
    /// prevents a network request; there is no permissive fallback.
    static func applySafeCustomFragments(
        _ fragments: [SafeCustomBodyFragment], to body: inout [String: Any],
        providerKind: ProviderKind, modelID: String, transport: String
    ) throws {
        guard !fragments.isEmpty else { return }
        var seenOwners: Set<String> = []
        for fragment in fragments {
            guard seenOwners.insert(fragment.owner).inserted else {
                throw ProviderServiceError.invalidConfiguration(detail: "Rejected safe custom fragment: duplicate_owner")
            }
            // `SafeCustomBodyFragment` crosses app-layer boundaries, so its owner map is input,
            // not authority. The active exact controlDefinitions chain is the only production
            // source for this transport's leaf ownership schema.
            guard let authority = safeFragmentAuthority(
                owner: fragment.owner, providerKind: providerKind, modelID: modelID, transport: transport
            ) else {
                throw ProviderServiceError.invalidConfiguration(detail: "Rejected safe custom fragment: unknown_path")
            }
            switch SafeCustomFragmentCompiler.compile(
                raw: fragment.raw, owner: fragment.owner, declaredOwners: authority.owners
            ) {
            case let .success(delta):
                guard !delta.isEmpty, validateCustomValues(delta, definitions: authority.definitions) else {
                    throw ProviderServiceError.invalidConfiguration(detail: "Rejected safe custom fragment: invalid_value")
                }
                let activeDelta = activeCustomDelta(
                    delta,
                    owner: fragment.owner,
                    providerKind: providerKind,
                    transport: transport,
                    identity: CapabilityEvidenceRequestContext.current
                )
                guard !activeDelta.isEmpty else { continue }
                try mergeSafeCustom(activeDelta, into: &body)
                CapabilityExecutionRuntime.recordCustomDelta(
                    owner: fragment.owner,
                    pointers: Set(redactedPointers(activeDelta)),
                    finalTransport: transport
                )
            case let .failure(reason):
                throw ProviderServiceError.invalidConfiguration(detail: "Rejected safe custom fragment: \(reason.rawValue)")
            }
        }
    }

    static func applySafeCustomFragment(
        _ fragment: SafeCustomBodyFragment?, to body: inout [String: Any],
        providerKind: ProviderKind, modelID: String, transport: String
    ) throws {
        try applySafeCustomFragments(
            fragment.map { [$0] } ?? [], to: &body,
            providerKind: providerKind, modelID: modelID, transport: transport
        )
    }

    /// The developer editor uses this exact production authorization boundary before it writes its
    /// local-only draft.  The returned strings intentionally contain pointers only, never values:
    /// a preview must not become another route for custom JSON into diagnostics or telemetry.
    static func redactedSafeCustomPreview(
        raw: String, owner: String = "generation", providerKind: ProviderKind, modelID: String, transport: String
    ) -> Result<[String], SafeCustomFragmentCompiler.Rejection> {
        guard let authority = safeFragmentAuthority(
            owner: owner, providerKind: providerKind, modelID: modelID, transport: transport
        ) else { return .failure(.unknownPath) }
        switch SafeCustomFragmentCompiler.compile(
            raw: raw, owner: owner, declaredOwners: authority.owners
        ) {
        case let .success(delta):
            guard !delta.isEmpty, validateCustomValues(delta, definitions: authority.definitions) else {
                return .failure(.invalidValue)
            }
            return .success(redactedPointers(delta))
        case let .failure(reason): return .failure(reason)
        }
    }

    static func safeCustomAllowedPaths(
        owner: String, providerKind: ProviderKind, modelID: String, transport: String
    ) -> [String] {
        safeFragmentAuthority(
            owner: owner, providerKind: providerKind, modelID: modelID, transport: transport
        )?.owners.keys.sorted() ?? []
    }

    static func hasSafeCustomSchema(
        owner: String, providerKind: ProviderKind, modelID: String, transport: String
    ) -> Bool {
        safeFragmentAuthority(
            owner: owner, providerKind: providerKind, modelID: modelID, transport: transport
        ) != nil
    }

    static func displayTransport(provider: Provider, model: AIModel) -> String? {
        if provider.kind == .relay { return relayLocalTransport(provider: provider, model: model) }
        return MetadataClient.shared.syncResolveCatalogModel(
            modelID: model.id, providerKind: provider.kind
        )?.transport
    }

    static func finalTransport(owner: String, provider: Provider, model: AIModel) -> String? {
        if provider.kind == .relay { return relayLocalTransport(provider: provider, model: model) }
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        )
        if let recipeRef = snapshot.controls?[owner]?.recipeRef,
           let recipe = snapshot.runtime?.recipes[recipeRef],
           recipe.executionKind == "endpoint_route" {
            return recipe.transport.protocolName
        }
        return MetadataClient.shared.syncResolveCatalogModel(
            modelID: model.id, providerKind: provider.kind
        )?.transport
    }

    private static func relayLocalTransport(provider: Provider, model: AIModel) -> String? {
        GenerationParameterAvailability.profile(provider: provider, model: model)?.transport
    }

    static func customControlRiskTiers(
        owner: String, providerKind: ProviderKind, modelID: String, transport: String
    ) -> [String] {
        guard let authority = safeFragmentAuthority(
            owner: owner, providerKind: providerKind, modelID: modelID, transport: transport
        ) else { return [] }
        var present = Set<String>()
        for definition in authority.definitions.values {
            guard case let .string(tier) = definition["riskTier"] else { continue }
            present.insert(tier)
        }
        return ["privacy_impacting", "cost_impacting"].filter(present.contains)
    }

    static func officialCustomDocumentationURL(
        owner: String, providerKind: ProviderKind, modelID: String, transport: String
    ) -> URL? {
        guard providerKind != .relay,
              safeFragmentAuthority(
                  owner: owner, providerKind: providerKind, modelID: modelID, transport: transport
              ) != nil else { return nil }
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: modelID, providerKind: providerKind
        )
        guard let runtime = snapshot.runtime,
              let refs = snapshot.controls?[owner]?.customControlRefs else { return nil }
        for ref in refs {
            guard case let .object(definition) = runtime.controlDefinitions[ref],
                  case let .string(definitionOwner) = definition["owner"], definitionOwner == owner,
                  case let .array(sourceValues) = definition["sourceRefs"] else { return nil }
            for sourceValue in sourceValues {
                guard case let .string(sourceRef) = sourceValue,
                      case let .object(source) = runtime.sourceIndex[sourceRef],
                      case let .string(kind) = source["kind"], kind == "official_doc",
                      case let .string(rawURL) = source["url"], rawURL.hasPrefix("https://") else { return nil }
                if let url = URL(string: rawURL) { return url }
            }
        }
        return nil
    }

    /// The UI may expose documentation only when the exact catalog-selected generation recipe
    /// carries an official source reference. This preserves the recipe -> sourceRefs ->
    /// sourceIndex authority chain and intentionally has no provider-name fallback.
    static func officialGenerationDocumentationURL(
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        control: MetadataClient.CapabilityControl?
    ) -> URL? {
        guard let recipeRef = control?.recipeRef,
              let recipe = runtime.recipes[recipeRef],
              let sourceRef = recipe.sourceRefs?.first,
              case let .object(source) = runtime.sourceIndex[sourceRef],
              case let .string(kind) = source["kind"], kind == "official_doc",
              case let .string(rawURL) = source["url"], rawURL.hasPrefix("https://")
        else { return nil }
        return URL(string: rawURL)
    }

    private struct SafeCustomAuthority {
        let owners: [String: String]
        /// Relay profiles predate typed custom definitions; exact local wires still provide path
        /// authority. Official controls must also validate values against these catalog definitions.
        let definitions: [String: [String: MetadataClient.JSONValue]]
    }

    private static func safeFragmentAuthority(
        owner: String, providerKind: ProviderKind, modelID: String, transport: String
    ) -> SafeCustomAuthority? {
        // A Relay has no catalog model-id recipe to infer from. Its configured, concrete transport
        // is the authority and is deliberately restricted to the local engine's declared profile.
        // `.auto` and legacy aliases fail closed rather than guessing a compatible body shape.
        if providerKind == .relay {
            guard let relayTransport = relayTransport(for: transport),
                  let profile = LocalEngineGenerationProfiles.profile(for: nil, transport: relayTransport)
            else { return nil }
            guard owner == "generation", let owners = safeFragmentOwners(profile: profile) else { return nil }
            return .init(owners: owners, definitions: [:])
        }
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: modelID, providerKind: providerKind
        )
        guard let runtime = snapshot.runtime,
              let control = snapshot.controls?[owner],
              customControlMatchesFinalTransport(
                  control: control, runtime: runtime, owner: owner,
                  providerKind: providerKind, modelID: modelID, transport: transport
              ),
              let refs = control.customControlRefs,
              !refs.isEmpty else { return nil }
        var owners: [String: String] = [:]
        var definitions: [String: [String: MetadataClient.JSONValue]] = [:]
        for ref in refs {
            guard case let .object(definition) = runtime.controlDefinitions[ref],
                  case let .string(id) = definition["id"], id == ref,
                  case let .string(definitionOwner) = definition["owner"], definitionOwner == owner,
                  case let .string(pointer) = definition["targetPointer"], safeCustomPointer(pointer),
                  safeCustomDefinition(definition),
                  case let .array(sourceValues) = definition["sourceRefs"], !sourceValues.isEmpty else { return nil }
            for sourceValue in sourceValues {
                guard case let .string(sourceRef) = sourceValue,
                      case let .object(source) = runtime.sourceIndex[sourceRef],
                      case let .string(kind) = source["kind"], kind == "official_doc",
                      case let .string(rawURL) = source["url"], rawURL.hasPrefix("https://") else { return nil }
            }
            guard owners.updateValue(owner, forKey: pointer) == nil else { return nil }
            definitions[pointer] = definition
        }
        return .init(owners: owners, definitions: definitions)
    }

    private static func safeCustomDefinition(_ definition: [String: MetadataClient.JSONValue]) -> Bool {
        guard case let .string(kind) = definition["kind"] else { return false }
        switch kind {
        case "boolean": return true
        case "enum":
            guard case let .array(values) = definition["values"], !values.isEmpty else { return false }
            return values.allSatisfy { if case .string = $0 { return true }; return false }
        case "integer_range":
            guard case let .number(minimum) = definition["min"],
                  case let .number(maximum) = definition["max"] else { return false }
            return minimum.rounded() == minimum && maximum.rounded() == maximum && minimum <= maximum
        default: return false
        }
    }

    private static func validateCustomValues(
        _ delta: [String: Any], definitions: [String: [String: MetadataClient.JSONValue]]
    ) -> Bool {
        for (pointer, definition) in definitions {
            guard let value = customValue(in: delta, pointer: pointer) else { continue }
            guard case let .string(kind) = definition["kind"] else { return false }
            switch kind {
            case "boolean":
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            case "enum":
                guard let string = value as? String,
                      case let .array(values) = definition["values"],
                      values.contains(where: {
                          if case let .string(allowed) = $0 { return allowed == string }
                          return false
                      }) else { return false }
            case "integer_range":
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue,
                      case let .number(minimum) = definition["min"],
                      case let .number(maximum) = definition["max"],
                      number.doubleValue >= minimum, number.doubleValue <= maximum else { return false }
            default: return false
            }
        }
        return true
    }

    private static func customValue(in delta: [String: Any], pointer: String) -> Any? {
        let segments = pointer.split(separator: "/").map(String.init)
        guard let first = segments.first else { return nil }
        return segments.dropFirst().reduce(delta[first] as Any?) { value, segment in
            (value as? [String: Any])?[segment]
        }
    }

    /// Definitions own body pointers, while the exact resolved model owns the final transport.
    /// An endpoint replacement is accepted only when this same control explicitly selects it.
    private static func customControlMatchesFinalTransport(
        control: MetadataClient.CapabilityControl,
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        owner: String,
        providerKind: ProviderKind,
        modelID: String,
        transport: String
    ) -> Bool {
        guard let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID, providerKind: providerKind
        ), !transport.isEmpty else { return false }
        let finalTransport = CapabilityRecipeRequestCompiler.canonicalTransport(transport)
        if let modelTransport = resolved.transport,
           CapabilityRecipeRequestCompiler.canonicalTransport(modelTransport) == finalTransport {
            return true
        }
        guard let recipeRef = control.recipeRef,
              let recipe = runtime.recipes[recipeRef],
              recipe.providerKind == runtimeProviderKind(providerKind),
              recipe.capability == owner,
              recipe.executionKind == "endpoint_route",
              CapabilityRecipeRequestCompiler.canonicalTransport(recipe.transport.protocolName) == finalTransport
        else { return false }
        return true
    }

    private static func runtimeProviderKind(_ providerKind: ProviderKind) -> String {
        switch providerKind {
        case .together: return "togetherAI"
        case .fireworks: return "fireworksAI"
        default: return providerKind.rawValue
        }
    }

    private static func safeCustomPointer(_ pointer: String) -> Bool {
        guard pointer.hasPrefix("/"), pointer.count > 1 else { return false }
        let segments = pointer.dropFirst().split(separator: "/").map(String.init)
        let forbiddenRoots: Set<String> = [
            "auth", "headers", "query", "endpoint", "base_url", "transport_route", "model_route",
            "continuation_state", "model", "messages", "input", "contents", "prompt", "attachments",
            "instructions", "system", "stream", "stream_options", "tools", "tool_choice", "plugins",
        ]
        let forbiddenSegments: Set<String> = ["__proto__", "prototype", "constructor"]
        return !segments.isEmpty && !forbiddenRoots.contains(segments[0].lowercased())
            && segments.allSatisfy { segment in
                !segment.isEmpty && !forbiddenSegments.contains(segment.lowercased())
                    && segment.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
            }
    }

    private static func safeFragmentOwners(profile: GenerationProfileRef) -> [String: String]? {
        guard let wire = profile.wire else { return nil }
        var owners: [String: String] = [:]
        for path in wire.values {
            let segments = path.split(separator: ".").map(String.init)
            guard !segments.isEmpty,
                  segments.allSatisfy({
                      $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
                  }),
                  !["model", "messages", "input", "contents", "instructions", "system", "stream", "tools"]
                    .contains(segments[0].lowercased()) else { continue }
            owners["/" + segments.joined(separator: "/")] = "generation"
        }
        return owners.isEmpty ? nil : owners
    }

    private static func relayTransport(for transport: String) -> RelayTransport? {
        switch CapabilityRecipeRequestCompiler.canonicalTransport(transport) {
        case "openai_chat", "openai_chat_completions": return .openaiChatCompletions
        case "openai_responses": return .openaiResponses
        case "anthropic_messages": return .anthropicMessages
        case "gemini_generate_content": return .geminiGenerateContent
        case "llamacpp_native": return .llamacppNative
        default: return nil
        }
    }

    static func redactedPointers(_ delta: [String: Any]) -> [String] {
        var pointers: [String] = []
        func visit(_ value: Any, path: String) {
            if let object = value as? [String: Any], !object.isEmpty {
                for key in object.keys.sorted() {
                    if let child = object[key] { visit(child, path: "\(path)/\(key)") }
                }
            } else {
                pointers.append(path.isEmpty ? "/" : path)
            }
        }
        visit(delta, path: "")
        return pointers.sorted()
    }

    static func activeCustomDelta(
        _ delta: [String: Any],
        owner: String,
        providerKind: ProviderKind,
        transport: String,
        identity: CapabilityEvidenceRequestIdentity?,
        cache: UnsupportedParamCache = .shared
    ) -> [String: Any] {
        guard let exact = identity?.resolvingCapabilityRuntimeTransport(transport) else { return delta }
        let dormant = !cache.customRejectedPointers(
            providerKind: providerKind,
            modelID: exact.query.effectiveModelID,
            owner: owner,
            identity: exact
        ).isEmpty
        return dormant ? [:] : delta
    }


    /// Merges only object parents so a custom nested generation leaf cannot erase a sibling
    /// injected by the recipe/typed builder.  A leaf collision is a conflict, never an override.
    private static func mergeSafeCustom(_ delta: [String: Any], into body: inout [String: Any]) throws {
        for (key, incoming) in delta {
            guard let existing = body[key] else {
                body[key] = incoming
                continue
            }
            guard var existingObject = existing as? [String: Any],
                  let incomingObject = incoming as? [String: Any] else {
                throw ProviderServiceError.invalidConfiguration(detail: "Safe custom fragment conflicts with production body.")
            }
            try mergeSafeCustom(incomingObject, into: &existingObject)
            body[key] = existingObject
        }
    }
}

/// Lossless enough for the one security property JSONDecoder cannot offer: duplicate keys must be
/// rejected *before* decoding. Accepted fragments are then constrained to catalog-declared body paths.
enum SafeCustomFragmentCompiler {
    enum Rejection: String, Error, Equatable {
        case duplicateJSONKey = "duplicate_json_key", forbiddenRoot = "forbidden_root", forbiddenChannel = "forbidden_channel"
        case forbiddenKey = "forbidden_key", tooLarge = "too_large", depthExceeded = "depth_exceeded", nodeLimitExceeded = "node_limit_exceeded", crossOwner = "cross_owner", unknownPath = "unknown_path", invalidJSON = "invalid_json"
        case invalidValue = "invalid_value"
    }

    static func compile(raw: String, owner: String, declaredOwners: [String: String]) -> Result<[String: Any], Rejection> {
        guard raw.utf8.count <= 65_536 else { return .failure(.tooLarge) }
        var parser = LosslessJSONFragmentParser(raw)
        switch parser.validate() {
        case .success: break
        case .duplicateKey: return .failure(.duplicateJSONKey)
        case .tooDeep: return .failure(.depthExceeded)
        case .tooManyNodes: return .failure(.nodeLimitExceeded)
        case .invalid: return .failure(.invalidJSON)
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.invalidJSON) }
        return validate(value: object, owner: owner, declaredOwners: declaredOwners, path: "", depth: 0).map { object }
    }

    private static func validate(
        value: Any, owner: String, declaredOwners: [String: String], path: String, depth: Int
    ) -> Result<Void, Rejection> {
        guard depth <= 32 else { return .failure(.depthExceeded) }
        if let array = value as? [Any] {
            // Array indexes are values, not independent ownership channels. Keep the owning
            // pointer while recursively inspecting every object hidden in the array.
            for item in array {
                switch validate(value: item, owner: owner, declaredOwners: declaredOwners, path: path, depth: depth + 1) {
                case .success: break
                case let .failure(error): return .failure(error)
                }
            }
            return .success(())
        }
        guard let object = value as? [String: Any] else { return .success(()) }
        for (key, child) in object {
            let lowered = key.lowercased()
            if ["model", "messages", "input", "contents", "instructions", "system", "stream", "prompt", "attachments", "stream_options", "tools", "tool_choice", "plugins"].contains(lowered) { return .failure(.forbiddenRoot) }
            if ["auth", "authorization", "headers", "header", "endpoint", "baseurl", "base_url", "url", "query", "transport_route", "model_route", "continuation_state"].contains(lowered) { return .failure(.forbiddenChannel) }
            if ["__proto__", "prototype", "constructor"].contains(lowered) { return .failure(.forbiddenKey) }
            let pointer = "\(path)/\(key)"
            // Ownership is declared for actual leaves. Requiring a duplicate declaration for
            // every object parent either lets a parent claim all descendants or makes legitimate
            // nested protocol paths impossible. Arrays have no stable index pointer, so their
            // container is the leaf ownership boundary while every nested object is still scanned.
            if let objectChild = child as? [String: Any] {
                // An empty object has no nested leaf to authorize; accepting it would create a
                // parent-level ownership escape hatch. Non-empty parents only route recursion.
                if objectChild.isEmpty {
                    guard let declaredOwner = declaredOwners[pointer] else { return .failure(.unknownPath) }
                    guard declaredOwner == owner else { return .failure(.crossOwner) }
                }
                switch validate(value: child, owner: owner, declaredOwners: declaredOwners, path: pointer, depth: depth + 1) {
                case .success: break
                case let .failure(error): return .failure(error)
                }
                continue
            }
            guard let declaredOwner = declaredOwners[pointer] else { return .failure(.unknownPath) }
            guard declaredOwner == owner else { return .failure(.crossOwner) }
            switch validate(value: child, owner: owner, declaredOwners: declaredOwners, path: pointer, depth: depth + 1) {
            case .success: break
            case let .failure(error): return .failure(error)
            }
        }
        return .success(())
    }

}

/// A small lossless JSON tokenizer/parser for security validation. Foundation's JSON decoders overwrite
/// duplicate object keys, so they cannot be used as the first parser for an untrusted fragment.
nonisolated struct LosslessJSONFragmentParser {
    enum Outcome { case success, duplicateKey, tooDeep, tooManyNodes, invalid }
    private let bytes: [UInt8]
    private var cursor = 0
    private var nodes = 0
    private static let maxDepth = 32
    private static let maxNodes = 2_048

    init(_ raw: String) { bytes = Array(raw.utf8) }

    mutating func validate() -> Outcome {
        do {
            skipWhitespace(); try value(depth: 0); skipWhitespace()
            return cursor == bytes.count ? .success : .invalid
        } catch let error as ParseError {
            switch error { case .duplicate: return .duplicateKey; case .deep: return .tooDeep; case .nodes: return .tooManyNodes; case .invalid: return .invalid }
        } catch { return .invalid }
    }

    private enum ParseError: Error { case duplicate, deep, nodes, invalid }
    private mutating func value(depth: Int) throws {
        guard depth <= Self.maxDepth else { throw ParseError.deep }
        nodes += 1; guard nodes <= Self.maxNodes else { throw ParseError.nodes }
        skipWhitespace(); guard cursor < bytes.count else { throw ParseError.invalid }
        switch bytes[cursor] {
        case 123: try object(depth: depth + 1)
        case 91: try array(depth: depth + 1)
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw ParseError.invalid
        }
    }

    private mutating func object(depth: Int) throws {
        guard depth <= Self.maxDepth else { throw ParseError.deep }
        try consume(123); skipWhitespace(); if accept(125) { return }
        var keys = Set<String>()
        while true {
            skipWhitespace(); let key = try string()
            guard keys.insert(key).inserted else { throw ParseError.duplicate }
            skipWhitespace(); try consume(58); try value(depth: depth); skipWhitespace()
            if accept(125) { return }; try consume(44)
        }
    }

    private mutating func array(depth: Int) throws {
        guard depth <= Self.maxDepth else { throw ParseError.deep }
        try consume(91); skipWhitespace(); if accept(93) { return }
        while true { try value(depth: depth); skipWhitespace(); if accept(93) { return }; try consume(44) }
    }

    private mutating func string() throws -> String {
        try consume(34); var scalars = String.UnicodeScalarView()
        while cursor < bytes.count {
            let byte = bytes[cursor]; cursor += 1
            if byte == 34 { return String(scalars) }
            guard byte >= 0x20 else { throw ParseError.invalid }
            if byte != 92 { // decode non-escaped UTF-8 as a scalar sequence via a tiny buffer.
                if byte < 0x80 { scalars.append(UnicodeScalar(byte)); continue }
                let start = cursor - 1
                while cursor < bytes.count, bytes[cursor] >= 0x80 { cursor += 1 }
                guard let text = String(bytes: bytes[start..<cursor], encoding: .utf8) else { throw ParseError.invalid }
                scalars.append(contentsOf: text.unicodeScalars); continue
            }
            guard cursor < bytes.count else { throw ParseError.invalid }; let escape = bytes[cursor]; cursor += 1
            switch escape {
            case 34, 92, 47: scalars.append(UnicodeScalar(escape))
            case 98: scalars.append("\u{08}")
            case 102: scalars.append("\u{0C}")
            case 110: scalars.append("\n")
            case 114: scalars.append("\r")
            case 116: scalars.append("\t")
            case 117:
                let first = try hexScalar()
                if (0xD800...0xDBFF).contains(first.value) {
                    try consume(92); try consume(117); let low = try hexScalar()
                    guard (0xDC00...0xDFFF).contains(low.value) else { throw ParseError.invalid }
                    let code = 0x10000 + ((first.value - 0xD800) << 10) + (low.value - 0xDC00)
                    guard let scalar = UnicodeScalar(code) else { throw ParseError.invalid }; scalars.append(scalar)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first.value) else { throw ParseError.invalid }; scalars.append(first)
                }
            default: throw ParseError.invalid
            }
        }
        throw ParseError.invalid
    }

    private mutating func hexScalar() throws -> UnicodeScalar {
        guard cursor + 4 <= bytes.count else { throw ParseError.invalid }
        var value: UInt32 = 0
        for byte in bytes[cursor..<(cursor + 4)] {
            let digit: UInt32
            switch byte { case 48...57: digit = UInt32(byte - 48); case 65...70: digit = UInt32(byte - 55); case 97...102: digit = UInt32(byte - 87); default: throw ParseError.invalid }
            value = value * 16 + digit
        }
        cursor += 4; guard let scalar = UnicodeScalar(value) else { throw ParseError.invalid }; return scalar
    }

    private mutating func number() throws {
        if accept(45) {} ; guard cursor < bytes.count else { throw ParseError.invalid }
        if accept(48) {} else { try digits() }
        if accept(46) { try digits() }
        if cursor < bytes.count, bytes[cursor] == 101 || bytes[cursor] == 69 { cursor += 1; _ = accept(43) || accept(45); try digits() }
    }
    private mutating func digits() throws { let start = cursor; while cursor < bytes.count, (48...57).contains(bytes[cursor]) { cursor += 1 }; guard cursor > start else { throw ParseError.invalid } }
    private mutating func literal(_ text: String) throws { for byte in text.utf8 { try consume(byte) } }
    private mutating func consume(_ byte: UInt8) throws { guard accept(byte) else { throw ParseError.invalid } }
    private mutating func accept(_ byte: UInt8) -> Bool { guard cursor < bytes.count, bytes[cursor] == byte else { return false }; cursor += 1; return true }
    private mutating func skipWhitespace() { while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
}
