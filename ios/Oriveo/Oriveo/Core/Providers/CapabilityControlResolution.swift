import Foundation

enum CapabilityControlResolution {
    enum State: String {
        case autoAvailable = "auto_available"
        case managedOnly = "managed_only"
        case customOnly = "custom_only"
        case unavailable
        case unknown
    }

    struct Verdict {
        let state: State
        let intents: [String]
        let reasonCode: String?
        let viaLegacyProfile: Bool

        var isAvailable: Bool { state == .autoAvailable || state == .managedOnly }
    }

    static func resolve(
        provider: Provider,
        model: AIModel,
        capability: String
    ) -> Verdict {
        let verdict = resolveAutomatic(provider: provider, model: model, capability: capability)
        // A relay model-level reasoning-level override only narrows the automatic set; other capabilities such as web search are unaffected.
        guard capability == "reasoning", ProviderForm.of(provider) == .relay,
              let levels = model.relayCapabilityOverrides?.reasoningLevels else { return verdict }
        return Verdict(
            state: verdict.state,
            intents: RelayReasoningLevelOverride.narrowed(verdict.intents, levels: levels),
            reasonCode: verdict.reasonCode,
            viaLegacyProfile: verdict.viaLegacyProfile
        )
    }

    /// The verdict that ignores the relay level override: the Advanced page takes its "automatic available set" from this one, and an override can only narrow within it.
    static func resolveAutomatic(
        provider: Provider,
        model: AIModel,
        capability: String
    ) -> Verdict {
        if isSubscriptionLink(provider) {
            return subscriptionVerdict(provider: provider, model: model, capability: capability)
        }
        if capability == "web", ProviderForm.of(provider) == .relay {
            // A relay does not derive web search from the official recipe: web search is a switch in the chat, and only when it is on
            // is an effective fragment sent (the saved fragment, else the template of the first-choice protocol). The scope follows the first-choice
            // protocol: a local engine or an undecided protocol has no such switch.
            let eligible = RelayWebProbe.effectiveFragments(provider: provider, model: model) != nil
            return Verdict(
                state: eligible ? .customOnly : .unknown, intents: [],
                reasonCode: eligible ? "relay_web_toggle" : "relay_web_unavailable",
                viaLegacyProfile: false
            )
        }
        if capability == "reasoning", ProviderForm.of(provider) == .relay, provider.relayRequested?.engineProfile == nil {
            // Relay reasoning levels come from the server model-facts; when they cannot be had, fall back to the current behavior below
            // (a chat-template switch / manual configuration needed). A local-engine connection still follows the write-path table and does not come here.
            let tiers = RelayReasoningTier.tiers(efforts: relayModelFactsReasoningEfforts(provider: provider, model: model))
            if !tiers.isEmpty {
                return Verdict(
                    state: .autoAvailable,
                    intents: [ModelOptionCapabilityShape.automaticIntent] + tiers.compactMap(\.intentToken),
                    reasonCode: relayModelFactsReasoningCode, viaLegacyProfile: false
                )
            }
        }
        if capability == "web" {
            return webVerdict(
                providerKind: provider.kind,
                modelID: model.id,
                declaresWebCapability: model.capabilities.contains(.web),
                webSearchProfileName: MetadataClient.shared.syncCapabilityEvidenceModelInput(
                    modelID: model.id, providerKind: provider.kind
                ).resolved?.profiles.webSearch
            )
        }
        let control = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        ).controls?[capability]

