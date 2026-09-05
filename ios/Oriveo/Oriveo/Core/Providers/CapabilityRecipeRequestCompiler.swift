import Foundation

/// Server `provider + exact model + transport + recipeRef`,
enum CapabilityRecipeRequestCompiler {
    struct LegacyInput: Sendable, Equatable {
        /// `false` means a capability runtime was delivered, so legacy profiles must
        /// not produce a second, ungoverned capability patch.
        let usesLegacyMapping: Bool
        let webSearchEnabled: Bool
        let reasoningMode: ReasoningMode
    }

    struct Compilation: Sendable {
        let applied: Bool
        let reason: String?
        let redactedPreview: [String: Any]
    }

    private enum RuntimeMode {
        case noAutomaticConfiguration
        case active(MetadataClient.CapabilityRuntimeEnvelope, [String: MetadataClient.CapabilityControl]?)
    }

    static func legacyInput(
        providerKind: ProviderKind,
        modelID: String,
        webSearchEnabled: Bool,
        reasoningMode: ReasoningMode
    ) -> LegacyInput {
        switch runtimeMode(providerKind: providerKind, modelID: modelID) {
        case .noAutomaticConfiguration:
            return .init(usesLegacyMapping: false, webSearchEnabled: false, reasoningMode: .automatic)
        case .active:
            return .init(usesLegacyMapping: false, webSearchEnabled: false, reasoningMode: .automatic)
        }
    }

    /// Generation remains a typed parameter projection, but runtime is its authorization source.
    /// A delivered runtime with a missing/mismatched generation control is an intentional zero-delta
    /// kill switch; callers must not revive the legacy profile in that state.
    static func generationTemplate(
        providerKind: ProviderKind, modelID: String, transport: String
    ) -> (
        runtimeDelivered: Bool,
        template: String?,
        recipe: MetadataClient.CapabilityRecipe?,
        runtime: MetadataClient.CapabilityRuntimeEnvelope?
    ) {
        // Relay is exempt from the kill switch, and the exemption is not a convenience:
        // a relay endpoint lives on the user's own machine and is never in the server catalog,
        // so it can *never* obtain a `generation` control. Applying the "runtime delivered but
        // no matching control ⇒ zero delta" rule to relay does not disable a capability for one
        // release - it makes relay generation parameters permanently dead, while the UI keeps
 // showing temperature / max_tokens / top_p / seed as set. That is the " / no-op"
        // Android already draws this line, and draws it in exactly this place -
        // `ProviderRequestProfiles.kt:474-477`: no runtime ⇒ relay keeps the full legacy
        // projection, while official providers keep the projection with `permitsOutbound = false`
        // half, so the two ends diverged on relay.
        if providerKind == .relay { return (false, nil, nil, nil) }
        guard case let .active(runtime, controls) = runtimeMode(
            providerKind: providerKind, modelID: modelID
        ) else { return (true, nil, nil, nil) }
        guard runtime.schemaVersion == RequestPreferenceResolver.runtimeSchemaVersion,
              let control = controls?["generation"],
              control.state == RequestControlAvailability.autoAvailable.rawValue,
              let ref = control.recipeRef, let recipe = runtime.recipes[ref],
              recipe.providerKind == runtimeProviderKind(providerKind),
              recipe.capability == "generation",
              canonicalTransport(recipe.transport.protocolName) == canonicalTransport(transport),
              recipe.executionKind == "request_overlay",
              recipe.requestOps.count == 1,
              recipe.requestOps[0].op == "legacy_generation_template",
              let template = recipe.requestOps[0].template,
              !template.isEmpty else { return (true, nil, nil, runtime) }
        return (true, template, recipe, runtime)
    }

