import Foundation

public struct ProviderRecipeAdapterCapabilities: Hashable, Sendable {
    public var transports: Set<String>
    public var executionKinds: Set<String>
    public var responseParsers: Set<String>
    public var continuationKinds: Set<String>
    public var endpointClasses: Set<String>
    public var requestMappers: Set<String>
    public var requiredHeaders: Set<String>

    public init(
        transports: Set<String>,
        executionKinds: Set<String>,
        responseParsers: Set<String>,
        continuationKinds: Set<String>,
        endpointClasses: Set<String> = [],
        requestMappers: Set<String> = [],
        requiredHeaders: Set<String> = []
    ) {
        self.transports = transports
        self.executionKinds = executionKinds
        self.responseParsers = responseParsers
        self.continuationKinds = continuationKinds
        self.endpointClasses = endpointClasses
        self.requestMappers = requestMappers
        self.requiredHeaders = requiredHeaders
    }
}

public struct ProviderRecipeCompilationContext: Hashable, Sendable {
    public var providerKind: String
    public var transport: String
    public var capability: String
    public var selectedIntent: String?
    public var availableIntents: [String]?

    public init(
        providerKind: String,
        transport: String,
        capability: String,
        selectedIntent: String? = nil,
        availableIntents: [String]? = nil
    ) {
        self.providerKind = providerKind
        self.transport = transport
        self.capability = capability
        self.selectedIntent = selectedIntent
        self.availableIntents = availableIntents
    }
}

public struct CompiledProviderPlan: Hashable, Sendable {
    public var recipeID: String
    public var providerKind: String
    public var transport: String
    public var capability: String
    public var executionKind: String
    public var responseParserKind: String
    public var continuationKind: String
    public var continuationVariant: String?
    public var endpointClass: String
    public var requiredHeaders: [String]
    public var route: ProviderRecipeRoute?
    public var requestBody: ProviderRecipeValue
    /// The root fields this plan actually changed, for showing the user what a capability added
    /// to their request. Credentials cannot appear here: the compiler refuses to patch them.
    public var bodyDelta: ProviderRecipeValue

    public var bodyDeltaIsEmpty: Bool {
        bodyDelta.objectValue?.isEmpty != false
    }
}

public enum ProviderRecipeCompileFailure: String, Error, Equatable, Sendable {
    case recipeNotFound = "recipe_not_found"
    case recipeIdentityInvalid = "recipe_identity_invalid"
    case providerMismatch = "provider_mismatch"
    case transportMismatch = "transport_mismatch"
    case capabilityMismatch = "capability_mismatch"
    case executionKindUnsupported = "unsupported_execution_kind"
    case responseParserUnsupported = "unsupported_response_parser"
    case continuationUnsupported = "unsupported_continuation_kind"
    case continuationVariantUnsupported = "unsupported_continuation_variant"
    case endpointClassUnsupported = "unsupported_endpoint_class"
    case requestMapperUnsupported = "unsupported_request_mapper"
    case requiredHeaderUnsupported = "unsupported_required_header"
    case streamingModeUnsupported = "unsupported_streaming_mode"
    case intentUnavailable = "intent_not_available"
    case intentUnsupported = "intent_not_supported"
    case requestBodyInvalid = "request_body_invalid"
    case operationRejected = "invalid_recipe_operation"
    case routeRejected = "recipe_route_rejected"
    case modelRouteHasBodyPatch = "model_route_has_body_patch"
}

/// Turns one recipe into a concrete request body.
///
/// The compiler is deliberately narrow. It patches the request body and nothing else: routing,
/// credentials, the model, the conversation and the streaming flags are owned by the caller and
/// are refused as patch targets, so a malformed or hostile recipe can change how a request is
/// decorated but never where it goes or who it is sent as. Anything the compiler does not
/// positively recognise - an execution kind, a parser, a pointer, a header - is rejected rather
/// than passed through.
public enum ProviderRecipeCompiler {
    public static let knownProviderKinds: Set<String> = [
        "openRouter", "openAI", "anthropic", "gemini", "groq", "deepseek", "siliconFlow",
        "togetherAI", "fireworksAI", "miniMax", "zhipu", "qwen", "grok", "moonshot",
        "mistral", "relay",
    ]
    private static let knownStreamingModes: Set<String> = ["required", "optional", "unsupported"]
    private static let knownCapabilities: Set<String> = ["web", "reasoning", "generation"]
    private static let knownExecutionKinds: Set<String> = [
        "request_overlay", "server_tool", "client_tool_loop", "endpoint_route", "model_route",
        "external_connector", "unavailable",
    ]
    private static let knownContinuationKinds: Set<String> = [
        "none", "previous_id", "replay_blocks", "replay_reasoning", "tool_loop",
    ]
    private static let knownFallbackPolicies: Set<String> = [
        "user_confirmed_resend_without_located_setting", "remove_auto_patch_once_pre_token",
        "no_fallback",
    ]
    private static let knownContinuationVariants: Set<String> = ["default", "fiber"]
    private static let blockedSegments: Set<String> = ["__proto__", "prototype", "constructor"]
    private static let blockedRootFields: Set<String> = [
        "auth", "headers", "query", "endpoint", "base_url", "transport_route", "model_route",
        "continuation_state", "model", "messages", "input", "contents", "prompt", "attachments",
        "instructions", "system", "stream", "stream_options", "credential", "credentials",
        "api_key", "apikey", "token",
    ]
    private static let appendOnlyRoots: Set<String> = ["tools", "plugins"]

