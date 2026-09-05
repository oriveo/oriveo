import Foundation

/// Production-only bridge between a runtime-selected recipe and the local opaque
/// continuation sidecar.  It deliberately resolves the same exact capability
/// control the request compiler uses; a missing, malformed, or mismatched recipe
/// is a clean restart rather than a model-name fallback.
enum RecipeContinuationRuntime {
    /// Services use the live local-only store by default. Tests can install an isolated store for
    /// one async task without a global mutable override or any Service API seam.
    @TaskLocal static var storeFactory: (@Sendable () throws -> RecipeContinuationStore)?

    static func withStore<T: Sendable>(
        _ store: RecipeContinuationStore,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $storeFactory.withValue({ store }) { try await operation() }
    }

    static func selectedRecipe(
        provider: ProviderKind,
        modelID: String,
        transport: String,
        webSearchEnabled: Bool,
        reasoningMode: ReasoningMode,
        continuationKind: String,
        parser: (String) -> Bool
    ) -> MetadataClient.CapabilityRecipe? {
        var candidates: [MetadataClient.CapabilityRecipe] = []
        if webSearchEnabled,
           let recipe = MetadataClient.shared.syncCapabilityRecipe(
                modelID: modelID, providerKind: provider, capability: "web"
           ) {
            candidates.append(recipe)
        }
        if reasoningMode != .automatic,
           let recipe = MetadataClient.shared.syncCapabilityRecipe(
                modelID: modelID, providerKind: provider, capability: "reasoning"
           ) {
            candidates.append(recipe)
        }
        let executable: (MetadataClient.CapabilityRecipe) -> Bool = { candidate in
            CapabilityRecipeExecution.mayExecute(candidate)
                && canonicalTransport(candidate.transport.protocolName) == canonicalTransport(transport)
        }

        // A Moonshot Formula/builtin loop owns the whole completed assistant/tool
        // transcript, including reasoning_content.  A simultaneously active reasoning
        // recipe must neither veto that loop nor overwrite its sidecar at completion.
        // This is deliberately capability-aware rather than relying on candidate order.
        let webToolLoop = candidates.first { candidate in
            candidate.capability == "web"
                && candidate.executionKind == "client_tool_loop"
                && candidate.continuationKind == "tool_loop"
                && executable(candidate)
        }
        if continuationKind == "tool_loop" {
            guard let recipe = webToolLoop,
                  recipe.responseParserKind.map(parser) == true else { return nil }
            return recipe
        }
        guard webToolLoop == nil else { return nil }

        return candidates.first { candidate in
            executable(candidate)
                && candidate.continuationKind == continuationKind
                && candidate.responseParserKind.map(parser) == true
        }
    }

    static func previousResponseID(
        explicitMessageID: UUID?, kind: String = "previous_id"
    ) -> String? {
        guard let explicitMessageID,
              let snapshot = try? store().load(messageID: explicitMessageID),
              snapshot.kind == kind,
              !snapshot.interrupted,
              case let .string(value)? = snapshot.state["previousResponseId"],
              continuationStateIsValid(kind: kind, state: snapshot.state),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func load(messageID: UUID) -> RecipeContinuationStore.Snapshot? {
        try? store().load(messageID: messageID)
    }

    static func markInterrupted(messageID: UUID) throws {
        try store().markInterrupted(messageID: messageID)
    }

    /// Captures the exact valid sidecar used by an explicit request.  The caller acknowledges it
    /// only after the provider has completed successfully.  A normal send has no explicit ID and
    /// therefore never obtains a token or reads opaque state.
    static func explicitConsumptionToken(
        explicitMessageID: UUID?
    ) -> RecipeContinuationStore.ConsumptionToken? {
        guard let messageID = explicitMessageID,
              let snapshot = try? store().load(messageID: messageID),
              !snapshot.interrupted,
              continuationStateIsValid(kind: snapshot.kind, state: snapshot.state) else {
            return nil
        }
        return .init(messageID: messageID, revision: snapshot.revision)
    }

    @discardableResult
    static func acknowledgeExplicitConsumption(
        _ token: RecipeContinuationStore.ConsumptionToken
    ) throws -> Bool {
        try store().discard(token)
    }

    static func replayBlocks(explicitMessageID: UUID?) -> [[String: Any]]? {
        guard let explicitMessageID,
              let snapshot = try? store().load(messageID: explicitMessageID),
              snapshot.kind == "replay_blocks",
              !snapshot.interrupted,
              continuationStateIsValid(kind: "replay_blocks", state: snapshot.state),
              case let .array(values)? = snapshot.state["blocks"] else { return nil }
        let blocks = values.map(\.foundationValue).compactMap { $0 as? [String: Any] }
        return blocks.count == values.count && !blocks.isEmpty ? blocks : nil
    }

    static func replayAssistantMessages(explicitMessageID: UUID?) -> [[String: Any]]? {
        guard let explicitMessageID,
              let snapshot = try? store().load(messageID: explicitMessageID),
              snapshot.kind == "replay_reasoning",
              !snapshot.interrupted,
              continuationStateIsValid(kind: "replay_reasoning", state: snapshot.state),
              case let .array(values)? = snapshot.state["assistantMessages"] else { return nil }
        let messages = values.map(\.foundationValue).compactMap { $0 as? [String: Any] }
        return messages.count == values.count && !messages.isEmpty ? messages : nil
    }

    static func save(
        messageID: UUID?,
        recipe: MetadataClient.CapabilityRecipe?,
        state: [String: MetadataClient.JSONValue]
    ) throws {
        guard let messageID, let recipe, !state.isEmpty else { return }
        try store().save(
            messageID: messageID,
            kind: recipe.continuationKind ?? "",
            state: state
        )
    }

    static func jsonValue(_ object: Any) -> MetadataClient.JSONValue? {
        guard JSONSerialization.isValidJSONObject(["value": object]),
              let data = try? JSONSerialization.data(withJSONObject: ["value": object]),
              case let .object(values) = try? JSONDecoder().decode(MetadataClient.JSONValue.self, from: data)
        else { return nil }
        return values["value"]
    }

    static func canonicalTransport(_ value: String) -> String {
        switch value {
        case "gemini_generate": return "gemini_generate_content"
        default: return value
        }
    }

    private static func store() throws -> RecipeContinuationStore {
        try storeFactory?() ?? RecipeContinuationStore()
    }

    private static func continuationStateIsValid(
        kind: String, state: [String: MetadataClient.JSONValue]
    ) -> Bool {
        RequestPreferenceResolver.validateContinuation(.init(
            kind: kind, variant: nil, step: 1,
            state: state.mapValues(requestPreferenceValue)
        )).accepted
    }

    private static func requestPreferenceValue(
        _ value: MetadataClient.JSONValue
    ) -> RequestPreferenceJSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .number(value):
            return value.rounded() == value ? .int(Int(value)) : .double(value)
        case let .string(value): return .string(value)
        case let .array(value): return .array(value.map(requestPreferenceValue))
        case let .object(value): return .object(value.mapValues(requestPreferenceValue))
        }
    }
}
