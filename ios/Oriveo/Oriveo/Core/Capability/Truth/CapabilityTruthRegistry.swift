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
