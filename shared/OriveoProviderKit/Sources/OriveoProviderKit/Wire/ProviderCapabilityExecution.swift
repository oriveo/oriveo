import Foundation

public struct ProviderCapabilitySelection: Codable, Hashable, Sendable {
    public var capability: String
    /// nil means the capability is enabled with the recipe's intent-free default ops.
    /// This is distinct from omitting the whole selection, which leaves the capability off.
    public var selectedIntent: String?

    public init(capability: String, selectedIntent: String? = nil) {
        self.capability = capability
        self.selectedIntent = selectedIntent
    }
}

public enum ProviderCapabilitySupport: String, Codable, Hashable, Sendable {
    case supported, unsupported, unknown
}

public struct ProviderCapabilityResolution: Codable, Hashable, Sendable {
    public var support: ProviderCapabilitySupport
    public var availableIntents: [String]
    public var reasonCode: String?

    public init(support: ProviderCapabilitySupport, availableIntents: [String] = [], reasonCode: String? = nil) {
        self.support = support
        self.availableIntents = availableIntents
        self.reasonCode = reasonCode
    }
}

/// Decides what a capability can do for one model, given the frozen authority for the run and
/// what this client's adapter can actually execute. `unknown` and `unsupported` are kept apart
/// on purpose: the first means the answer is not established, the second means it is
/// established as no, and only the second is safe to present as a hard limitation.
public enum ProviderCapabilityResolver {
    public static func resolve(
        capability: String,
        snapshot: ProviderModelRecipeSnapshot?,
        adapter: ProviderRecipeAdapterCapabilities
    ) -> ProviderCapabilityResolution {
        guard let control = snapshot?.capabilityControls[capability] else {
            return .init(support: .unknown, reasonCode: "authority_missing")
        }
        switch control.state {
        case "unavailable":
            return .init(support: .unsupported, reasonCode: control.reasonCode)
        case "unknown":
            return .init(support: .unknown, reasonCode: control.reasonCode)
        case "auto_available":
            guard let ref = control.recipeRef,
                  let recipe = snapshot?.recipes[ref],
                  adapter.transports.contains(ProviderRecipeCompiler.canonicalTransport(recipe.transport.protocolName)),
                  adapter.executionKinds.contains(recipe.executionKind),
                  adapter.responseParsers.contains(recipe.responseParserKind),
                  adapter.continuationKinds.contains(recipe.continuationKind) else {
                return .init(support: .unknown, reasonCode: "adapter_recipe_gap")
            }
            return .init(support: .supported, availableIntents: control.availableIntents ?? [])
        case "custom_only":
            return .init(support: .unknown, availableIntents: control.availableIntents ?? [], reasonCode: control.reasonCode)
        default:
            return .init(support: .unknown, reasonCode: "control_state_unknown")
        }
    }
}

