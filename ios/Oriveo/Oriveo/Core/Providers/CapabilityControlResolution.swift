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
        if isSubscriptionLink(provider) {
            return subscriptionVerdict(provider: provider, model: model, capability: capability)
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
            return Verdict(
                state: .autoAvailable,
                intents: provider.kind == .grok ? ["automatic"] : ["off", "automatic"],
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
        status == .automaticAvailable || customIsActive
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