    public static func compile(
        recipeRef: String,
        runtime: ProviderCapabilityRuntime,
        context: ProviderRecipeCompilationContext,
        adapter: ProviderRecipeAdapterCapabilities,
        baseBody: ProviderRecipeValue
    ) throws -> CompiledProviderPlan {
        guard let recipe = runtime.recipes[recipeRef] else {
            throw ProviderRecipeCompileFailure.recipeNotFound
        }
        guard recipe.id == recipeRef,
              !recipe.sourceRefs.isEmpty,
              recipe.sourceRefs.allSatisfy({ runtime.sourceIndex[$0] != nil }) else {
            throw ProviderRecipeCompileFailure.recipeIdentityInvalid
        }
        guard recipe.controlRefs.allSatisfy({ runtime.controlDefinitions[$0] != nil }) else {
            throw ProviderRecipeCompileFailure.recipeIdentityInvalid
        }
        return try compile(recipe: recipe, context: context, adapter: adapter, baseBody: baseBody)
    }

    public static func compile(
        recipe: ProviderRecipe,
        context: ProviderRecipeCompilationContext,
        adapter: ProviderRecipeAdapterCapabilities,
        baseBody: ProviderRecipeValue
    ) throws -> CompiledProviderPlan {
        guard isValidRecipeID(recipe.id),
              knownProviderKinds.contains(recipe.providerKind),
              isValidReviewedAt(recipe.reviewedAt),
              !recipe.sourceRefs.isEmpty,
              !recipe.transport.protocolName.isEmpty,
              !recipe.transport.endpointClass.isEmpty else {
            throw ProviderRecipeCompileFailure.recipeIdentityInvalid
        }
        guard recipe.providerKind == context.providerKind else {
            throw ProviderRecipeCompileFailure.providerMismatch
        }
        guard knownCapabilities.contains(recipe.capability),
              knownExecutionKinds.contains(recipe.executionKind),
              knownContinuationKinds.contains(recipe.continuationKind),
              knownFallbackPolicies.contains(recipe.fallbackPolicy) else {
            throw ProviderRecipeCompileFailure.recipeIdentityInvalid
        }
        let recipeTransport = canonicalTransport(recipe.transport.protocolName)
        let requestedTransport = canonicalTransport(context.transport)
        guard recipeTransport == requestedTransport, adapter.transports.contains(recipeTransport) else {
            throw ProviderRecipeCompileFailure.transportMismatch
        }
        guard recipe.capability == context.capability else {
            throw ProviderRecipeCompileFailure.capabilityMismatch
        }
        guard adapter.executionKinds.contains(recipe.executionKind) else {
            throw ProviderRecipeCompileFailure.executionKindUnsupported
        }
        guard adapter.responseParsers.contains(recipe.responseParserKind) else {
            throw ProviderRecipeCompileFailure.responseParserUnsupported
        }
        guard adapter.continuationKinds.contains(recipe.continuationKind) else {
            throw ProviderRecipeCompileFailure.continuationUnsupported
        }
        if let variant = recipe.continuationVariant,
           !knownContinuationVariants.contains(variant) {
            throw ProviderRecipeCompileFailure.continuationVariantUnsupported
        }
        if recipe.continuationKind != "tool_loop", recipe.continuationVariant != nil {
            throw ProviderRecipeCompileFailure.continuationVariantUnsupported
        }
        guard knownStreamingModes.contains(recipe.transport.streaming) else {
            throw ProviderRecipeCompileFailure.streamingModeUnsupported
        }
        guard adapter.endpointClasses.contains(recipe.transport.endpointClass) else {
            throw ProviderRecipeCompileFailure.endpointClassUnsupported
        }
        guard Set(recipe.transport.requiredHeaders).isSubset(of: adapter.requiredHeaders),
              recipe.transport.requiredHeaders.allSatisfy(isSafeHeaderName) else {
            throw ProviderRecipeCompileFailure.requiredHeaderUnsupported
        }
        if let selectedIntent = context.selectedIntent {
            guard context.availableIntents?.contains(selectedIntent) == true else {
                throw ProviderRecipeCompileFailure.intentUnavailable
            }
            guard recipe.requestOps.contains(where: { $0.intent == selectedIntent }) else {
                throw ProviderRecipeCompileFailure.intentUnsupported
            }
        }
        if recipe.executionKind == "model_route", !recipe.requestOps.isEmpty {
            throw ProviderRecipeCompileFailure.modelRouteHasBodyPatch
        }
        if recipe.executionKind == "client_tool_loop" {
            guard let maxToolLoops = recipe.maxToolLoops, (1 ... 8).contains(maxToolLoops) else {
                throw ProviderRecipeCompileFailure.executionKindUnsupported
            }
            if recipe.continuationVariant == "fiber" {
                guard case .object(let formula)? = recipe.formula,
                      ["uri", "toolsPath", "fibersPath", "argumentsMode", "resultPaths"]
                        .allSatisfy({ formula[$0] != nil }) else {
                    throw ProviderRecipeCompileFailure.executionKindUnsupported
                }
            }
        }
        try validateRoute(recipe.route, executionKind: recipe.executionKind, context: context, adapter: adapter)
        guard var body = baseBody.objectValue else {
            throw ProviderRecipeCompileFailure.requestBodyInvalid
        }
        let original = body
        if recipe.requestOps.count > 128 { throw ProviderRecipeCompileFailure.operationRejected }
        for operation in mergedRequestOps(recipe.requestOps, selectedIntent: context.selectedIntent) {
            guard try apply(operation, to: &body) else {
                throw ProviderRecipeCompileFailure.operationRejected
            }
        }
        let delta = body.reduce(into: [String: ProviderRecipeValue]()) { result, pair in
            if original[pair.key] != pair.value { result[pair.key] = pair.value }
        }
        return CompiledProviderPlan(
            recipeID: recipe.id,
            providerKind: context.providerKind,
            transport: recipeTransport,
            capability: context.capability,
            executionKind: recipe.executionKind,
            responseParserKind: recipe.responseParserKind,
            continuationKind: recipe.continuationKind,
            continuationVariant: recipe.continuationVariant,
            endpointClass: recipe.transport.endpointClass,
            requiredHeaders: recipe.transport.requiredHeaders,
            route: recipe.route,
            requestBody: .object(body),
            bodyDelta: .object(delta)
        )
    }

