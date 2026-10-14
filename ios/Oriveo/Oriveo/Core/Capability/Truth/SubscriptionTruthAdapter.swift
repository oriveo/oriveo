import Foundation

/// Capability truth adapter for subscriptions (Codex / Grok subscription login): upstream `/models` snapshot -> evidence candidates.
///
/// Subscription models are not in the official `/api/metadata`; capabilities are copied from the per-model declarations of the subscription proxy `/models`.
/// `ProviderManager` has already folded `input_modalities` / `web_search_tool_type` / the level table into
/// `provider.catalogModels`. The level filter uses the same `codexReasoningEffort` as the outbound path: if the ruling says a level exists
/// but the outbound path cannot send it, the result is "the UI lets you pick it, the request never sends it". Pure function: no network, no credentials; the level source is injected as a closure.
enum SubscriptionTruthAdapter: CapabilityTruthAdapter {
    /// Three states (contract `rules.subscription`): empty catalog -> no candidates; non-empty catalog without this model ->
    /// every key the catalog governs becomes `catalog_absent` (`tool_call` is not produced); found -> read the entry.
    static func candidates(_ input: CapabilityTruthInput) -> [CapabilityEvidenceFacade.Candidate] {
        guard let subscription = input.subscription else { return [] }
        let query = input.query
        let transport = subscription.finalTransport
        let entry: AIModel
        if let catalogModels = input.catalogModels {
            guard !catalogModels.isEmpty else { return [] }
            guard let found = catalogModels.first(where: { $0.id == input.model.id }) else {
                return input.keys.filter(governs).map { key in
                    CapabilityEvidenceFacade.Candidate(
                        key: key, support: .unknown, source: .catalogAbsent, grade: .none,
                        scope: .providerModelTransport, providerKind: query.providerKind,
                        modelID: query.effectiveModelID, transport: transport
                    )
                }
            }
            entry = found
        } else {
            entry = input.model
        }

        // When the first-hand level declaration is non-empty the source is the upstream declaration; once empty we fall to the model-facts dictionary, and the source must honestly be marked second-hand.
        let declaredLevels = subscription.declaredReasoningLevels(entry)
        let reasoningSource: CapabilityEvidenceFacade.Source =
            entry.upstreamReasoningLevels.isEmpty ? .modelFacts : .upstreamDeclaration

        return input.keys.compactMap { key in
            guard let (support, source) = verdict(for: key, entry: entry,
                                                  declaredLevels: declaredLevels,
                                                  reasoningSource: reasoningSource) else { return nil }
            return CapabilityEvidenceFacade.Candidate(
                key: key, support: support, source: source, grade: .declared,
                scope: .providerModelTransport, providerKind: query.providerKind,
                modelID: query.effectiveModelID, transport: transport
            )
        }
    }

    private static func governs(_ key: String) -> Bool {
        key == "vision_input" || key == "web_search" || key.hasPrefix("reasoning_level/")
    }

    private static func verdict(
        for key: String,
        entry: AIModel,
        declaredLevels: [String],
        reasoningSource: CapabilityEvidenceFacade.Source
    ) -> (CapabilityEvidenceFacade.Support, CapabilityEvidenceFacade.Source)? {
        switch key {
        case "vision_input":
            return (entry.capabilities.contains(.image) ? .supported : .unsupported, .upstreamDeclaration)
        case "web_search":
            return (entry.capabilities.contains(.web) ? .supported : .unsupported, .upstreamDeclaration)
        case "tool_call":
            // Only conclude when upstream declared the boolean first-hand; if undeclared, produce no candidate and do not guess from the model id.
            guard let toolCall = entry.toolCall else { return nil }
            return (toolCall ? .supported : .unsupported, .upstreamDeclaration)
        default:
            guard key.hasPrefix("reasoning_level/"),
                  let mode = ReasoningMode.fromIntent(String(key.dropFirst("reasoning_level/".count)))
            else { return nil }
            let effort = OpenAIService.codexReasoningEffort(for: mode, declaredLevels: declaredLevels)
            return (effort == nil ? .unsupported : .supported, reasoningSource)
        }
    }
}
