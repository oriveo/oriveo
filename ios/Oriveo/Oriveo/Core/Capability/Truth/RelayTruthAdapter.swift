import Foundation

/// Relay capability truth adapter: the connection's own declaration + the envelope of that transport -> evidence candidates.
///
/// A Relay catalog lives on the user's own machine and has no official evidence: a declaration of "supported" can only become unknown
/// (the user tries it after expressing intent explicitly); only a capability the envelope cannot carry at all is explicitly unsupported.
enum RelayTruthAdapter: CapabilityTruthAdapter {
    static func candidates(_ input: CapabilityTruthInput) -> [CapabilityEvidenceFacade.Candidate] {
        guard let relay = input.relay else { return [] }
        return input.keys.compactMap { key in
            declarationCandidate(
                key: key, providerKind: input.providerKind, model: input.model,
                relay: relay, query: input.query
            )
        }
    }

    private static func declarationCandidate(
        key: String,
        providerKind: ProviderKind,
        model: AIModel,
        relay: CapabilityTruthInput.Relay,
        query: CapabilityEvidenceFacade.Query
    ) -> CapabilityEvidenceFacade.Candidate? {
        let envelopeCapabilities = relay.envelopeCapabilities
        // Per-model declaration from the local engine: when a key has a declaration, no other source for that key is consulted, and nil falls through to the existing rules below;
        // the wire gate (the envelope cannot carry it) still comes before the declaration.
        let engineDeclaration = relay.consumesEngineDeclaration ? model.engineDeclaration : nil
        // Override values (user / tested) are the highest source for vision / tools and beat the engine declaration and all other candidates.
        let overrides = model.relayCapabilityOverrides
        let support: CapabilityEvidenceFacade.Support
        switch key {
        case "tool_call":
            if let overridden = overrides?.toolCall {
                support = overridden ? .supported : .unsupported
            } else if let declared = engineDeclaration?.toolCall {
                support = declared ? .supported : .unsupported
            } else {
                guard let declared = model.toolCall else { return nil }
                support = declared ? .unknown : .unsupported
            }
        case "web_search":
            // Relay web search truth: user override of web > current record (under the effective fragment hash) searched / rejected > unknown.
            // The effective fragment = the saved fragment ?? the first-send protocol's template; it does not look at the catalog, the profile inherited by the model, or the web switch in chat.
            guard let webFragment = relay.webFragment else { return nil }
            if RelayCapabilityTest.isUserSet(overrides, .web), let overridden = overrides?.web {
                support = overridden ? .supported : .unsupported
            } else {
                switch webFragment.probe {
                case .searched?: support = .supported
                case .rejected?: support = .unsupported
                case .silent?, nil: support = .unknown
                }
            }
        case "vision_input":
            if !envelopeCapabilities.contains(.image) { support = .unsupported }
            else if let overridden = overrides?.image { support = overridden ? .supported : .unsupported }
            else if let declared = engineDeclaration?.image { support = declared ? .supported : .unsupported }
            else if model.capabilities.contains(.image) { support = .unknown }
            else { return nil }
        default:
            guard key.hasPrefix("reasoning_level/") else { return nil }
            let rawLevel = String(key.dropFirst("reasoning_level/".count))
            guard let mode = ReasoningMode.fromIntent(rawLevel) else { return nil }
            if !envelopeCapabilities.contains(.reasoning) { support = .unsupported }
            else if CapabilityEvidenceProductionAdapter.trimmedNonEmpty(model.reasoningProfile) != nil,
                    relay.supportedReasoningModes(model.reasoningProfile).contains(mode) { support = .unknown }
            else { return nil }
        }
        return .init(
            key: key, support: support, source: .relayDeclaration,
            grade: support == .unknown ? .acceptedUnverified : .declared,
            scope: .connectionModelTransport,
            partitionID: query.partitionID, providerKind: providerKind.rawValue,
            modelID: query.effectiveModelID, transport: query.effectiveTransport,
            connectionInstanceID: query.connectionInstanceID,
            connectionGeneration: query.connectionGeneration,
            credentialEpoch: query.credentialEpoch,
            endpointFingerprint: query.endpointFingerprint,
            metadataRevision: query.metadataRevision
        )
    }
}