    /// Intent-specific operations win over the intent-free defaults that target the same
    /// pointer, so a recipe can state a general default once and then override it per intent.
    static func mergedRequestOps(
        _ operations: [ProviderRecipeOperation],
        selectedIntent: String?
    ) -> [ProviderRecipeOperation] {
        let candidates = operations.filter { $0.intent == nil || $0.intent == selectedIntent }
        let pointersWithSpecific = Set(candidates.filter { $0.intent != nil }.compactMap(\.pointer))
        return candidates.filter { operation in
            guard operation.intent == nil, let pointer = operation.pointer else { return true }
            return !pointersWithSpecific.contains(pointer)
        }
    }

    public static func canonicalTransport(_ value: String) -> String {
        value == "gemini_generate" ? "gemini_generate_content" : value
    }

    private static func validateRoute(
        _ route: ProviderRecipeRoute?,
        executionKind: String,
        context: ProviderRecipeCompilationContext,
        adapter: ProviderRecipeAdapterCapabilities
    ) throws {
        guard executionKind == "endpoint_route" else {
            if route != nil { throw ProviderRecipeCompileFailure.routeRejected }
            return
        }
        guard let route,
              isSafeRoutePath(route.path),
              (route.method ?? "POST") == "POST",
              adapter.transports.contains(canonicalTransport(route.protocolName)),
              adapter.endpointClasses.contains(route.endpointClass),
              adapter.requestMappers.contains(route.requestMapper),
              route.sourceProtocol.map(canonicalTransport) == nil
                || route.sourceProtocol.map(canonicalTransport) == canonicalTransport(context.transport),
              (route.headers ?? [:]).keys.allSatisfy(isSafeHeaderName),
              (route.headers ?? [:]).keys.allSatisfy(adapter.requiredHeaders.contains),
              isSafeRouteAuthentication(mode: route.authMode, header: route.authHeader),
              (route.headers ?? [:]).values.allSatisfy(isSafeFixedHeaderValue)
        else { throw ProviderRecipeCompileFailure.routeRejected }
    }