public extension ProviderRecipeAdapterCapabilities {
    /// What the shipped wire core can execute for a given transport.
    ///
    /// A recipe is only applied when every part of it is on these lists. The parser names are
    /// enumerated rather than pattern-matched so that a recipe naming a parser this build does
    /// not implement is refused outright instead of falling into a lookalike code path.
    static func providerTextProduction(transport: ProviderWireTransport) -> Self {
        let protocolName = ProviderRecipeCompiler.canonicalTransport(transport.rawValue)
        let parsers: Set<String>
        let continuations: Set<String>
        let endpointClasses: Set<String>
        let headers: Set<String>
        switch transport {
        case .openAIChat:
            parsers = [
                "deepseek_reasoning_v1", "fireworks_reasoning_v1", "grok_reasoning_v1",
                "groq_reasoning_v1", "mistral_reasoning_v1", "moonshot_builtin_web_v1",
                "moonshot_formula_web_v1", "moonshot_reasoning_v1", "openai_chat_generation_v1",
                "openai_chat_reasoning_v1", "openai_chat_web_v1", "openrouter_reasoning_v1",
                "openrouter_web_v1", "minimax_anthropic_web_v1", "qwen_chat_search_v1", "qwen_reasoning_v1",
                "siliconflow_reasoning_v1", "together_reasoning_v1", "zhipu_reasoning_v1",
                "zhipu_web_search_v1",
            ]
            continuations = ["none", "replay_blocks", "replay_reasoning", "tool_loop"]
            endpointClasses = ["chat_completions", "messages"]
            headers = ["Content-Type", "anthropic-version"]
        case .openAIResponses:
            parsers = ["grok_reasoning_v1", "grok_web_search_v1", "openai_responses_generation_v1",
                       "openai_responses_reasoning_v1", "openai_responses_web_v1"]
            continuations = ["none", "previous_id"]
            endpointClasses = ["responses"]
            headers = []
        case .anthropicMessages:
            parsers = ["anthropic_messages_generation_v1", "anthropic_thinking_v1", "anthropic_web_search_v1"]
            continuations = ["none", "replay_blocks"]
            endpointClasses = ["messages"]
            headers = ["anthropic-version"]
        case .geminiGenerate:
            parsers = ["gemini_generate_content_generation_v1", "gemini_google_search_v1", "gemini_thinking_v1"]
            continuations = ["none", "replay_blocks"]
            endpointClasses = ["generate_content"]
            headers = []
        default:
            parsers = []
            continuations = []
            endpointClasses = []
            headers = []
        }
        return .init(
            transports: transport == .openAIChat
                ? [protocolName, "anthropic_messages"]
                : [protocolName],
            executionKinds: transport == .openAIChat
                ? ["request_overlay", "server_tool", "client_tool_loop", "endpoint_route", "model_route"]
                : ["request_overlay", "server_tool", "client_tool_loop", "model_route"],
            responseParsers: parsers,
            continuationKinds: continuations,
            endpointClasses: endpointClasses,
            requestMappers: transport == .openAIChat ? ["minimax_anthropic_messages_v1"] : [],
            requiredHeaders: headers
        )
    }
}

public struct ProviderCapabilityCompilationResult: Hashable, Sendable {
    public var requestBody: ProviderRecipeValue
    public var applied: [CompiledProviderPlan]
    public var rejectedCapabilities: [String: String]
}

public enum ProviderContinuationReplayError: Error, Equatable, Sendable {
    case missingReasoningContent
    case missingPreviousResponseID
    case missingAnthropicThinkingBlock
    case missingGeminiThoughtSignature
}

/// Enforces the continuation contract across a tool-calling loop.
///
/// Several providers only accept the next request in a loop if it replays something the
/// previous turn produced - a reasoning block, a response id, a thinking block with its
/// signature, a thought signature. Losing that state produces an upstream rejection several
/// steps later, so the guard watches the stream and fails at the tool call itself, where the
/// missing piece is still obvious. It inspects wire events only and holds no UI state.
public struct ProviderContinuationReplayGuard: Sendable {
    private let continuationKind: String?
    private let transport: ProviderWireTransport
    private var reasoningContent = ""
    private var opaqueFields: [String: ProviderRecipeValue] = [:]

    public init(continuationKind: String?, transport: ProviderWireTransport) {
        self.continuationKind = continuationKind
        self.transport = transport
    }

    public mutating func observe(_ event: ProviderStreamEvent) throws {
        switch event {
        case .reasoningDelta(let text):
            reasoningContent += text
        case .opaqueContinuation(let value):
            if let fields = value.objectValue {
                for (key, value) in fields { opaqueFields[key] = value }
            }
        case .toolCall:
            try validateBeforeToolCall()
        default:
            break
        }
    }