        if let raw = control?.state, let state = State(rawValue: raw), state != .unknown {
            return Verdict(
                state: state,
                intents: control?.availableIntents ?? [],
                reasonCode: control?.reasonCode,
                viaLegacyProfile: false
            )
        }
        return Verdict(state: .unknown, intents: [], reasonCode: control?.reasonCode, viaLegacyProfile: false)
    }

    static let relayModelFactsReasoningCode = "relay_reasoning_model_facts"

    /// The model-facts reasoning-effort words of a relay model: the family is the one the official catalog matches; only when none matches
    /// is the `model-facts?view=by-model` entry already cached in this session used (no request is made for it). If neither is available the result is empty.
    static func relayModelFactsReasoningEfforts(provider: Provider, model: AIModel) -> [String] {
        let metadata = MetadataClient.shared
        if let match = metadata.syncResolveCatalogModelAcrossProvidersWithProvider(
            modelID: model.id, transportPriority: RelayRuntimeSupport.transportProviderKind(for: provider, model: model)
        ) {
            return metadata.syncModelFacts(providerKind: match.matchedProviderKind, modelID: model.id)?.reasoningEfforts
                ?? metadata.syncModelFacts(
                    providerKind: match.matchedProviderKind, modelID: match.canonicalModelId
                )?.reasoningEfforts
                ?? []
        }
        guard let key = metadata.cachedRelayModelFactsKeyNow(for: model.id) else { return [] }
        return metadata.syncModelFacts(providerKind: key.providerKind, modelID: key.modelID)?.reasoningEfforts ?? []
    }

    static func webVerdict(
        providerKind: ProviderKind,
        modelID: String,
        declaresWebCapability: Bool,
        webSearchProfileName: String?
    ) -> Verdict {
        let control = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: modelID, providerKind: providerKind
        ).controls?["web"]
        if let raw = control?.state, let state = State(rawValue: raw), state != .unknown {
            return Verdict(
                state: state,
                intents: control?.availableIntents ?? [],
                reasonCode: control?.reasonCode,
                viaLegacyProfile: false
            )
        }
        _ = declaresWebCapability
        _ = webSearchProfileName
        return Verdict(state: .unknown, intents: [], reasonCode: control?.reasonCode, viaLegacyProfile: false)
    }

    nonisolated static func isSubscriptionLink(_ provider: Provider) -> Bool {
        provider.authMode == .subscription
    }

    ///   `/responses` + `tools:[{"type":"web_search"}]`
    nonisolated static func subscriptionFinalTransport(for provider: Provider, model: AIModel) -> String? {
        guard isSubscriptionLink(provider) else { return nil }
        switch provider.kind {
        case .openAI: return TransportKind.openaiResponses.rawValue
        case .grok: return grokSubscriptionTransport(model: model).rawValue
        default: return nil
        }
    }

    nonisolated private static func grokSubscriptionTransport(model: AIModel) -> TransportKind {
        if let declared = GrokSubscriptionAuthConfig.transportKind(apiBackend: model.upstreamAPIBackend) {
            return declared
        }
        if case let .available(config) = MetadataClient.shared.syncGrokSubscriptionAvailability(),
           let seeded = GrokSubscriptionAuthConfig.transportKind(apiBackend: config.apiBackend) {
            return seeded
        }
        return .openaiResponses
    }

    static func subscriptionVerdict(
        provider: Provider,
        model: AIModel,
        capability: String
    ) -> Verdict {
        switch capability {
        case "web":
            if provider.kind == .grok,
               subscriptionFinalTransport(for: provider, model: model) != TransportKind.openaiResponses.rawValue {
                return Verdict(
                    state: .unavailable, intents: [],
                    reasonCode: "upstream_transport_without_web_search", viaLegacyProfile: false
                )
            }
            guard model.capabilities.contains(.web) else {
                return Verdict(
                    state: .unavailable, intents: [],
                    reasonCode: "model_capability_absent", viaLegacyProfile: false
                )
            }
            // A Grok subscription always sends web_search outbound (the proxy has no notion of turning search off; see GrokService),
            // so the only level is automatic. The reason code is marked separately so the panel draws a read-only "Always on"
            // instead of a switch that has no effect.
            if provider.kind == .grok {
                return Verdict(
                    state: .autoAvailable, intents: ["automatic"],
                    reasonCode: "subscription_web_always_on", viaLegacyProfile: false
                )
            }
            return Verdict(
                state: .autoAvailable, intents: ["off", "automatic"],
                reasonCode: "subscription_upstream_declared", viaLegacyProfile: false
            )
        case "reasoning":
            let intents = subscriptionReasoningIntents(provider: provider, model: model)
            guard !intents.isEmpty else {
                return Verdict(
                    state: .unavailable, intents: [],
                    reasonCode: "upstream_parameter_not_declared", viaLegacyProfile: false
                )
            }
            return Verdict(
                state: .autoAvailable, intents: intents,
                reasonCode: "subscription_upstream_declared", viaLegacyProfile: false
            )
        default:
            return Verdict(state: .unknown, intents: [], reasonCode: nil, viaLegacyProfile: false)
        }
    }

    nonisolated static func subscriptionDeclaredReasoningLevels(
        providerKind: ProviderKind, model: AIModel?
    ) -> [String] {
        if let firstParty = model?.upstreamReasoningLevels, !firstParty.isEmpty {
            return firstParty
        }
        guard let modelID = model?.id else { return [] }
        return MetadataClient.shared.syncModelFacts(
            providerKind: providerKind, modelID: modelID
        )?.reasoningEfforts ?? []
    }

    nonisolated static func subscriptionDefaultReasoningLevel(
        providerKind: ProviderKind, model: AIModel?
    ) -> String? {
        guard let declared = model?.upstreamDefaultReasoningLevel else { return nil }
        let levels = subscriptionDeclaredReasoningLevels(providerKind: providerKind, model: model)
        return levels.contains(declared) ? declared : nil
    }

    private static func subscriptionReasoningIntents(provider: Provider, model: AIModel) -> [String] {
        let declared = subscriptionDeclaredReasoningLevels(providerKind: provider.kind, model: model)
        return [ReasoningMode.fast, .balanced, .deep, .max].compactMap { mode in
            guard OpenAIService.codexReasoningEffort(for: mode, declaredLevels: declared) != nil else {
                return nil
            }
            return mode.intentToken
        }
    }

}