    private static func apply(
        _ operation: ProviderRecipeOperation,
        to body: inout [String: ProviderRecipeValue]
    ) throws -> Bool {
        guard let pointer = operation.pointer, let value = operation.value,
              validateValue(value) else { return false }
        switch operation.op {
        case "append":
            guard pointer.hasSuffix("/-") else { return false }
            let root = String(pointer.dropFirst().dropLast(2))
            guard appendOnlyRoots.contains(root) else { return false }
            var values = body[root]?.arrayValue ?? []
            if !values.contains(value) { values.append(value) }
            body[root] = .array(values)
            return true
        case "set":
            let segments = pointer.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst().map(String.init)
            guard !segments.isEmpty,
                  segments.allSatisfy(isSafeSegment),
                  !blockedRootFields.contains(segments[0].lowercased()),
                  !appendOnlyRoots.contains(segments[0]) else { return false }
            set(value, segments: segments, in: &body)
            return true
        default:
            return false
        }
    }

    private static func set(
        _ value: ProviderRecipeValue,
        segments: [String],
        in object: inout [String: ProviderRecipeValue]
    ) {
        let head = segments[0]
        guard segments.count > 1 else { object[head] = value; return }
        var child = object[head]?.objectValue ?? [:]
        set(value, segments: Array(segments.dropFirst()), in: &child)
        object[head] = .object(child)
    }

    private static func validateValue(_ value: ProviderRecipeValue) -> Bool {
        var nodes = 0
        func visit(_ value: ProviderRecipeValue, depth: Int) -> Bool {
            nodes += 1
            guard nodes <= 2_048, depth <= 32 else { return false }
            switch value {
            case .number(let value): return !value.isNaN && value.isFinite
            case .array(let values): return values.allSatisfy { visit($0, depth: depth + 1) }
            case .object(let values):
                return values.allSatisfy { key, child in
                    !blockedSegments.contains(key) && visit(child, depth: depth + 1)
                }
            default: return true
            }
        }
        guard visit(value, depth: 0),
              JSONSerialization.isValidJSONObject(["value": value.foundationValue]),
              let bytes = try? JSONSerialization.data(withJSONObject: ["value": value.foundationValue]),
              bytes.count <= 65_536 else { return false }
        return true
    }

    private static func isSafeHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }

    private static func isSafeFixedHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { byte in
            byte == 9 || (byte >= 32 && byte <= 126)
        }
    }

    private static func isSafeRouteAuthentication(mode: String?, header: String?) -> Bool {
        switch (mode, header) {
        case (nil, nil): true
        case ("x_api_key", "x-api-key"), ("bearer", "Authorization"): true
        default: false
        }
    }

    private static func isSafeRoutePath(_ value: String) -> Bool {
        var decoded = value
        for _ in 0 ..< 8 {
            guard isStructurallySafeRoutePath(decoded),
                  let next = decoded.removingPercentEncoding else { return false }
            if next == decoded { return true }
            decoded = next
        }
        // No legitimate route path needs this much nested percent-encoding, and allowing it
        // would let a delimiter re-emerge after the structural check has already run.
        return false
    }

    private static func isStructurallySafeRoutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//") && !value.contains("\\")
            && !value.contains("://") && !value.contains("?") && !value.contains("#")
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isSafeSegment(_ value: String) -> Bool {
        guard !value.isEmpty, !blockedSegments.contains(value), let first = value.utf8.first else { return false }
        let validFirst = (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95
        return validFirst && value.utf8.dropFirst().allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95
        }
    }

    private static func isValidRecipeID(_ value: String) -> Bool {
        let components = value.split(separator: ".")
        guard components.count == 4,
              let version = components.last,
              version.first == "v",
              version.dropFirst().allSatisfy(\.isNumber),
              !version.dropFirst().isEmpty else { return false }
        return components.dropLast().allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
        }
    }

    private static func isValidReviewedAt(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(components[0]), let month = Int(components[1]), let day = Int(components[2]),
              year >= 2000, (1 ... 12).contains(month), (1 ... 31).contains(day) else { return false }
        return true
    }
}
