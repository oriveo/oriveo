import Foundation



nonisolated enum RequestPreferenceJSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RequestPreferenceJSONValue])
    case object([String: RequestPreferenceJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([RequestPreferenceJSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: RequestPreferenceJSONValue].self))
        }
    }

    var objectValue: [String: RequestPreferenceJSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}


nonisolated enum RequestPreferenceOwner: String, CaseIterable, Sendable {
    case web
    case reasoning
    case generation
}

nonisolated enum RequestPreferenceScope: String, CaseIterable, Sendable {
    case singleSend = "single_send"
    case conversationConnectionModel = "conversation_connection_model"
    case skillAgent = "skill_agent"
    case connectionModel = "connection_model"
    case connection
    case providerRecipe = "provider_recipe"
    case providerDefault = "provider_default"
}

nonisolated enum RequestPreferenceOverride: Equatable, Sendable {
    case inherit
    case omit
    case value(RequestPreferenceJSONValue)

    var stateToken: String {
        switch self {
        case .inherit: return "inherit"
        case .omit: return "omit"
        case .value: return "value"
        }
    }
}

nonisolated enum RequestPreferenceValueMode: String, CaseIterable, Sendable {
    case preset
    case custom
}

nonisolated enum RequestControlAvailability: String, CaseIterable, Sendable {
    case autoAvailable = "auto_available"
    case managedOnly = "managed_only"
    case customOnly = "custom_only"
    case unavailable
    case unknown
}

nonisolated enum RequestConnectionAccess: String, CaseIterable, Sendable {
    case managed
    case byokDeveloper = "byok_developer"
    case relayDeveloper = "relay_developer"
}

nonisolated enum RequestContinuationKind: String, CaseIterable, Sendable {
    case none
    case previousID = "previous_id"
    case replayBlocks = "replay_blocks"
    case replayReasoning = "replay_reasoning"
    case toolLoop = "tool_loop"
}

nonisolated enum RequestResultState: String, CaseIterable, Codable, Sendable {
    case notRequested = "not_requested"
    case requested
    case observed
    case unconfirmed
    case rejected
    case recovered
}

nonisolated enum RequestObservationEvidence: String, CaseIterable, Sendable {
    case providerToolResult = "provider_tool_result"
    case citation
    case grounding
    case thinkingBlock = "thinking_block"
    case reasoningUsage = "reasoning_usage"
}

nonisolated enum RequestReasoningIntent: String, CaseIterable, Sendable {
    case off
    case low
    case balanced
    case deep
    case max
}

nonisolated enum RequestProviderKind: String, CaseIterable, Sendable {
    case openRouter
    case openAI
    case anthropic
    case gemini
    case groq
    case deepseek
    case siliconFlow
    case togetherAI
    case fireworksAI
    case miniMax
    case zhipu
    case qwen
    case grok
    case moonshot
    case mistral
    case relay
}

nonisolated enum RequestContributionTarget: String, CaseIterable, Sendable {
    case tools
    case plugins
}

nonisolated enum RequestOverlayOperationKind: String, CaseIterable, Sendable {
    case set
    case omit
    case upsertOwnedElement = "upsert_owned_element"
}

nonisolated enum RequestRetrySource: String, CaseIterable, Sendable {
    case providerRecipe = "provider_recipe"
    case custom
}


nonisolated enum RequestResolutionReason: String, Sendable {
    case noExplicitOrRecipeValue = "no_explicit_or_recipe_value"
}

nonisolated enum RequestSelectionRejection: String, Sendable {
    case autoRecipeUnavailable = "auto_recipe_unavailable"
    case customForbidden = "custom_forbidden"
    case controlUnknown = "control_unknown"
    case customUnavailable = "custom_unavailable"
}

nonisolated enum RequestAssignmentRejection: String, Sendable {
    case ownerConflict = "owner_conflict"
    case duplicatePointer = "duplicate_pointer"
    case semanticConflict = "semantic_conflict"
}

nonisolated enum RequestOverlayRejection: String, Sendable {
    case forbiddenChannel = "forbidden_channel"
    case sizeExceeded = "size_exceeded"
    case depthExceeded = "depth_exceeded"
    case nodeLimitExceeded = "node_limit_exceeded"
    case operationLimitExceeded = "operation_limit_exceeded"
    case unknownOperation = "unknown_operation"
    case duplicatePointer = "duplicate_pointer"
    case invalidPointer = "invalid_pointer"
    case blockedSegment = "blocked_segment"
    case builderOwnedRoot = "builder_owned_root"
    case typedContributionRequired = "typed_contribution_required"
    case blockedValueKey = "blocked_value_key"
    case unknownPointer = "unknown_pointer"
    case crossOwner = "cross_owner"
}

nonisolated enum RequestContributionRejection: String, Sendable {
    case unknownTarget = "unknown_target"
    case nonAppendOperation = "non_append_operation"
    case ownerNotAllowed = "owner_not_allowed"
    case duplicateIdentity = "duplicate_identity"
}

nonisolated enum RequestContinuationRejection: String, Sendable {
    case unknownContinuationKind = "unknown_continuation_kind"
    case unknownVariant = "unknown_variant"
    case stepLimitExceeded = "step_limit_exceeded"
    case missingStateField = "missing_state_field"
    case invalidReplayReasoningState = "invalid_replay_reasoning_state"
    case invalidToolLoopState = "invalid_tool_loop_state"
}

