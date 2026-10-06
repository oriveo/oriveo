import Foundation

enum GenerationWireDiagnostics {
    struct Entry: Equatable, Sendable {
        let parameterID: String
        let wirePath: String
        let reason: ProfileParamsResolver.WireRejectionReason
    }

    private static let capacity = 50
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    static func record(parameterID: String, wirePath: String, reason: ProfileParamsResolver.WireRejectionReason) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(parameterID: parameterID, wirePath: wirePath, reason: reason))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    static func read() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

/// Per-item outcome of the generation-parameter writer. The rules live in the shared contract
/// `generation_parameter_contract.v1.json#outboundRules`: an invalid item drops only itself, and
/// the list is returned so the interface can point at it.
struct GenerationParameterApplication: Equatable, Sendable {
    enum DropReason: String, CaseIterable, Equatable, Sendable {
        case invalidValue = "invalid_value"
        case conflict
        case requirementUnmet = "requirement_unmet"
        case requiredField = "required_field"
        case thinkingIncompatible = "thinking_incompatible"
        case thinkingBudget = "thinking_budget"
    }

    struct Dropped: Equatable, Sendable {
        let parameterID: String
        let reason: DropReason
    }

    /// Sorted by parameterID, the same order every client and the contract cases use.
    private(set) var dropped: [Dropped] = []
    /// Wire path → parameter ID for values the user set explicitly in this request, so a later
    /// guard can attribute a change back to its parameter.
    var appliedWirePaths: [String: String] = [:]

    /// Nothing was dropped.
    var isClean: Bool { dropped.isEmpty }

    mutating func drop(_ parameterID: String, _ reason: DropReason) {
        guard !dropped.contains(where: { $0.parameterID == parameterID }) else { return }
        dropped.append(.init(parameterID: parameterID, reason: reason))
        dropped.sort { $0.parameterID < $1.parameterID }
    }
}

enum ProfileParamsResolver {
    enum WireRejectionReason: String, Equatable, Sendable {
        case blockedSegment = "blocked_segment"
        case invalidSegment = "invalid_segment"
        case depthExceeded = "depth_exceeded"
        case ownedRootField = "owned_root_field"
    }

    private static let blockedWireSegments: Set<String> = ["__proto__", "prototype", "constructor"]
    private static let maxWireSegments = 4
    private static let builderOwnedRootFields: Set<String> = [
        "model", "messages", "input", "contents", "prompt", "attachments", "instructions", "system", "stream", "stream_options", "tools", "tool_choice", "plugins",
    ]
    private static let jsonSchemaMaxBytes = 64 * 1024
    // Per-item evaluation constants (shared contract #outboundRules; reconciled by contract tests).
    /// Presence keys the builder already wrote into the body: they take part in conflict
    /// evaluation but are not user parameters.
    static let builderPresenceKeys = ["tools"]
    /// Wire fields the upstream requires: `omit` must not remove them, the builder default stays.
    static let requiredWireFields: [String: Set<String>] = ["anthropic_messages": ["max_tokens"]]
    static let anthropicThinkingActiveTypes: Set<String> = ["enabled", "adaptive"]
    static let anthropicThinkingDroppedParameters = ["temperature", "top_k"]
    static let anthropicThinkingTopPMin = 0.95
    static let anthropicThinkingMaxTokensHeadroom = 4096

    static func wireRejectionReason(_ wirePath: String) -> WireRejectionReason? {
        let segments = wirePath.components(separatedBy: ".")
        for segment in segments {
            if blockedWireSegments.contains(segment) { return .blockedSegment }
            if !isValidWireSegment(segment) { return .invalidSegment }
        }
        if segments.count > maxWireSegments { return .depthExceeded }
        if let root = segments.first, builderOwnedRootFields.contains(root) { return .ownedRootField }
        return nil
    }