    private func validateBeforeToolCall() throws {
        switch continuationKind {
        case nil, "none", "tool_loop":
            return
        case "replay_reasoning":
            guard !reasoningContent.isEmpty || opaqueFields["reasoning_details"] != nil else {
                throw ProviderContinuationReplayError.missingReasoningContent
            }
        case "previous_id":
            guard opaqueFields["previous_response_id"]?.stringValue?.isEmpty == false else {
                throw ProviderContinuationReplayError.missingPreviousResponseID
            }
        case "replay_blocks" where transport == .anthropicMessages:
            guard opaqueFields["thinking"]?.stringValue?.isEmpty == false,
                  opaqueFields["signature"]?.stringValue?.isEmpty == false else {
                throw ProviderContinuationReplayError.missingAnthropicThinkingBlock
            }
        case "replay_blocks" where transport == .geminiGenerate:
            guard opaqueFields["thought_signature"]?.stringValue?.isEmpty == false else {
                throw ProviderContinuationReplayError.missingGeminiThoughtSignature
            }
        default:
            return
        }
    }
}

/// Compiles the capabilities a user turned on into a single request body.
///
/// Selections are applied one at a time onto the running body, so each capability sees the
/// result of the previous one, and a capability that cannot be compiled is recorded in
/// `rejectedCapabilities` with a reason instead of silently dropping out or taking the rest of
/// the request down with it.
public enum ProviderCapabilityRequestCompiler {
    public static func compile(
        baseBody: ProviderRecipeValue,
        snapshot: ProviderModelRecipeSnapshot?,
        selections: [ProviderCapabilitySelection],
        providerKind: String,
        transport: ProviderWireTransport,
        adapter: ProviderRecipeAdapterCapabilities,
        modelID: String? = nil
    ) -> ProviderCapabilityCompilationResult {
        guard let snapshot else {
            return .init(
                requestBody: baseBody,
                applied: [],
                rejectedCapabilities: Dictionary(
                    selections.map { ($0.capability, "authority_missing") },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        let snapshotIsValid = snapshot.schemaVersion == 2
            && !snapshot.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelMatches = modelID.map { snapshot.canonicalModelID == $0 } ?? true
        guard snapshotIsValid, modelMatches else {
            let reason = snapshotIsValid ? "recipe_snapshot_model_mismatch" : "recipe_snapshot_invalid"
            return .init(
                requestBody: baseBody,
                applied: [],
                rejectedCapabilities: Dictionary(
                    selections.map { ($0.capability, reason) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        var body = baseBody
        var applied: [CompiledProviderPlan] = []
        var rejected: [String: String] = [:]
        var seen = Set<String>()
        let counts = Dictionary(grouping: selections, by: \.capability).mapValues(\.count)
        for selection in selections {
            if counts[selection.capability, default: 0] > 1 {
                rejected[selection.capability] = "duplicate_capability_selection"
                continue
            }
            guard seen.insert(selection.capability).inserted else {
                rejected[selection.capability] = "duplicate_capability_selection"
                continue
            }
            let resolution = ProviderCapabilityResolver.resolve(
                capability: selection.capability,
                snapshot: snapshot,
                adapter: adapter
            )
            guard resolution.support == .supported,
                  selection.selectedIntent.map(resolution.availableIntents.contains) ?? true,
                  let control = snapshot.capabilityControls[selection.capability],
                  let recipeRef = control.recipeRef else {
                rejected[selection.capability] = resolution.reasonCode ?? "intent_not_available"
                continue
            }
            do {
                let plan = try ProviderRecipeCompiler.compile(
                    recipeRef: recipeRef,
                    runtime: snapshot.runtime,
                    context: .init(
                        providerKind: providerKind,
                        transport: transport.rawValue,
                        capability: selection.capability,
                        selectedIntent: selection.selectedIntent,
                        availableIntents: resolution.availableIntents
                    ),
                    adapter: adapter,
                    baseBody: body
                )
                body = plan.requestBody
                applied.append(plan)
            } catch let failure as ProviderRecipeCompileFailure {
                rejected[selection.capability] = failure.rawValue
            } catch {
                rejected[selection.capability] = "recipe_compile_failed"
            }
        }
        return .init(requestBody: body, applied: applied, rejectedCapabilities: rejected)
    }
}