nonisolated enum RequestRetryAction: String, Sendable {
    case userConfirmedResendWithoutLocatedSetting = "user_confirmed_resend_without_located_setting"
    case surfaceError = "surface_error"
}

nonisolated enum RequestRuntimeAction: String, CaseIterable, Sendable {
    case applyRuntime = "apply_runtime"
    case applyRecipe = "apply_recipe"
    case noAutoConfig = "no_auto_config"
    case ignoreRuntime = "ignore_runtime"
    case rejectFeaturePatch = "reject_feature_patch"
}

nonisolated enum RequestRuntimeEnvelopeRejection: String, Sendable {
    case missingRuntimeEnvelope = "missing_runtime_envelope"
    case unknownSchemaVersion = "unknown_schema_version"
    case missingEnvelopeField = "missing_envelope_field"
}

nonisolated enum RequestCapabilityRejection: String, Sendable {
    case unknownState = "unknown_state"
    case fixedVerdictViolation = "fixed_verdict_violation"
    case missingRecipeRef = "missing_recipe_ref"
    case danglingRecipeRef = "dangling_recipe_ref"
    case unexpectedRecipeRef = "unexpected_recipe_ref"
    case missingReasonCode = "missing_reason_code"
    case missingSourceRefs = "missing_source_refs"
    case unresolvedSourceRef = "unresolved_source_ref"
    case intentsNotApplicable = "intents_not_applicable"
    case invalidAvailableIntent = "invalid_available_intent"
    case duplicateAvailableIntent = "duplicate_available_intent"
    case unorderedAvailableIntents = "unordered_available_intents"
    case invalidCustomControlRefs = "invalid_custom_control_refs"
    case managedCustomControlForbidden = "managed_custom_control_forbidden"
    case unresolvedCustomControlRef = "unresolved_custom_control_ref"
    case customControlOwnerMismatch = "custom_control_owner_mismatch"
}


nonisolated struct RequestPreferenceLayer: Equatable, Sendable {
    let scope: RequestPreferenceScope
    let override: RequestPreferenceOverride
}

nonisolated struct RequestSelectionIntent: Equatable, Sendable {
    let availability: RequestControlAvailability
    let selection: RequestPreferenceValueMode
    let access: RequestConnectionAccess
}

nonisolated struct RequestPointerAssignment: Equatable, Sendable {
    let owner: RequestPreferenceOwner
    let pointer: String
}

nonisolated struct RequestOverlayMetrics: Equatable, Sendable {
    let bytes: Int
    let depth: Int
    let nodes: Int
}

nonisolated struct RequestOverlayOperation: Equatable, Sendable {
    let owner: RequestPreferenceOwner
    let op: String
    let pointer: String
    let value: RequestPreferenceJSONValue?
}

nonisolated struct RequestOverlayIntent: Equatable, Sendable {
    let channel: String
    let metrics: RequestOverlayMetrics
    let declaredOwners: [String: RequestPreferenceOwner]
    let operations: [RequestOverlayOperation]
}

nonisolated struct RequestToolContribution: Equatable, Sendable {
    let owner: RequestPreferenceOwner
    let target: String
    let operation: String
    let identity: String
    let value: RequestPreferenceJSONValue?

    init(owner: RequestPreferenceOwner, target: String, operation: String, identity: String, value: RequestPreferenceJSONValue? = nil) {
        self.owner = owner; self.target = target; self.operation = operation; self.identity = identity; self.value = value
    }
}

nonisolated struct RequestOwnedPatchCompileResult: Equatable, Sendable {
    let accepted: Bool
    let reason: String?
    let delta: RequestPreferenceJSONValue?
    let preview: RequestPreferenceJSONValue?
}

nonisolated struct RequestResultFacts: Equatable, Sendable {
    let wireApplied: Bool
    let providerAccepted: Bool
    let evidenceKinds: [String]
    let recovered: Bool
}

nonisolated struct RequestContinuationIntent: Equatable, Sendable {
    let kind: String
    let variant: String?
    let step: Int
    let state: [String: RequestPreferenceJSONValue]
}

nonisolated struct RequestRetryIntent: Equatable, Sendable {
    let source: RequestRetrySource
    let status: Int?
    let errorClass: String
    let owner: RequestPreferenceOwner?
    let locatedPointers: [String]
    let preToken: Bool
    let streamStarted: Bool
    let sideEffects: Bool
    let automaticRetryCount: Int
}

nonisolated struct RequestCapabilityControl: Equatable, Sendable {
    let state: String
    let recipeRef: String?
    let reasonCode: String?
    let sourceRefs: [String]?
    let availableIntents: [String]?
    let customControlRefs: [String]?

    init(
        state: String,
        recipeRef: String? = nil,
        reasonCode: String? = nil,
        sourceRefs: [String]? = nil,
        availableIntents: [String]? = nil,
        customControlRefs: [String]? = nil
    ) {
        self.state = state
        self.recipeRef = recipeRef
        self.reasonCode = reasonCode
        self.sourceRefs = sourceRefs
        self.availableIntents = availableIntents
        self.customControlRefs = customControlRefs
    }
}


nonisolated struct ResolvedRequestPreference: Equatable, Sendable {
    let override: RequestPreferenceOverride
    let source: RequestPreferenceScope
    let reason: RequestResolutionReason?
}

nonisolated struct RequestSelectionDecision: Equatable, Sendable {
    let allowed: Bool
    let reason: RequestSelectionRejection?
}

nonisolated struct RequestAssignmentDecision: Equatable, Sendable {
    let accepted: Bool
    let reason: RequestAssignmentRejection?
}

