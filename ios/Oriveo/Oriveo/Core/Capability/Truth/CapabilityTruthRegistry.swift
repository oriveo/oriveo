import Foundation

/// Adapter input: the projection entry point gathers every fact this ruling needs up front, and the adapter reads only this bundle.
///
/// Each form reads only its own segment; segments that do not belong to it are nil. The two checks that need a metadata snapshot are injected as closures,
/// so the adapter never touches `MetadataClient`, never goes online and never reads credentials.
struct CapabilityTruthInput {
    struct Official {
        let resolved: MetadataClient.ResolvedModelMetadata
        let metadataRevision: String?
        let reasoningModes: [ReasoningMode]
        /// The online exact-v2 verdict (`CapabilityControlResolution.webVerdict`); only read when ruling on `web_search`.
        let webState: () -> CapabilityControlResolution.State
        /// The recipe verdict for an input capability key (`CapabilityControlResolution.inputVerdict`); only read when ruling on the three input keys.
        let inputState: (_ key: String) -> CapabilityControlResolution.State
    }

    struct Relay {
        let envelopeCapabilities: Set<ModelCapability>
        /// Levels supported by a reasoning profile; only read when the connection declares a profile.
        let supportedReasoningModes: (_ profileName: String?) -> [ReasoningMode]
        /// Whether `model.engineDeclaration` may be used as evidence: entry points that hold a Provider require the connection to have an
        /// engineProfile; entry points without a Provider trust the declaration on the model (declarations are only written by the local connector).
        var consumesEngineDeclaration = false
        /// Input for web-search truth: nil when out of scope (local engine / undecided protocol); otherwise carries the local probe result recorded under the effective fragment (untested / stale hash = nil).
        var webFragment: WebFragment?

        struct WebFragment: Equatable {
            var probe: RelayWebProbeRecord.Result?
        }
    }

    struct Subscription {
        /// The final outbound protocol of this subscription link (`CapabilityControlResolution.subscriptionFinalTransport`).
        let finalTransport: String
        /// Source of truth for levels (`CapabilityControlResolution.subscriptionDeclaredReasoningLevels`):
        /// the first-hand `upstreamReasoningLevels` win, and only when empty does it fall back to the `model-facts` dictionary. Injected as a closure so the adapter never touches MetadataClient.
        let declaredReasoningLevels: (AIModel) -> [String]
        /// Secondary source for input media (`modalities.input` in the `model-facts` dictionary): only read when the first-hand
        /// `upstreamInputModalities` is absent. nil = the dictionary has no such entry. Injected as a closure so the adapter never touches MetadataClient.
        var modelFactsInputModalities: (AIModel) -> [String]? = { _ in nil }
    }

    let providerKind: ProviderKind
    let model: AIModel
    /// A key that has already passed the safety check; the adapter does not judge key validity again.
    let keys: Set<String>
    let query: CapabilityEvidenceFacade.Query
    var official: Official? = nil
    var relay: Relay? = nil
    var subscription: Subscription? = nil
    /// This form's own catalog snapshot (subscription `/models` listing): entry points that hold a Provider pass
    /// `provider.catalogModels`; serializers that do not pass nil, and the adapter then treats `model` itself as the catalog entry.
    var catalogModels: [AIModel]? = nil
}

/// Capability truth adapter: translates the facts of one form into evidence candidates.
/// It only produces candidates and does not rule: priority, conflicts and the explicit escape hatch all live in `CapabilityEvidenceFacade.resolve`.
protocol CapabilityTruthAdapter {
    static func candidates(_ input: CapabilityTruthInput) -> [CapabilityEvidenceFacade.Candidate]
    /// Display fact: the thinking under the facade's `reasoning` key, i.e. whether the model thinks (shows its reasoning).
    /// Separate from the `reasoning_level/*` levels; produced only from this form's own sources, and a missing source = false (not shown, never guessed).
    static func thinking(_ source: CapabilityDisplaySource) -> Bool
}

/// Input of the display facts: only this form's sources, no request identity (display does not go outbound, so it needs no connection or credential generation).
/// Raw fields are only read inside each `*TruthAdapter`; read points only receive the conclusion.
struct CapabilityDisplaySource {
    let model: AIModel
    /// This form's own catalog snapshot, same meaning as `CapabilityTruthInput.catalogModels`.
    var catalogModels: [AIModel]? = nil
    /// Official: the entry for this model in the metadata catalog; nil = catalog miss.
    var officialEntry: MetadataClient.ResolvedModelMetadata? = nil
    /// The Server `model-facts` (models.dev) facts, only fetched when the official catalog misses or the subscription first-hand levels are absent.
    var modelFacts: MetadataClient.ModelFacts? = nil

    /// The entry in the catalog of catalog-style forms (subscription): when `catalogModels` is nil, `model` itself
    /// is the object generated from the catalog; an empty catalog or a catalog without this model = no source.
    var catalogEntry: AIModel? {
        guard let catalogModels else { return model }
        return catalogModels.first { $0.id == model.id }
    }
}

/// The facade's display facts: every platform's thinking row reads from here instead of reading the legacy capability bits itself.
enum CapabilityDisplayFacts {
    static func thinking(form: ProviderForm, source: CapabilityDisplaySource) -> Bool {
        CapabilityTruthRegistry.adapter(for: form).thinking(source)
    }

    /// Read point for callers holding a Provider: gathers the sources by form, then asks the adapter. model-facts is only queried when the official catalog misses or the subscription first-hand levels are absent.
    static func thinking(provider: Provider, model: AIModel) -> Bool {
        let form = ProviderForm.of(provider)
        var source = CapabilityDisplaySource(model: model, catalogModels: provider.catalogModels)
        switch form {
        case .official:
            source.officialEntry = MetadataClient.shared.syncCapabilityEvidenceModelInput(
                modelID: model.id, providerKind: provider.kind
            ).resolved
            if source.officialEntry == nil {
                source.modelFacts = MetadataClient.shared.syncModelFacts(providerKind: provider.kind, modelID: model.id)
            }
        case .subscription:
            if source.catalogEntry?.upstreamReasoningLevels.isEmpty ?? true {
                source.modelFacts = SubscriptionTruthAdapter.modelFacts(providerKind: provider.kind, model: model)
            }
        default:
            break
        }
        return thinking(form: form, source: source)
    }
}

/// The single registry from form to adapter, matching `forms.adapters` in the shared contract item by item.
/// The switch has no default: when a new form is added, the compiler forces you to take a position here.
enum CapabilityTruthRegistry {
    static func adapter(for form: ProviderForm) -> any CapabilityTruthAdapter.Type {
        switch form {
        case .relay:
            return RelayTruthAdapter.self
        case .subscription:
            return SubscriptionTruthAdapter.self
        case .official:
            return OfficialTruthAdapter.self
        }
    }
}