    private static func isValidWireSegment(_ segment: String) -> Bool {
        guard let first = segment.unicodeScalars.first, isASCIILetterOrUnderscore(first) else { return false }
        return segment.unicodeScalars.allSatisfy { isASCIILetterOrUnderscore($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetterOrUnderscore(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_"
    }

    /// The single writer for generation parameters. Evaluation is per item: a parameter with an
    /// invalid value, a conflict or an unmet requirement drops only itself and the rest is still
    /// written; the result lists what was dropped.
    @discardableResult
    static func applyGenerationParameters(
        to body: inout [String: Any],
        options: ChatRequestOptions,
        profile: GenerationProfileRef? = nil,
        finalRequest: URLRequest? = nil,
        effectiveTransport: String? = nil
    ) -> GenerationParameterApplication {
        var application = GenerationParameterApplication()
        guard let overrides = options.generationParameters?.values else { return application }

        let requestedProfile = profile ?? options.generationProfile
        let transport = effectiveTransport ?? requestedProfile?.transport ?? ""
        let finalProfile: GenerationProfileRef? = {
            guard CapabilityEvidenceRequestContext.current?.query.providerKind == ProviderKind.relay.rawValue,
                  let relayTransport = RelayTransport(rawValue: transport) else {
                return requestedProfile
            }
            return CapabilityEvidenceProductionAdapter.mergeRelayDeclaration(
                LocalEngineGenerationProfiles.profile(
                    for: options.relayRequested?.engineProfile,
                    transport: relayTransport
                ),
                requestedProfile
            )
        }()
        var runtimeGenerationAuthorized = false
        var runtimeGenerationRecipe: MetadataClient.CapabilityRecipe?
        var runtimeGenerationEnvelope: MetadataClient.CapabilityRuntimeEnvelope?
        if let current = CapabilityEvidenceRequestContext.current,
           let providerKind = ProviderKind(rawValue: current.query.providerKind) {
            let authorization = CapabilityRecipeRequestCompiler.generationTemplate(
                providerKind: providerKind, modelID: current.query.modelID, transport: transport
            )
            // Runtime delivery suppresses legacy profile authority. A valid exact recipe delegates
            // only to the already typed profile bearing the recipe's declared template.
            if authorization.runtimeDelivered,
               !CapabilityRecipeRequestCompiler.legacyGenerationTemplatesMatch(
                   runtimeTemplate: authorization.template,
                   profileTemplate: finalProfile?.template
               ) {
                return application
            }
            runtimeGenerationAuthorized = authorization.runtimeDelivered
            runtimeGenerationRecipe = authorization.recipe
            runtimeGenerationEnvelope = authorization.runtime
        }
        let scopedIdentity: CapabilityEvidenceRequestIdentity? = {
            if let finalRequest {
                return CapabilityEvidenceRequestContext.generationScope(
                    for: finalRequest,
                    effectiveTransport: transport,
                    relayEngineProfile: options.relayRequested?.engineProfile,
                    relayDeclaredProfile: requestedProfile
                )
            }
            return CapabilityEvidenceRequestContext.current
        }()
        let explicitParameterIDs = Set(overrides.compactMap { key, override in
            override.state == .value ? UnsupportedParamClassifier.normalize(key) : nil
        })
        let projection = CapabilityEvidenceProductionAdapter.generationRequestProjection(
            identity: scopedIdentity,
            relayEngineProfile: options.relayRequested?.engineProfile,
            relayDeclaredProfile: requestedProfile,
            explicitParameterIDs: explicitParameterIDs
        )
        guard let profile = (runtimeGenerationAuthorized ? finalProfile : projection.profile),
              let wire = profile.wire,
              !wire.isEmpty else {
            return application
        }
        func permitsOutbound(_ key: String) -> Bool {
            if runtimeGenerationAuthorized {
                return wire[UnsupportedParamClassifier.normalize(key)]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            return projection.permitsOutbound(key)
        }
        func pointer(for key: String) -> String? {
            guard let wirePath = wire[key], wireRejectionReason(wirePath) == nil else { return nil }
            return "/" + wirePath.split(separator: ".").map {
                String($0).replacingOccurrences(of: "~", with: "~0")
                    .replacingOccurrences(of: "/", with: "~1")
            }.joined(separator: "/")
        }
        let dormantPointers: Set<String> = {
            guard let recipe = runtimeGenerationRecipe,
                  let identity = scopedIdentity,
                  let providerKind = ProviderKind(rawValue: identity.query.providerKind) else { return [] }
            return UnsupportedParamCache.shared.recipeRejectedPointers(
                providerKind: providerKind,
                modelID: identity.query.effectiveModelID,
                owner: RequestPreferenceOwner.generation.rawValue,
                recipeRef: recipe.id,
                identity: identity
            )
        }()
        guard let pointersToOmit = CapabilityRecipeRequestCompiler.runtimeOwnedOmission(
            dormantPointers: dormantPointers,
            source: .providerRecipe,
            owner: RequestPreferenceOwner.generation.rawValue,
            recipeRef: runtimeGenerationRecipe?.id,
            runtimeRevision: runtimeGenerationEnvelope?.revision ?? "",
            descriptor: CapabilityRecipeResendContext.recoveryDescriptor
        ) else { return application }
        func isOmitted(_ key: String) -> Bool {
            pointer(for: key).map(pointersToOmit.contains) ?? false
        }

        let candidates = overrides.filter { key, override in
            override.state == .value && permitsOutbound(key) && !isOmitted(key)
        }
        let presence = Set(builderPresenceKeys.filter { body[$0] is [Any] })
        let evaluation = evaluateOutbound(candidates: candidates, profile: profile, builderPresence: presence)
        for (key, reason) in evaluation.dropped { application.drop(key, reason) }
        let kept = evaluation.kept
        let active = kept.union(presence)
        let required = requiredWireFields[profile.template ?? ""] ?? []

        var appliedPointers = Set<String>()
        for (key, override) in overrides {
            guard override.state != .inherit,
                  let wirePath = wire[key] else { continue }
            if override.state == .value, (!permitsOutbound(key) || isOmitted(key)) { continue }
            if let reason = wireRejectionReason(wirePath) {
                GenerationWireDiagnostics.record(parameterID: key, wirePath: wirePath, reason: reason)
                continue
            }

            switch override.state {
            case .inherit:
                break
            case .omit:
                if required.contains(wirePath) {
                    application.drop(key, .requiredField)
                    continue
                }
                removeValue(in: &body, path: wirePath.split(separator: ".").map(String.init))
            case .value:
                guard kept.contains(key), let rawValue = override.value else { continue }
                application.appliedWirePaths[wirePath] = key
                applySpecializedOutputContract(
                    rawValue,
                    parameterID: key,
                    template: profile.template,
                    fallbackPath: wirePath,
                    body: &body
                )
                if let pointer = pointer(for: key) { appliedPointers.insert(pointer) }
            }
        }
        if let recipe = runtimeGenerationRecipe, let runtime = runtimeGenerationEnvelope {
            CapabilityExecutionRuntime.recordCompiledDelta(
                recipe: recipe,
                runtime: runtime,
                finalTransport: transport,
                deltaIsNonEmpty: !appliedPointers.isEmpty,
                deltaRootKeys: Set(appliedPointers.compactMap {
                    $0.dropFirst().split(separator: "/").first.map(String.init)
                }),
                ownedPointers: appliedPointers,
                capabilityKeys: active,
                includeExecutionFact: false
            )
        }
        return application
    }

    /// The pure part of per-item evaluation (it never touches the body, so the interface can reuse
    /// it): invalid values go first, then items are admitted in the order the profile declares
    /// them. A later item that conflicts with an admitted one or with a builder presence key is
    /// dropped, and an item whose requirement is unmet drops only itself.
    static func evaluateOutbound(
        candidates: [String: GenerationParameterOverride],
        profile: GenerationProfileRef,
        builderPresence: Set<String>
    ) -> (kept: Set<String>, dropped: [String: GenerationParameterApplication.DropReason]) {
        var dropped: [String: GenerationParameterApplication.DropReason] = [:]
        var definitions: [String: GenerationParameterRef] = [:]
        var declaredOrder: [String] = []
        for parameter in profile.parameters ?? [] {
            guard let id = parameter.id, definitions[id] == nil else { continue }
            definitions[id] = parameter
            declaredOrder.append(id)
        }
        var valid: Set<String> = []
        for (key, override) in candidates {
            guard let value = override.value,
                  definitions[key].map({ isValidGenerationValue(value, for: $0) }) ?? true else {
                dropped[key] = .invalidValue
                continue
            }
            valid.insert(key)
        }
        let order = declaredOrder.filter(valid.contains)
            + valid.subtracting(declaredOrder).sorted()
        var kept: [String] = []
        for key in order {
            let occupied = Set(kept).union(builderPresence)
            let declaresConflict = definitions[key]?.conflictsWith?.contains(where: occupied.contains) == true
            let isConflictedBy = kept.contains { definitions[$0]?.conflictsWith?.contains(key) == true }
            if declaresConflict || isConflictedBy {
                dropped[key] = .conflict
            } else {
                kept.append(key)
            }
        }
        // Dropping one item can leave another item's requirement unmet, so iterate to a fixed
        // point; a profile has at most a few dozen parameters, so the cost is negligible.
        var changed = true
        while changed {
            changed = false
            let active = Set(kept).union(builderPresence)
            for key in kept {
                let unmet = definitions[key]?.requires?.contains(where: { requirement in
                    guard case .string(let required)? = requirement["key"], active.contains(required) else { return true }
                    if let expected = requirement["value"], candidates[required]?.value != expected { return true }
                    return false
                }) == true
                guard unmet else { continue }
                dropped[key] = .requirementUnmet
                kept.removeAll { $0 == key }
                changed = true
                break
            }
        }
        return (Set(kept), dropped)
    }

    /// Keeps an Anthropic request valid while thinking is on (shared contract
    /// #outboundRules.anthropicThinking). The capability writer adds the thinking fields after the
    /// generation parameters, so call this once it has run; with thinking off nothing changes.
    @discardableResult
    static func applyAnthropicThinkingGuard(
        to body: inout [String: Any],
        application: GenerationParameterApplication,
        builderDefaultMaxTokens: Int?
    ) -> GenerationParameterApplication {
        var application = application
        guard let thinking = body["thinking"] as? [String: Any],
              let type = thinking["type"] as? String,
              anthropicThinkingActiveTypes.contains(type) else { return application }
        func strip(_ wirePath: String) {
            guard body[wirePath] != nil else { return }
            body.removeValue(forKey: wirePath)
            if let parameterID = application.appliedWirePaths.removeValue(forKey: wirePath) {
                application.drop(parameterID, .thinkingIncompatible)
            }
        }
        anthropicThinkingDroppedParameters.forEach(strip)
        if let topP = (body["top_p"] as? NSNumber)?.doubleValue, topP < anthropicThinkingTopPMin {
            strip("top_p")
        }
        guard let budget = (thinking["budget_tokens"] as? NSNumber)?.intValue,
              let maxTokens = (body["max_tokens"] as? NSNumber)?.intValue,
              maxTokens <= budget else { return application }
        if let parameterID = application.appliedWirePaths.removeValue(forKey: "max_tokens") {
            application.drop(parameterID, .thinkingBudget)
        }
        let fallback = builderDefaultMaxTokens ?? 0
        body["max_tokens"] = fallback > budget ? fallback : budget + anthropicThinkingMaxTokensHeadroom
        return application
    }

    private static func applySpecializedOutputContract(
        _ value: GenerationParameterValue,
        parameterID: String,
        template: String?,
        fallbackPath: String,
        body: inout [String: Any]
    ) {
        if parameterID == "json_schema", case .object = value {
            let schema = value.foundationValue
            switch template {
            case "openai_chat_completions", "vllm_extra_body":
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "oriveo_response", "strict": true, "schema": schema],
                ]
            case "openai_responses":
                setValue(
                    ["type": "json_schema", "name": "oriveo_response", "strict": true, "schema": schema],
                    in: &body,
                    path: ["text", "format"]
                )
            case "anthropic_messages":
                body["output_format"] = ["type": "json_schema", "schema": schema]
            case "gemini_generate_content":
                setValue("application/json", in: &body, path: ["generationConfig", "responseMimeType"])
                setValue(schema, in: &body, path: ["generationConfig", "responseJsonSchema"])
            default:
                return
            }
            return
        }
        if parameterID == "response_format", case .string(let format) = value {
            switch template {
            case "openai_chat_completions", "vllm_extra_body":
                body["response_format"] = ["type": format == "json" ? "json_object" : "text"]
            case "gemini_generate_content":
                setValue(
                    format == "json" ? "application/json" : "text/plain",
                    in: &body,
                    path: ["generationConfig", "responseMimeType"]
                )
            default:
                setValue(value.foundationValue, in: &body, path: fallbackPath.split(separator: ".").map(String.init))
            }
            return
        }
        setValue(value.foundationValue, in: &body, path: fallbackPath.split(separator: ".").map(String.init))
    }

    private static func setValue(_ value: Any, in body: inout [String: Any], path: [String]) {
        guard let key = path.first else { return }
        guard path.count > 1 else {
            body[key] = value
            return
        }
        var nested = body[key] as? [String: Any] ?? [:]
        setValue(value, in: &nested, path: Array(path.dropFirst()))
        body[key] = nested
    }

    private static func removeValue(in body: inout [String: Any], path: [String]) {
        guard let key = path.first else { return }
        guard path.count > 1 else {
            body.removeValue(forKey: key)
            return
        }
        guard var nested = body[key] as? [String: Any] else { return }
        removeValue(in: &nested, path: Array(path.dropFirst()))
        body[key] = nested
    }

    static func isValidGenerationValue(
        _ value: GenerationParameterValue,
        for parameter: GenerationParameterRef
    ) -> Bool {
        let number: Double?
        switch value {
        case .number(let candidate) where candidate.isFinite:
            number = candidate
        case .number:
            return false
        default:
            number = nil
        }

        switch parameter.valueSchema {
        case "number": guard number != nil else { return false }
        case "integer": guard let number, number.rounded() == number else { return false }
        case "string-list": if case .stringList(_) = value {} else { return false }
        case "boolean": if case .boolean(_) = value {} else { return false }
        case "json-schema":
            guard case .object(let schema) = value,
                  isWithinJSONSchemaByteLimit(value),
                  isValidJSONSchema(schema) else { return false }
        case "enum": if case .string(_) = value {} else { return false }
        default: break
        }

        if let enumValues = parameter.enumValues, !enumValues.isEmpty, !enumValues.contains(value) {
            return false
        }

        if let number {
            if let minimum = parameter.range?.min, number < minimum { return false }
            if let maximum = parameter.range?.max, number > maximum { return false }
            if let minimum = parameter.range?.minExclusive, number <= minimum { return false }
            if let maximum = parameter.range?.maxExclusive, number >= maximum { return false }
        }
        return true
    }

    private static func isWithinJSONSchemaByteLimit(_ value: GenerationParameterValue) -> Bool {
        guard JSONSerialization.isValidJSONObject(value.foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationValue) else { return false }
        return data.count <= jsonSchemaMaxBytes
    }

    private static func isValidJSONSchema(
        _ schema: [String: GenerationParameterValue],
        depth: Int = 0
    ) -> Bool {
        guard depth <= 32, !schema.isEmpty else { return false }
        if let type = schema["type"] {
            switch type {
            case .string, .stringList: break
            default: return false
            }
        }
        if let required = schema["required"], case .stringList = required {} else if schema["required"] != nil {
            return false
        }
        if let properties = schema["properties"] {
            guard case .object(let children) = properties else { return false }
            for child in children.values {
                guard case .object(let object) = child, isValidJSONSchema(object, depth: depth + 1) else { return false }
            }
        }
        return true
    }

    static func reasoningMergeParams(
        providerKind: ProviderKind,
        modelID: String,
        reasoningMode: ReasoningMode,
        resolved: MetadataClient.ResolvedModelMetadata?,
        droppedParams: Set<String> = [],
        allowLegacyProfile: Bool = false
    ) -> [String: Any]? {
        reasoningMergeParams(
            providerKind: providerKind,
            modelID: modelID,
            reasoningMode: reasoningMode,
            profileName: resolved?.profiles.reasoning,
            droppedParams: droppedParams,
            allowLegacyProfile: allowLegacyProfile
        )
    }

    static func reasoningMergeParams(
        providerKind: ProviderKind,
        modelID: String,
        reasoningMode: ReasoningMode,
        profileName: String?,
        droppedParams: Set<String> = [],
        allowLegacyProfile: Bool = false
    ) -> [String: Any]? {
        let relayOwned = providerKind == .relay
            || CapabilityEvidenceRequestContext.current?.query.providerKind == ProviderKind.relay.rawValue
        guard allowLegacyProfile || relayOwned else { return nil }
        guard let profileName,
              var merge = MetadataClient.shared.syncReasoningMergeParams(
                profileName: profileName,
                mode: reasoningMode
              )
        else { return nil }

        let dropSet = droppedParams
        if let stripped = UnsupportedParamJSON.strippedObject(
            merge,
            dropping: dropSet,
            pruneEmptyObjects: true
        ) {
            merge = stripped
        }
        return UnsupportedParamJSON.isEffectivelyEmpty(merge) ? nil : merge
    }

    static func webSearchMergeParams(
        providerKind: ProviderKind,
        modelID: String,
        profileName: String?,
        droppedParams: Set<String> = [],
        allowLegacyProfile: Bool = false
    ) -> [String: Any]? {
        let relayOwned = providerKind == .relay
            || CapabilityEvidenceRequestContext.current?.query.providerKind == ProviderKind.relay.rawValue
        guard allowLegacyProfile || relayOwned else { return nil }
        guard var merge = MetadataClient.shared.syncWebSearchMergeParams(profileName: profileName) else {
            return nil
        }
        let dropSet = droppedParams
        if let stripped = UnsupportedParamJSON.strippedObject(
            merge,
            dropping: dropSet,
            pruneEmptyObjects: true
        ) {
            merge = stripped
        }
        return UnsupportedParamJSON.isEffectivelyEmpty(merge) ? nil : merge
    }

    static func imageGenMergeParams(
        providerKind: ProviderKind,
        modelID: String,
        profileName: String?,
        droppedParams: Set<String> = []
    ) -> [String: Any]? {
        guard var merge = MetadataClient.shared.syncImageGenMergeParams(profileName: profileName) else {
            return nil
        }
        let dropSet = droppedParams
        if let stripped = UnsupportedParamJSON.strippedObject(
            merge,
            dropping: dropSet,
            pruneEmptyObjects: true
        ) {
            merge = stripped
        }
        return UnsupportedParamJSON.isEffectivelyEmpty(merge) ? nil : merge
    }

    /// Deep-merge profile params into the request body.
    /// Object values merge recursively. `tools` / `plugins` append owned entries, preserving base tools.
    static func deepMerge(_ target: inout [String: Any], _ source: [String: Any]) {
        for (key, value) in source {
            if var existing = target[key] as? [String: Any],
               let nested = value as? [String: Any] {
                deepMerge(&existing, nested)
                target[key] = existing
            } else if (key == "tools" || key == "plugins"), let existing = target[key] as? [Any], let incoming = value as? [Any] {
                target[key] = composeOwnedArray(base: existing, contribution: incoming)
            } else {
                target[key] = value
            }
        }
    }

    static func composeOwnedArray(base: [Any], contribution: [Any]) -> [Any] {
        var result = base
        var identities = Set(base.map(ownedArrayIdentity))
        for item in contribution where identities.insert(ownedArrayIdentity(item)).inserted { result.append(item) }
        return result
    }

    private static func ownedArrayIdentity(_ value: Any) -> String {
        guard let object = value as? [String: Any] else { return String(reflecting: value) }
        let type = object["type"] as? String ?? ""
        let name = object["name"] as? String ?? ""
        return "\(type):\(name.isEmpty ? canonicalJSON(object) : name)"
    }
    private static func canonicalJSON(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            let entries = object.keys.sorted().map { key in
                "\(String(reflecting: key)):\(canonicalJSON(object[key]!))"
            }
            return "{" + entries.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + array.map(canonicalJSON).joined(separator: ",") + "]"
        }
        return String(reflecting: value)
    }

    static func applyTemperatureGate(
        to body: inout [String: Any],
        resolved: MetadataClient.ResolvedModelMetadata?
    ) {
        if resolved?.supportsTemperature == false {
            body.removeValue(forKey: "temperature")
        }
    }
}