nonisolated struct RequestOverlayDecision: Equatable, Sendable {
    let accepted: Bool
    let reason: RequestOverlayRejection?
}

nonisolated struct RequestContributionDecision: Equatable, Sendable {
    let accepted: Bool
    let identities: [String]?
    let reason: RequestContributionRejection?
}

nonisolated struct RequestResultClassification: Equatable, Sendable {
    let state: RequestResultState
    let requested: Bool
    let observed: Bool
}

nonisolated struct RequestContinuationDecision: Equatable, Sendable {
    let accepted: Bool
    let reason: RequestContinuationRejection?
}

nonisolated struct RequestRetryDecision: Equatable, Sendable {
    let retry: Bool
    let action: RequestRetryAction
}

nonisolated struct RequestRuntimeEnvelopeDecision: Equatable, Sendable {
    let applied: Bool
    let action: RequestRuntimeAction
    let reason: RequestRuntimeEnvelopeRejection?
    let chatContinues: Bool
}

nonisolated struct RequestCapabilityControlDecision: Equatable, Sendable {
    let valid: Bool
    let state: RequestControlAvailability
    let action: RequestRuntimeAction
    let reason: RequestCapabilityRejection?
}

nonisolated struct RequestCapabilityResolution: Equatable, Sendable {
    let unknownCapabilities: [String]
    let results: [RequestPreferenceOwner: RequestCapabilityControlDecision]
}

nonisolated struct RequestReasoningIntentValidation: Equatable, Sendable {
    let valid: Bool
    let reason: RequestCapabilityRejection?
    let intents: [String]
}


nonisolated struct RequestOverlayLimits: Equatable, Sendable {
    let maxBytes: Int
    let maxDepth: Int
    let maxNodes: Int
    let maxOperations: Int
}

nonisolated struct RequestContinuationSpec: Equatable, Sendable {
    let maxSteps: Int
    let requiredStateFields: [String]
    let opaqueReplay: Bool
    let variants: [String]
}

nonisolated struct RequestFixedVerdict: Equatable, Sendable {
    let providerKind: RequestProviderKind
    let state: RequestControlAvailability
    let reasonCode: String
    let autoRecipeAllowed: Bool
}

nonisolated struct RequestSourceRefExemption: Equatable, Sendable {
    let providerKind: RequestProviderKind
    let state: RequestControlAvailability
    let reasonCode: String
}

nonisolated struct RequestRetryPolicy: Equatable, Sendable {
    let automaticRetry: Bool
    let allowedStatus: Int
    let allowedErrorClass: String
    let requiresLocatedOwner: Bool
    let requiresLocatedPointers: Bool
    let requiresPreToken: Bool
    let requiresStreamNotStarted: Bool
    let requiresNoSideEffects: Bool
    let requiresStructuredErrorLocator: Bool
    let requiresExactRecipeOwnedPointers: Bool
    let unreviewedLocatorAction: String
    let mutationScope: String
    let savedPreferenceAfterRejection: String
    let explicitResendAction: String
    let preserveOnFailure: [String]
    let neverAutomatic: [String]
}

// MARK: - Resolver

