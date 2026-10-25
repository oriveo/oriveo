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
                                                  reasoningSource: reasoningSource,
                                                  modelFactsInput: subscription.modelFactsInputModalities) else { return nil }
            return CapabilityEvidenceFacade.Candidate(
                key: key, support: support, source: source, grade: .declared,
                scope: .providerModelTransport, providerKind: query.providerKind,
                modelID: query.effectiveModelID, transport: transport
            )
        }
    }

    /// Thinking fact = the first-hand level table `upstreamReasoningLevels` declared by upstream is non-empty; when the first-hand one is absent (always empty on a cold start)
    /// it falls back to the model-facts `reasoning`, with the same priority as the level source of truth `subscriptionDeclaredReasoningLevels`.
    static func thinking(_ source: CapabilityDisplaySource) -> Bool {
        if let firstHand = source.catalogEntry?.upstreamReasoningLevels, !firstHand.isEmpty {
            return true
        }
        return source.modelFacts?.reasoning == true
    }

    /// The subscription fact for the outbound tool gate (`ToolCallCapabilityPolicy.catalogVerdict`): the subscription proxy `/models` has no tool field,
    /// so `model.toolCall` is not read; only model-facts is consulted (same lookup as the input keys, `modelFactsLookup`). nil goes to connection memory, then unknown.
    static func toolCallModelFact(providerKind: ProviderKind, model: AIModel) -> Bool? {
        modelFacts(providerKind: providerKind, model: model)?.toolCall
    }

    /// The **only** model-facts lookup for the subscription form: first by `model.id`, and when that misses, by the canonical id resolved from the metadata
    /// `resolveMap`; if resolveMap has nothing it uses `model.id` alone, with no fuzzy matching.
    /// Input modalities, displayed thinking, thinking levels and tool_call all call it. `usedModelID` = the id that actually hit.
    nonisolated static func modelFactsLookup(
        providerKind: ProviderKind, model: AIModel
    ) -> (usedModelID: String, facts: MetadataClient.ModelFacts)? {
        let metadata = MetadataClient.shared
        if let facts = metadata.syncModelFacts(providerKind: providerKind, modelID: model.id) {
            return (model.id, facts)
        }
        guard let canonical = metadata.syncResolveCatalogModel(
            modelID: model.id, providerKind: providerKind
        )?.canonicalModelId, canonical != model.id,
            let facts = metadata.syncModelFacts(providerKind: providerKind, modelID: canonical) else { return nil }
        return (canonical, facts)
    }

    nonisolated static func modelFacts(providerKind: ProviderKind, model: AIModel) -> MetadataClient.ModelFacts? {
        modelFactsLookup(providerKind: providerKind, model: model)?.facts
    }

    private static func governs(_ key: String) -> Bool {
        CapabilityEvidenceFacade.inputCapabilityKeys.contains(key) || key == "web_search" || key.hasPrefix("reasoning_level/")
    }

    /// Media names for an input key (first-hand `input_modalities` and models.dev `modalities.input` share one vocabulary; pdf counts as file).
    private static func inputMedia(for key: String) -> Set<String> {
        switch key {
        case CapabilityEvidenceFacade.visionInputKey: return ["image"]
        case CapabilityEvidenceFacade.fileInputKey: return ["file", "pdf"]
        case CapabilityEvidenceFacade.videoInputKey: return ["video"]
        default: return []
        }
    }

    /// Input-key verdict: first-hand per-model declaration > model-facts (only when the first-hand one is absent) > no candidate (unknown / catalog_silent).
    /// First-hand without the medium = unsupported; model-facts without it is only unknown (third-party facts are not hard evidence).
    /// The legacy capability bits are not read and attachment support is not inferred from providerKind.
    static func inputSupport(
        key: String, firstHand: [String]?, modelFacts: [String]?
    ) -> (CapabilityEvidenceFacade.Support, CapabilityEvidenceFacade.Source)? {
        let media = inputMedia(for: key)
        func declares(_ list: [String]) -> Bool {
            list.contains { media.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        }
        if let firstHand {
            return (declares(firstHand) ? .supported : .unsupported, .upstreamDeclaration)
        }
        if let modelFacts {
            return (declares(modelFacts) ? .supported : .unknown, .modelFacts)
        }
        return nil
    }

    /// Arguments for the input-key projection of a subscription: state / reasonCode are restored from the facade verdict, and the protocol family comes from the subscription's final wire.
    /// A non-empty catalog that lacks this model (catalog_absent) stays rejected, the same rule as "even an explicit user choice does not go outbound" for this source.
    static func inputVerdict(
        key: String,
        resolution: CapabilityEvidenceFacade.Resolution?,
        transport: String?
    ) -> CapabilityEvidenceFacade.InputVerdict {
        let wireFamily = CapabilityEvidenceFacade.inputWireFamily(key: key, transport: transport)
        switch resolution?.support {
        case .supported:
            return .init(state: .autoAvailable, wireFamily: wireFamily)
        case .unsupported:
            return .init(state: .unavailable, reasonCode: "model_capability_absent", wireFamily: wireFamily)
        default:
            switch resolution?.source {
            case .catalogAbsent:
                return .init(state: .unavailable, reasonCode: "catalog_absent", wireFamily: wireFamily)
            case .modelFacts:
                return .init(state: .unknown, wireFamily: wireFamily)
            default:
                return .init(state: .unknown, reasonCode: "catalog_silent", wireFamily: wireFamily)
            }
        }
    }

    private static func verdict(
        for key: String,
        entry: AIModel,
        declaredLevels: [String],
        reasoningSource: CapabilityEvidenceFacade.Source,
        modelFactsInput: (AIModel) -> [String]?
    ) -> (CapabilityEvidenceFacade.Support, CapabilityEvidenceFacade.Source)? {
        switch key {
        case CapabilityEvidenceFacade.visionInputKey, CapabilityEvidenceFacade.fileInputKey,
             CapabilityEvidenceFacade.videoInputKey:
            let firstHand = entry.upstreamInputModalities
            return inputSupport(key: key, firstHand: firstHand,
                                modelFacts: firstHand == nil ? modelFactsInput(entry) : nil)
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