    @discardableResult
    static func apply(
        to body: inout [String: Any],
        providerKind: ProviderKind,
        modelID: String,
        transport: String,
        webSearchEnabled: Bool,
        reasoningMode: ReasoningMode,
        capabilityPreferences: CapabilityPreferenceValues? = nil
    ) -> [Compilation] {
        guard case let .active(runtime, controls) = runtimeMode(
            providerKind: providerKind, modelID: modelID
        ) else {
            return []
        }
        CapabilityExecutionRuntime.freezeRuntimeEnvelope(runtime, controls: controls)
        guard runtime.schemaVersion == RequestPreferenceResolver.runtimeSchemaVersion else {
            return [.init(applied: false, reason: "unknown_schema_version", redactedPreview: [:])]
        }

        var results: [Compilation] = []
        let webIntent: String?
        switch capabilityPreferences?.web {
        case .inherit: webIntent = nil
        case .off: webIntent = nil
        case .automatic: webIntent = nil
        case .force: webIntent = "force"
        case .custom: webIntent = "custom"
        case nil: webIntent = nil
        }
        if capabilityPreferences?.web != .off,
           capabilityPreferences?.web != .inherit,
           (capabilityPreferences != nil || webSearchEnabled) {
            results.append(applyCapability(
                to: &body, capability: .web, selectedIntent: webIntent, providerKind: providerKind,
                transport: transport, runtime: runtime, controls: controls
            ))
        }
        // Presence of a typed value is authoritative even when its reasoning intent is nil:
        // nil means provider default, not “fall back to the old chip mirror”.
        let resolvedReasoningIntent: String?
        if let capabilityPreferences {
            resolvedReasoningIntent = capabilityPreferences.reasoningIntent
        } else {
            resolvedReasoningIntent = reasoningMode == .automatic ? nil : reasoningIntent(reasoningMode)
        }
        if let resolvedReasoningIntent {
            results.append(applyCapability(
                to: &body, capability: .reasoning, selectedIntent: resolvedReasoningIntent,
                providerKind: providerKind, transport: transport, runtime: runtime, controls: controls
            ))
        }
        return results
    }

 /// fixture production compiler hook:recipe registry/runtime
    static func compile(
        recipe: MetadataClient.CapabilityRecipe,
        providerKind: String,
        transport: String,
        capability: String,
        selectedIntent: String?,
        availableIntents: [String]? = nil,
        base: [String: Any]
    ) -> Compilation {
        var body = base
        return compile(
            recipe: recipe, to: &body, providerKind: providerKind, transport: transport,
            capability: capability, selectedIntent: selectedIntent,
            availableIntents: availableIntents, omittingPointers: []
        )
    }

    static func compile(
        recipeRef: String,
        recipes: [String: MetadataClient.CapabilityRecipe],
        providerKind: String,
        transport: String,
        capability: String,
        selectedIntent: String?,
        availableIntents: [String]? = nil,
        base: [String: Any]
    ) -> Compilation {
        guard let recipe = recipes[recipeRef] else {
            return .init(applied: false, reason: "recipe_not_found", redactedPreview: [:])
        }
        return compile(
            recipe: recipe, providerKind: providerKind, transport: transport,
            capability: capability, selectedIntent: selectedIntent,
            availableIntents: availableIntents, base: base
        )
    }