nonisolated enum RequestPreferenceResolver {


    static let scopePriority: [RequestPreferenceScope] = RequestPreferenceScope.allCases

    static let overlayLimits = RequestOverlayLimits(
        maxBytes: 65_536, maxDepth: 32, maxNodes: 2_048, maxOperations: 128
    )
    static let overlaySegmentPattern = "^[A-Za-z_][A-Za-z0-9_]*$"
    static let blockedSegmentsRecursive = ["__proto__", "prototype", "constructor"]
    static let overlayBodyChannel = "body_fragment"
    static let forbiddenChannels = [
        "auth", "headers", "query", "endpoint",
        "base_url", "transport_route", "model_route", "continuation_state",
    ]
    static let builderOwnedRootFields = [
        "model", "messages", "input", "contents", "prompt", "attachments", "instructions",
        "system", "stream", "stream_options", "tools", "tool_choice", "plugins",
    ]
    static let typedContributionOnlyRoots = ["tools", "plugins"]

    static let allowedOwnerByTarget: [RequestContributionTarget: [RequestPreferenceOwner]] = [
        .tools: [.web],
        .plugins: [.web],
    ]
    static let contributionAppendOperation = "append_owned"

    static let continuationSpecs: [RequestContinuationKind: RequestContinuationSpec] = [
        RequestContinuationKind.none: RequestContinuationSpec(
            maxSteps: 0, requiredStateFields: [], opaqueReplay: false, variants: []
        ),
        RequestContinuationKind.previousID: RequestContinuationSpec(
            maxSteps: 1, requiredStateFields: ["previousResponseId"], opaqueReplay: true, variants: []
        ),
        RequestContinuationKind.replayBlocks: RequestContinuationSpec(
            maxSteps: 8, requiredStateFields: ["blocks"], opaqueReplay: true, variants: []
        ),
        RequestContinuationKind.replayReasoning: RequestContinuationSpec(
            maxSteps: 8, requiredStateFields: ["assistantMessages"], opaqueReplay: true, variants: []
        ),
        RequestContinuationKind.toolLoop: RequestContinuationSpec(
            maxSteps: 8,
            requiredStateFields: ["completedMessages"],
            opaqueReplay: true,
            variants: ["default", "fiber"]
        ),
    ]

    static let retryPolicy = RequestRetryPolicy(
        automaticRetry: false,
        allowedStatus: 400,
        allowedErrorClass: "optional_parameter_rejected",
        requiresLocatedOwner: true,
        requiresLocatedPointers: true,
        requiresPreToken: true,
        requiresStreamNotStarted: true,
        requiresNoSideEffects: true,
        requiresStructuredErrorLocator: true,
        requiresExactRecipeOwnedPointers: true,
        unreviewedLocatorAction: "surface_error",
        mutationScope: "explicit_resend_only",
        savedPreferenceAfterRejection: "retain_dormant",
        explicitResendAction: "user_confirmed_resend_without_located_setting",
        preserveOnFailure: ["draft", "attachments", "generated_content", "saved_preference"],
        neverAutomatic: [
            "401", "403", "422", "429", "5xx", "network", "timeout",
            "stream_started", "side_effect_started", "unlocated_error",
        ]
    )

    static let runtimeEnvelopeKey = "capabilityRuntime"
    static let runtimeSchemaVersion = 2
    static let runtimeEnvelopeFields = [
        "schemaVersion", "revision", "generatedAt", "recipes", "controlDefinitions", "sourceIndex",
    ]
    static let capabilityControlsKey = "capabilityControls"
    static let recipeReferenceKey = "recipeRef"

    static let nonAutoMinSourceRefs = 1

    static let fixedVerdicts: [RequestFixedVerdict] = [
        RequestFixedVerdict(
            providerKind: .relay, state: .customOnly,
            reasonCode: "relay_user_directory", autoRecipeAllowed: false
        ),
    ]

    static let sourceRefExemptions: [RequestSourceRefExemption] = [
        RequestSourceRefExemption(
            providerKind: .relay, state: .customOnly, reasonCode: "relay_user_directory"
        ),
    ]


    static func resolve(layers: [RequestPreferenceLayer]) -> ResolvedRequestPreference {
        let ordered = layers.sorted { left, right in
            priorityIndex(of: left.scope) < priorityIndex(of: right.scope)
        }
        for layer in ordered {
            switch layer.override {
            case .inherit:
                continue
            case .omit:
                return ResolvedRequestPreference(override: .omit, source: layer.scope, reason: nil)
            case .value(let value):
                return ResolvedRequestPreference(
                    override: .value(value), source: layer.scope, reason: nil
                )
            }
        }
        return ResolvedRequestPreference(
            override: .omit, source: .providerDefault, reason: .noExplicitOrRecipeValue
        )
    }

    private static func priorityIndex(of scope: RequestPreferenceScope) -> Int {
        scopePriority.firstIndex(of: scope) ?? scopePriority.count
    }


    static func evaluateSelection(_ intent: RequestSelectionIntent) -> RequestSelectionDecision {
        if intent.selection == .preset {
            if intent.availability == .autoAvailable {
                return RequestSelectionDecision(allowed: true, reason: nil)
            }
            if intent.availability == .managedOnly && intent.access == .managed {
                return RequestSelectionDecision(allowed: true, reason: nil)
            }
            if intent.availability == .unknown {
                return RequestSelectionDecision(allowed: false, reason: .controlUnknown)
            }
            return RequestSelectionDecision(allowed: false, reason: .autoRecipeUnavailable)
        }

        if intent.availability == .managedOnly || intent.access == .managed {
            return RequestSelectionDecision(allowed: false, reason: .customForbidden)
        }
        if intent.availability == .customOnly
            && (intent.access == .byokDeveloper || intent.access == .relayDeveloper) {
            return RequestSelectionDecision(allowed: true, reason: nil)
        }
        if intent.availability == .autoAvailable && intent.access != .managed {
            return RequestSelectionDecision(allowed: true, reason: nil)
        }
        if intent.availability == .unknown {
            return RequestSelectionDecision(allowed: false, reason: .controlUnknown)
        }
        return RequestSelectionDecision(allowed: false, reason: .customUnavailable)
    }


    static func validateAssignments(
        _ assignments: [RequestPointerAssignment],
        declaredConflicts: [[String]]
    ) -> RequestAssignmentDecision {
        var seen: [String: RequestPreferenceOwner] = [:]
        for assignment in assignments {
            if let existing = seen[assignment.pointer] {
                return RequestAssignmentDecision(
                    accepted: false,
                    reason: existing == assignment.owner ? .duplicatePointer : .ownerConflict
                )
            }
            seen[assignment.pointer] = assignment.owner
        }
        let active = Set(assignments.map(\.pointer))
        for pair in declaredConflicts where pair.count == 2 {
            if active.contains(pair[0]) && active.contains(pair[1]) {
                return RequestAssignmentDecision(accepted: false, reason: .semanticConflict)
            }
        }
        return RequestAssignmentDecision(accepted: true, reason: nil)
    }


    static func validateOverlay(_ intent: RequestOverlayIntent) -> RequestOverlayDecision {
        guard intent.channel == overlayBodyChannel else {
            return RequestOverlayDecision(accepted: false, reason: .forbiddenChannel)
        }
        if intent.metrics.bytes > overlayLimits.maxBytes {
            return RequestOverlayDecision(accepted: false, reason: .sizeExceeded)
        }
        if intent.metrics.depth > overlayLimits.maxDepth {
            return RequestOverlayDecision(accepted: false, reason: .depthExceeded)
        }
        if intent.metrics.nodes > overlayLimits.maxNodes {
            return RequestOverlayDecision(accepted: false, reason: .nodeLimitExceeded)
        }
        if intent.operations.count > overlayLimits.maxOperations {
            return RequestOverlayDecision(accepted: false, reason: .operationLimitExceeded)
        }

        var seen = Set<String>()
        for operation in intent.operations {
            guard RequestOverlayOperationKind(rawValue: operation.op) != nil else {
                return RequestOverlayDecision(accepted: false, reason: .unknownOperation)
            }
            guard seen.insert(operation.pointer).inserted else {
                return RequestOverlayDecision(accepted: false, reason: .duplicatePointer)
            }

            guard operation.pointer.hasPrefix("/") else {
                return RequestOverlayDecision(accepted: false, reason: .invalidPointer)
            }
            let segments = operation.pointer.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst()
                .map(String.init)
            guard segments.allSatisfy(isValidPointerSegment) else {
                return RequestOverlayDecision(accepted: false, reason: .invalidPointer)
            }
            if segments.contains(where: { blockedSegmentsRecursive.contains($0) }) {
                return RequestOverlayDecision(accepted: false, reason: .blockedSegment)
            }
            if let root = segments.first,
               typedContributionOnlyRoots.contains(root), operation.op == "upsert_owned_element", segments.count == 1 {
                guard operation.owner == .web else {
                    return RequestOverlayDecision(accepted: false, reason: .crossOwner)
                }
                continue
            }
            if let root = segments.first, builderOwnedRootFields.contains(root) {
                let reason: RequestOverlayRejection = typedContributionOnlyRoots.contains(root)
                    ? .typedContributionRequired
                    : .builderOwnedRoot
                return RequestOverlayDecision(accepted: false, reason: reason)
            }
            if let value = operation.value, containsBlockedKey(value) {
                return RequestOverlayDecision(accepted: false, reason: .blockedValueKey)
            }
            guard let declaredOwner = intent.declaredOwners[operation.pointer] else {
                return RequestOverlayDecision(accepted: false, reason: .unknownPointer)
            }
            guard declaredOwner == operation.owner else {
                return RequestOverlayDecision(accepted: false, reason: .crossOwner)
            }
        }
        return RequestOverlayDecision(accepted: true, reason: nil)
    }

    private static func isValidPointerSegment(_ segment: String) -> Bool {
        guard let first = segment.first, first.isASCII, first.isLetter || first == "_" else {
            return false
        }
        return segment.dropFirst().allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
    }

    private static func containsBlockedKey(_ value: RequestPreferenceJSONValue) -> Bool {
        switch value {
        case .array(let items):
            return items.contains(where: containsBlockedKey)
        case .object(let fields):
            return fields.contains { key, item in
                blockedSegmentsRecursive.contains(key) || containsBlockedKey(item)
            }
        default:
            return false
        }
    }


    static func composeContributions(
        base: [String],
        contributions: [RequestToolContribution]
    ) -> RequestContributionDecision {
        var identities = base
        var seen = Set(base)
        for contribution in contributions {
            guard let target = RequestContributionTarget(rawValue: contribution.target) else {
                return RequestContributionDecision(
                    accepted: false, identities: nil, reason: .unknownTarget
                )
            }
            guard contribution.operation == contributionAppendOperation else {
                return RequestContributionDecision(
                    accepted: false, identities: nil, reason: .nonAppendOperation
                )
            }
            guard allowedOwnerByTarget[target]?.contains(contribution.owner) == true else {
                return RequestContributionDecision(
                    accepted: false, identities: nil, reason: .ownerNotAllowed
                )
            }
            guard seen.insert(contribution.identity).inserted else {
                return RequestContributionDecision(
                    accepted: false, identities: nil, reason: .duplicateIdentity
                )
            }
            identities.append(contribution.identity)
        }
        return RequestContributionDecision(accepted: true, identities: identities, reason: nil)
    }

    // MARK: owned patch compiler

    /// Composes only declared, safe body deltas. Nested RFC6901 pointers retain their full
    /// structure; arrays are appended base-first and never deep-merged.
    static func compileOwnedPatches(
        overlay: RequestOverlayIntent,
        declaredConflicts: [[String]],
        base: [String: [RequestPreferenceJSONValue]],
        contributions: [RequestToolContribution]
    ) -> RequestOwnedPatchCompileResult {
        let overlayDecision = validateOverlay(overlay)
        guard overlayDecision.accepted else { return .init(accepted: false, reason: overlayDecision.reason?.rawValue, delta: nil, preview: nil) }
        let assignments = overlay.operations.map { RequestPointerAssignment(owner: $0.owner, pointer: $0.pointer) }
        let assignmentDecision = validateAssignments(assignments, declaredConflicts: declaredConflicts)
        guard assignmentDecision.accepted else { return .init(accepted: false, reason: assignmentDecision.reason?.rawValue, delta: nil, preview: nil) }

        var delta: [String: RequestPreferenceJSONValue] = [:]
        for operation in overlay.operations where operation.op != "omit" && operation.op != "upsert_owned_element" {
            guard setPointer(operation.pointer, value: operation.value ?? .null, in: &delta) else {
                return .init(accepted: false, reason: "pointer_parent_conflict", delta: nil, preview: nil)
            }
        }
        var normalized = contributions
        for operation in overlay.operations where operation.op == "upsert_owned_element" {
            guard case .object(let item)? = operation.value,
                  let identity = item["identity"], case .string(let id) = identity,
                  let value = item["value"] else { return .init(accepted: false, reason: "invalid_typed_contribution", delta: nil, preview: nil) }
            let target = String(operation.pointer.dropFirst())
            normalized.append(.init(owner: operation.owner, target: target, operation: contributionAppendOperation, identity: id, value: value))
        }
        for target in RequestContributionTarget.allCases {
            let selected = normalized.filter { $0.target == target.rawValue }
            guard !selected.isEmpty else { continue }
            let baseItems = base[target.rawValue] ?? []
            let baseIDs = baseItems.map(canonicalIdentity)
            let checked = composeContributions(base: baseIDs, contributions: selected)
            guard checked.accepted else { return .init(accepted: false, reason: checked.reason?.rawValue, delta: nil, preview: nil) }
            delta[target.rawValue] = .array(baseItems + selected.compactMap(\.value))
        }
        let value = RequestPreferenceJSONValue.object(delta)
        return .init(accepted: true, reason: nil, delta: value, preview: redactPreview(value))
    }

    private static func setPointer(_ pointer: String, value: RequestPreferenceJSONValue, in object: inout [String: RequestPreferenceJSONValue]) -> Bool {
        var parts = pointer.dropFirst().split(separator: "/").map(String.init)
        guard let key = parts.popLast() else { return false }
        func descend(_ parts: ArraySlice<String>, _ leaf: String, _ value: RequestPreferenceJSONValue, _ fields: inout [String: RequestPreferenceJSONValue]) -> Bool {
            guard let head = parts.first else { fields[leaf] = value; return true }
            var child: [String: RequestPreferenceJSONValue]
            if let existing = fields[head] { guard case .object(let current) = existing else { return false }; child = current } else { child = [:] }
            guard descend(parts.dropFirst(), leaf, value, &child) else { return false }
            fields[head] = .object(child); return true
        }
        return descend(parts[...], key, value, &object)
    }

    private static func canonicalIdentity(_ value: RequestPreferenceJSONValue) -> String {
        switch value {
        case .null: return "null"; case .bool(let v): return v ? "true" : "false"; case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"; case .string(let v): return String(reflecting: v)
        case .array(let values): return "[" + values.map(canonicalIdentity).joined(separator: ",") + "]"
        case .object(let fields): return "{" + fields.keys.sorted().map { "\(String(reflecting: $0)):\(canonicalIdentity(fields[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    private static func redactPreview(_ value: RequestPreferenceJSONValue) -> RequestPreferenceJSONValue {
        let excluded: Set<String> = ["api_key", "authorization", "prompt", "messages", "attachments", "full_endpoint", "response", "raw_custom_fragment"]
        switch value {
        case .array(let values): return .array(values.map(redactPreview))
        case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { key, item in (key, excluded.contains(key.lowercased()) ? .string("[REDACTED]") : redactPreview(item)) }))
        default: return value
        }
    }


    static func classifyResult(_ facts: RequestResultFacts) -> RequestResultClassification {
        guard facts.wireApplied else {
            return RequestResultClassification(state: .notRequested, requested: false, observed: false)
        }
        guard facts.providerAccepted else {
            return RequestResultClassification(state: .rejected, requested: true, observed: false)
        }
        if facts.recovered {
            return RequestResultClassification(state: .recovered, requested: true, observed: false)
        }
        let hasEvidence = facts.evidenceKinds.contains { kind in
            RequestObservationEvidence(rawValue: kind) != nil
        }
        return hasEvidence
            ? RequestResultClassification(state: .observed, requested: true, observed: true)
            : RequestResultClassification(state: .unconfirmed, requested: true, observed: false)
    }


    static func validateContinuation(_ intent: RequestContinuationIntent) -> RequestContinuationDecision {
        guard let kind = RequestContinuationKind(rawValue: intent.kind),
              let spec = continuationSpecs[kind] else {
            return RequestContinuationDecision(accepted: false, reason: .unknownContinuationKind)
        }
        if let variant = intent.variant, !spec.variants.contains(variant) {
            return RequestContinuationDecision(accepted: false, reason: .unknownVariant)
        }
        guard intent.step >= 0, intent.step <= spec.maxSteps else {
            return RequestContinuationDecision(accepted: false, reason: .stepLimitExceeded)
        }
        if spec.requiredStateFields.contains(where: { intent.state[$0] == nil }) {
            return RequestContinuationDecision(accepted: false, reason: .missingStateField)
        }
        if kind == .replayReasoning,
           !validReplayReasoningMessages(intent.state["assistantMessages"]) {
            return RequestContinuationDecision(accepted: false, reason: .invalidReplayReasoningState)
        }
        if kind == .toolLoop, !validToolLoopMessages(intent.state["completedMessages"]) {
            return RequestContinuationDecision(accepted: false, reason: .invalidToolLoopState)
        }
        return RequestContinuationDecision(accepted: true, reason: nil)
    }

    /// replay_reasoning is opaque only inside a bounded assistant-message envelope. The known
    /// OpenAI-chat continuations use string content plus reasoning_content/reasoning_details;
    /// Mistral additionally uses thinking/text content blocks. Unknown block types and malformed
    /// tool calls reject local state instead of being guessed into a provider request.
    private static func validReplayReasoningMessages(_ raw: RequestPreferenceJSONValue?) -> Bool {
        guard case let .array(messages)? = raw, !messages.isEmpty else { return false }
        let allowedKeys: Set<String> = [
            "role", "content", "reasoning_content", "reasoning_details", "tool_calls",
        ]
        return messages.allSatisfy { value in
            guard case let .object(message) = value,
                  Set(message.keys).isSubset(of: allowedKeys),
                  case .string("assistant")? = message["role"],
                  validReplayContent(message["content"]) else { return false }
            if let reasoning = message["reasoning_content"] {
                guard case .string = reasoning else { return false }
            }
            if let details = message["reasoning_details"] {
                guard case let .array(values) = details,
                      validOpenRouterReasoningDetails(values) else { return false }
            }
            if let calls = message["tool_calls"], !validReplayToolCalls(calls) { return false }
            return true
        }
    }

    private static func validOpenRouterReasoningDetails(
        _ values: [RequestPreferenceJSONValue]
    ) -> Bool {
        guard !values.isEmpty else { return false }
        return values.allSatisfy { value in
            guard case let .object(detail) = value,
                  !detail.isEmpty,
                  case let .string(type)? = detail["type"], !type.isEmpty else { return false }
            if let index = detail["index"] {
                guard case let .int(raw) = index, raw >= 0 else { return false }
            }
            for key in ["text", "summary", "data"] where detail[key] != nil {
                guard case .string? = detail[key] else { return false }
            }
            return true
        }
    }

    private static func validReplayContent(_ raw: RequestPreferenceJSONValue?) -> Bool {
        guard let raw else { return false }
        if case .null = raw { return true }
        if case .string = raw { return true }
        guard case let .array(blocks) = raw, !blocks.isEmpty else { return false }
        return blocks.allSatisfy { value in
            guard case let .object(block) = value,
                  case let .string(type)? = block["type"] else { return false }
            switch type {
            case "text":
                guard case .string? = block["text"] else { return false }
                return true
            case "thinking":
                guard case let .array(parts)? = block["thinking"] else { return false }
                return parts.allSatisfy { part in
                    guard case let .object(item) = part,
                          case .string("text")? = item["type"],
                          case .string? = item["text"] else { return false }
                    return true
                }
            default:
                return false
            }
        }
    }

    private static func validReplayToolCalls(_ raw: RequestPreferenceJSONValue) -> Bool {
        guard case let .array(calls) = raw else { return false }
        return calls.allSatisfy { value in
            guard case let .object(call) = value,
                  case let .string(id)? = call["id"], !id.isEmpty,
                  case .string("function")? = call["type"],
                  case let .object(function)? = call["function"],
                  case let .string(name)? = function["name"], !name.isEmpty,
                  case .string? = function["arguments"] else { return false }
            return true
        }
    }

    /// `completedMessages` is an opaque replay block, but its envelope must be structurally safe:
    /// every assistant call has one unique id and a following paired tool result; a standalone tool
    /// result or a partially persisted leg is never eligible for continuation.
    private static func validToolLoopMessages(_ raw: RequestPreferenceJSONValue?) -> Bool {
        guard case let .array(messages)? = raw else { return false }
        var pending = Set<String>()
        var seen = Set<String>()
        for message in messages {
            guard case let .object(object) = message, case let .string(role)? = object["role"] else { return false }
            switch role {
            case "assistant":
                guard pending.isEmpty, case let .array(calls)? = object["tool_calls"], !calls.isEmpty else { return false }
                for call in calls {
                    guard case let .object(item) = call,
                          case let .string(id)? = item["id"], !id.isEmpty,
                          case let .string(type)? = item["type"],
                          ["function", "builtin_function"].contains(type),
                          case let .object(function)? = item["function"],
                          case let .string(name)? = function["name"], !name.isEmpty,
                          case .string? = function["arguments"],
                          seen.insert(id).inserted else { return false }
                    pending.insert(id)
                }
            case "tool":
                guard case let .string(id)? = object["tool_call_id"], pending.remove(id) != nil,
                      case .string? = object["content"] else { return false }
                if let name = object["name"] { guard case .string = name else { return false } }
            default: return false
            }
        }
        return pending.isEmpty
    }


    static func resolveRetry(_ intent: RequestRetryIntent) -> RequestRetryDecision {
        let mayOfferExplicitResend = intent.status == retryPolicy.allowedStatus
            && intent.errorClass == retryPolicy.allowedErrorClass
            && intent.owner != nil
            && !intent.locatedPointers.isEmpty
            && intent.preToken
            && !intent.streamStarted
            && !intent.sideEffects
            && intent.automaticRetryCount == 0
        return mayOfferExplicitResend
            ? RequestRetryDecision(retry: false, action: .userConfirmedResendWithoutLocatedSetting)
            : RequestRetryDecision(retry: false, action: .surfaceError)
    }


    static func validateRuntimeEnvelope(
        payload: [String: RequestPreferenceJSONValue]
    ) -> RequestRuntimeEnvelopeDecision {
        func ignore(_ reason: RequestRuntimeEnvelopeRejection) -> RequestRuntimeEnvelopeDecision {
            RequestRuntimeEnvelopeDecision(
                applied: false, action: .ignoreRuntime, reason: reason, chatContinues: true
            )
        }
        guard let envelopeValue = payload[runtimeEnvelopeKey] else {
            return ignore(.missingRuntimeEnvelope)
        }
        guard let envelope = envelopeValue.objectValue,
              envelope["schemaVersion"]?.intValue == runtimeSchemaVersion else {
            return ignore(.unknownSchemaVersion)
        }
        if runtimeEnvelopeFields.contains(where: { envelope[$0] == nil }) {
            return ignore(.missingEnvelopeField)
        }
        return RequestRuntimeEnvelopeDecision(
            applied: true, action: .applyRuntime, reason: nil, chatContinues: true
        )
    }


    static func resolveCapabilityControls(
        providerKind: RequestProviderKind,
        controls: [String: RequestCapabilityControl],
        availableRecipeIDs: Set<String>,
        sourceIndexKeys: Set<String>,
        controlDefinitionOwners: [String: String] = [:]
    ) -> RequestCapabilityResolution {
        var unknown: [String] = []
        var results: [RequestPreferenceOwner: RequestCapabilityControlDecision] = [:]
        for (key, control) in controls {
            guard let capability = RequestPreferenceOwner(rawValue: key) else {
                unknown.append(key)
                continue
            }
            results[capability] = resolveCapabilityControl(
                providerKind: providerKind,
                capability: capability,
                control: control,
                availableRecipeIDs: availableRecipeIDs,
                sourceIndexKeys: sourceIndexKeys,
                controlDefinitionOwners: controlDefinitionOwners
            )
        }
        return RequestCapabilityResolution(unknownCapabilities: unknown.sorted(), results: results)
    }

    static func resolveCapabilityControl(
        providerKind: RequestProviderKind,
        capability: RequestPreferenceOwner,
        control: RequestCapabilityControl,
        availableRecipeIDs: Set<String>,
        sourceIndexKeys: Set<String>,
        controlDefinitionOwners: [String: String] = [:]
    ) -> RequestCapabilityControlDecision {
        func noAutoConfig(
            _ valid: Bool,
            _ state: RequestControlAvailability,
            _ reason: RequestCapabilityRejection?
        ) -> RequestCapabilityControlDecision {
            RequestCapabilityControlDecision(
                valid: valid, state: state, action: .noAutoConfig, reason: reason
            )
        }

        guard let state = RequestControlAvailability(rawValue: control.state) else {
            return noAutoConfig(true, .unknown, .unknownState)
        }

        if let verdict = fixedVerdicts.first(where: { $0.providerKind == providerKind }),
           !verdict.autoRecipeAllowed, state == .autoAvailable {
            return noAutoConfig(false, verdict.state, .fixedVerdictViolation)
        }

        if let intents = control.availableIntents {
            let validation = validateAvailableIntents(capability: capability, intents: intents)
            if !validation.valid {
                return noAutoConfig(false, state, validation.reason)
            }
        }

        let customRefs = control.customControlRefs ?? []
        if Set(customRefs).count != customRefs.count {
            return noAutoConfig(false, state, .invalidCustomControlRefs)
        }
        if state == .managedOnly, !customRefs.isEmpty {
            return noAutoConfig(false, state, .managedCustomControlForbidden)
        }
        for ref in customRefs {
            guard let owner = controlDefinitionOwners[ref] else {
                return noAutoConfig(false, state, .unresolvedCustomControlRef)
            }
            guard owner == capability.rawValue else {
                return noAutoConfig(false, state, .customControlOwnerMismatch)
            }
        }

        if state == .autoAvailable {
            guard let recipeRef = control.recipeRef else {
                return noAutoConfig(false, .unknown, .missingRecipeRef)
            }
            guard availableRecipeIDs.contains(recipeRef) else {
                return noAutoConfig(true, .unknown, .danglingRecipeRef)
            }
            return RequestCapabilityControlDecision(
                valid: true, state: .autoAvailable, action: .applyRecipe, reason: nil
            )
        }

        if control.recipeRef != nil {
            return noAutoConfig(false, state, .unexpectedRecipeRef)
        }
        guard let reasonCode = control.reasonCode, !reasonCode.isEmpty else {
            return noAutoConfig(false, state, .missingReasonCode)
        }

        let exempt = sourceRefExemptions.contains { exemption in
            exemption.providerKind == providerKind
                && exemption.state == state
                && exemption.reasonCode == reasonCode
        }
        if !exempt {
            let refs = control.sourceRefs ?? []
            guard refs.count >= nonAutoMinSourceRefs else {
                return noAutoConfig(false, state, .missingSourceRefs)
            }
            guard refs.allSatisfy({ sourceIndexKeys.contains($0) }) else {
                return noAutoConfig(false, state, .unresolvedSourceRef)
            }
        }
        return noAutoConfig(true, state, nil)
    }

    /// Reasoning keeps its ordered sparse ladder. Web has no ladder: its only legal
    /// runtime override is the exact `[force]` supplied by a reviewed recipe.
    static func validateAvailableIntents(
        capability: RequestPreferenceOwner,
        intents: [String]
    ) -> RequestReasoningIntentValidation {
        func fail(_ reason: RequestCapabilityRejection) -> RequestReasoningIntentValidation {
            RequestReasoningIntentValidation(valid: false, reason: reason, intents: intents)
        }
        if capability == .web {
            guard intents == ["force"] else { return fail(.invalidAvailableIntent) }
            return RequestReasoningIntentValidation(valid: true, reason: nil, intents: intents)
        }
        guard capability == .reasoning else { return fail(.intentsNotApplicable) }

        var positions: [Int] = []
        for token in intents {
            guard let intent = RequestReasoningIntent(rawValue: token),
                  let index = RequestReasoningIntent.allCases.firstIndex(of: intent) else {
                return fail(.invalidAvailableIntent)
            }
            positions.append(index)
        }
        if Set(positions).count != positions.count { return fail(.duplicateAvailableIntent) }
        for (offset, position) in positions.enumerated() where offset > 0 {
            if position <= positions[offset - 1] { return fail(.unorderedAvailableIntents) }
        }
        return RequestReasoningIntentValidation(valid: true, reason: nil, intents: intents)
    }
}