enum CapabilityControlPresentationResolver {
    static func presentation(
        provider: Provider, model: AIModel, capability: String
    ) -> CapabilityControlPresentation {
        let verdict = CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: capability
        )
        return CapabilityControlPresentation.status(
            state: verdict.state.rawValue,
            reasonCode: verdict.reasonCode,
            exactTransportMatches: verdict.viaLegacyProfile
                || CapabilityControlResolution.isSubscriptionLink(provider)
                // Relay model-facts levels likewise have no recipe: the outbound mapping is decided by the protocol.
                || verdict.reasonCode == CapabilityControlResolution.relayModelFactsReasoningCode
                || hasExactTransportRecipe(provider: provider, model: model, capability: capability)
        )
    }

    static func hasExactTransportRecipe(
        provider: Provider, model: AIModel, capability: String
    ) -> Bool {
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        )
        guard let control = snapshot.controls?[capability] else { return false }
        guard control.state == RequestControlAvailability.autoAvailable.rawValue else { return true }
        guard let recipeRef = control.recipeRef,
              let runtime = snapshot.runtime,
              let recipe = runtime.recipes[recipeRef],
              let modelTransport = MetadataClient.shared.syncResolveCatalogModel(
                  modelID: model.id, providerKind: provider.kind
              )?.transport
        else { return false }
        return CapabilityRecipeRequestCompiler.canonicalTransport(recipe.transport.protocolName)
            == CapabilityRecipeRequestCompiler.canonicalTransport(modelTransport)
    }
}

enum CapabilityWebPreferenceLiveness {
    static func reachesTheWire(
        status: CapabilityControlPresentation, customIsActive: Bool
    ) -> Bool {
        // Always-on (.alwaysOn) counts as read-only: it is not the user's choice, so a stored preference does not light up with it;
        // Grok still always sends web_search outbound, which has nothing to do with this.
        status == .automaticAvailable || customIsActive
    }