    private static func runtimeMode(
        providerKind: ProviderKind,
        modelID: String
    ) -> RuntimeMode {
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: modelID, providerKind: providerKind
        )
        guard let runtime = snapshot.runtime else { return .noAutomaticConfiguration }
        return .active(runtime, snapshot.controls)
    }

    private static func applyCapability(
        to body: inout [String: Any],
        capability: RequestPreferenceOwner,
        selectedIntent: String?,
        providerKind: ProviderKind,
        transport: String,
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        controls: [String: MetadataClient.CapabilityControl]?
    ) -> Compilation {
        guard let control = controls?[capability.rawValue],
              control.state == RequestControlAvailability.autoAvailable.rawValue,
              let recipeRef = control.recipeRef,
              let recipe = runtime.recipes[recipeRef] else {
            return .init(applied: false, reason: "no_auto_config", redactedPreview: [:])
        }
        let dispatchIdentity = CapabilityEvidenceRequestContext.current?
            .resolvingCapabilityRuntimeTransport(transport)?
            .resolvingRuntimeRevision(runtime.revision)
        let dormantPointers = dispatchIdentity.map {
            UnsupportedParamCache.shared.recipeRejectedPointers(
                providerKind: providerKind,
                modelID: $0.query.effectiveModelID,
                owner: capability.rawValue,
                recipeRef: recipe.id,
                identity: $0
            )
        } ?? []
        guard let pointersToOmit = runtimeOwnedOmission(
            dormantPointers: dormantPointers,
            source: .providerRecipe,
            owner: capability.rawValue,
            recipeRef: recipe.id,
            runtimeRevision: runtime.revision,
            descriptor: CapabilityRecipeResendContext.recoveryDescriptor
        ) else {
            return .init(applied: false, reason: "upstream_setting_dormant", redactedPreview: [:])
        }
        let activePointers = Set(
            mergedRequestOps(recipe.requestOps, selectedIntent: selectedIntent).compactMap(\.pointer)
        ).subtracting(pointersToOmit)
        let compilation = compile(
            recipe: recipe, to: &body, providerKind: runtimeProviderKind(providerKind),
            transport: transport, capability: capability.rawValue, selectedIntent: selectedIntent,
            availableIntents: control.availableIntents, omittingPointers: pointersToOmit
        )
        // A compilation is deliberately only a candidate.  The final JSON encoder confirms it
        // after every remaining production mutation has succeeded; failed encoding never becomes
        CapabilityExecutionRuntime.recordCompiledDelta(
            recipe: recipe,
            runtime: runtime,
            finalTransport: transport,
            deltaIsNonEmpty: !compilation.redactedPreview.isEmpty,
            deltaRootKeys: Set(compilation.redactedPreview.keys),
            ownedPointers: activePointers,
            capabilityKeys: capabilityEvidenceKeys(
                capability: capability, selectedIntent: selectedIntent
            )
        )
        return compilation
    }

    /// `nil` means the whole owner is dormant for a normal send. A non-empty result is available
    /// only to the one request carrying the exact failed-message recovery descriptor.
    static func runtimeOwnedOmission(
        dormantPointers: Set<String>,
        source: CapabilityRejectionSource,
        owner: String,
        recipeRef: String?,
        runtimeRevision: String,
        descriptor: CapabilityRecoveryDescriptor?
    ) -> Set<String>? {
        guard !dormantPointers.isEmpty else { return [] }
        guard descriptor?.source == source,
              descriptor?.owner == owner,
              descriptor?.recipeRef == recipeRef,
              descriptor?.runtimeRevision == runtimeRevision,
              let located = descriptor?.locatedPointers,
              !located.isEmpty,
              located == dormantPointers else { return nil }
        return located
    }

    /// Applies the production mutation and returns a separately redacted audit preview.
    /// Callers must send `body`, never `redactedPreview`.
    static func compile(
        recipe: MetadataClient.CapabilityRecipe,
        to body: inout [String: Any],
        providerKind: String,
        transport: String,
        capability: String,
        selectedIntent: String?,
        availableIntents: [String]? = nil,
        omittingPointers: Set<String> = []
    ) -> Compilation {
        guard !recipe.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(applied: false, reason: "recipe_id_mismatch", redactedPreview: [:])
        }
        guard recipe.providerKind == providerKind else {
            return .init(applied: false, reason: "provider_mismatch", redactedPreview: [:])
        }
        guard recipe.capability == capability else {
            return .init(applied: false, reason: "capability_mismatch", redactedPreview: [:])
        }
        guard canonicalTransport(recipe.transport.protocolName) == canonicalTransport(transport) else {
            return .init(applied: false, reason: "transport_mismatch", redactedPreview: [:])
        }
        guard ["request_overlay", "server_tool", "model_route", "endpoint_route", "client_tool_loop"].contains(recipe.executionKind) else {
            return .init(applied: false, reason: "unsupported_execution_kind", redactedPreview: [:])
        }
        if let selectedIntent,
           availableIntents?.contains(selectedIntent) != true {
            return .init(applied: false, reason: "intent_not_available", redactedPreview: [:])
        }
        if let selectedIntent,
           !recipe.requestOps.contains(where: { $0.intent == selectedIntent }) {
            return .init(applied: false, reason: "intent_not_supported", redactedPreview: [:])
        }
        if recipe.executionKind == "model_route" {
            guard recipe.requestOps.isEmpty else {
                return .init(applied: false, reason: "model_route_has_body_patch", redactedPreview: [:])
            }
            return .init(applied: true, reason: nil, redactedPreview: [:])
        }

        let original = body
        for operation in mergedRequestOps(recipe.requestOps, selectedIntent: selectedIntent)
            where operation.pointer.map({ !omittingPointers.contains($0) }) ?? true {
            guard apply(operation: operation, to: &body) else {
                body = original
                return .init(applied: false, reason: "invalid_recipe_operation", redactedPreview: [:])
            }
        }
        let delta = requestDelta(from: original, to: body)
        return .init(applied: true, reason: nil, redactedPreview: redact(delta))
    }

 /// / `/model-contracts/provider_recipe_request_compiler.v1.json`
 /// `requestOpMerge`:**last-specific-wins**, last-write-wins.
 /// 1. foreignOp(intent != selectedIntent);
    static func mergedRequestOps(
        _ operations: [MetadataClient.CapabilityRecipeOperation],
        selectedIntent: String?
    ) -> [MetadataClient.CapabilityRecipeOperation] {
        let candidates = operations.filter { $0.intent == nil || $0.intent == selectedIntent }
        let pointersWithSpecificOp = Set(
            candidates.filter { $0.intent != nil }.compactMap(\.pointer)
        )
        return candidates.filter { operation in
            guard operation.intent == nil, let pointer = operation.pointer else { return true }
            return !pointersWithSpecificOp.contains(pointer)
        }
    }

    private static func apply(
        operation: MetadataClient.CapabilityRecipeOperation,
        to body: inout [String: Any]
    ) -> Bool {
        guard let pointer = operation.pointer else { return false }
        switch operation.op {
        case "append":
 // request_preference_contract.v2
 // ,"""".
            guard let root = appendTargetRoot(for: pointer),
                  let value = operation.value?.foundationValue else { return false }
            var elements = body[root] as? [Any] ?? []
 // D8 append :stableJson(value) ( builder
 // ). web_search .
            guard !elements.contains(where: { stableJSON($0) == stableJSON(value) }) else { return true }
            elements.append(value)
            body[root] = elements
            return true
        case "set":
            guard let value = operation.value?.foundationValue else { return false }
            return set(value: value, pointer: pointer, in: &body)
        default:
            return false
        }
    }

 /// append .pointer `/-` ( requestOpMerge 5 :
 /// append "", `/-` ,),
 /// owned array root .
    private static func appendTargetRoot(for pointer: String) -> String? {
        guard pointer.hasSuffix("/-") else { return nil }
        switch String(pointer.dropLast(2)) {
        case "/tools": return "tools"
        case "/plugins": return "plugins"
        default: return nil
        }
    }

    private static func set(value: Any, pointer: String, in object: inout [String: Any]) -> Bool {
        let segments = pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
              !["model", "messages", "input", "contents", "instructions", "system", "stream"].contains(segments[0]) else {
            return false
        }
        set(value: value, segments: Array(segments), in: &object)
        return true
    }

    private static func set(value: Any, segments: [String], in object: inout [String: Any]) {
        guard let head = segments.first else { return }
        guard segments.count > 1 else { object[head] = value; return }
        var child = object[head] as? [String: Any] ?? [:]
        set(value: value, segments: Array(segments.dropFirst()), in: &child)
        object[head] = child
    }

 /// `requestOpMerge.stableJson`: key JSON,.
    private static func stableJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(
                withJSONObject: ["v": value], options: [.sortedKeys]
              ) else { return "<invalid>" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func requestDelta(from original: [String: Any], to body: [String: Any]) -> [String: Any] {
        body.reduce(into: [:]) { result, pair in
            guard !jsonEquivalent(original[pair.key], pair.value) else { return }
            result[pair.key] = pair.value
        }
    }

    private static func jsonEquivalent(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        if JSONSerialization.isValidJSONObject(["value": lhs]),
           JSONSerialization.isValidJSONObject(["value": rhs]),
           let left = try? JSONSerialization.data(withJSONObject: ["value": lhs], options: [.sortedKeys]),
           let right = try? JSONSerialization.data(withJSONObject: ["value": rhs], options: [.sortedKeys]) {
            return left == right
        }
        return (lhs as? NSObject)?.isEqual(rhs) ?? false
    }

    private static func redact(_ value: [String: Any]) -> [String: Any] {
        value.mapValues { item in redact(item) }
    }

    private static func redact(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object {
                result[key] = ["authorization", "api_key", "apikey", "token", "secret"]
                    .contains(key.lowercased()) ? "[REDACTED]" : redact(child)
            }
            return result
        }
        if let array = value as? [Any] { return array.map { redact($0) } }
        return value
    }

    /// Metadata selector wire and recipe protocol deliberately differ for Gemini: model metadata uses
    /// `gemini_generate`, recipe registry uses `gemini_generate_content`. This is the sole alias.
    static func canonicalTransport(_ transport: String) -> String {
        switch transport {
        case "gemini_generate": return "gemini_generate_content"
        default: return transport
        }
    }

    private static func reasoningIntent(_ mode: ReasoningMode) -> String? { mode.intentToken }

 /// owner + intent → capability evidence key. key ,
 /// exact runtime/source/owner cache owner dormant;
 /// failed-message CTA latch pointer .
    static func capabilityEvidenceKeys(
        capability: RequestPreferenceOwner,
        selectedIntent: String?
    ) -> Set<String> {
        switch capability {
        case .web:
            return ["web_search"]
        case .reasoning:
            guard let mode = ReasoningMode.fromIntent(selectedIntent) else { return [] }
            return ["reasoning_level/\(mode.rawValue)"]
        case .generation:
            return []
        }
    }

    private static func runtimeProviderKind(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAI: return "openAI"
        case .anthropic: return "anthropic"
        case .gemini: return "gemini"
        case .deepseek: return "deepseek"
        case .together: return "togetherAI"
        case .fireworks: return "fireworksAI"
        default: return kind.rawValue
        }
    }
}