    /// The "web permitted" value for the composer globe and the outbound decision: besides the verdict allowing outbound, an always-on
    /// (`.alwaysOn`) capability is not a dialable user choice either, matching Android `hasWebSelection` and Web `modelControlWebReachesTheWire`.
    /// A Grok subscription always sends web_search outbound and does not read this value (`GrokService.buildSubscriptionResponsesRequest`).
    static func composerWebPermitted(
        outboundPermitted: Bool, provider: Provider, model: AIModel
    ) -> Bool {
        outboundPermitted && CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: "web"
        ) != .alwaysOn
    }

    static func reachesTheWire(
        provider: Provider, model: AIModel, conversationID: UUID?,
        forwardPortsStaleCustom: Bool = false
    ) -> Bool {
        let status = CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: "web"
        )
        guard status != .automaticAvailable else { return true }
        guard let identity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
        else { return false }
        let customIsActive = GenerationParameterSettingsStore.shared.effectiveLocalCustomConfiguration(
            providerID: provider.id, modelID: identity.canonicalModelID,
            conversationID: conversationID, transportIdentity: identity.wireValue,
            namespace: "webPatch",
            forwardPort: forwardPortsStaleCustom
                ? .init(providerKind: provider.kind, schemaModelID: model.id)
                : nil
        ).mode == .custom
        return reachesTheWire(status: status, customIsActive: customIsActive)
    }
}

/// Relay model-level reasoning-level override (`relayCapabilityOverrides.reasoningLevels`).
///
/// The five slots are contract vocabulary = the raw `ReasoningMode` values (automatic / fast / balanced / deep / max), and the override stores raw values;
/// conversion to v2 intents: `automatic` <-> `"automatic"`, the rest via `ReasoningMode.intentToken` / `fromIntent`.
/// `off` is a switch rather than a level: it is not one of the five slots and is not removed by an override.
enum RelayReasoningLevelOverride {
    static func intent(of mode: ReasoningMode) -> String? {
        mode == .automatic ? ModelOptionCapabilityShape.automaticIntent : mode.intentToken
    }

    static func mode(ofIntent intent: String) -> ReasoningMode? {
        intent == ModelOptionCapabilityShape.automaticIntent ? .automatic : ReasoningMode.fromIntent(intent)
    }

    /// The automatic available set: the slots resolved from the existing reasoning control (the reasoning intents of `resolveAutomatic`), in the order of the five slots.
    static func automaticModes(provider: Provider, model: AIModel) -> [ReasoningMode] {
        let intents = CapabilityControlResolution.resolveAutomatic(
            provider: provider, model: model, capability: "reasoning"
        ).intents
        let present = Set(intents.compactMap(mode(ofIntent:)))
        return ReasoningMode.allCases.filter(present.contains)
    }

    /// Consumption point: available intents = automatic ∩ override; an intent that is not one of the five slots (such as `off`) is kept as is.
    static func narrowed(_ intents: [String], levels: [String]) -> [String] {
        let allowed = Set(levels)
        return intents.filter { intent in
            guard let mode = mode(ofIntent: intent) else { return true }
            return allowed.contains(mode.rawValue)
        }
    }

    /// Normalization before writing: keeps only slots in the automatic set (narrowing only), in the order of the five slots; an empty set cannot be written (returns `.reject`),
    /// and a set equal to the automatic set deletes the override (returns `.clear`).
    enum Normalized: Equatable {
        case reject
        case clear
        case store([String])
    }

    static func normalized(_ levels: [String], automatic: [ReasoningMode]) -> Normalized {
        let requested = Set(levels)
        let kept = automatic.filter { requested.contains($0.rawValue) }
        if kept.isEmpty { return .reject }
        if kept == automatic { return .clear }
        return .store(kept.map(\.rawValue))
    }
}
