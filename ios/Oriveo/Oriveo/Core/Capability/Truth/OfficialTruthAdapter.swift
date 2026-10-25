import Foundation

/// Official Provider capability truth adapter: parsed official metadata -> evidence candidates.
///
/// Candidates come from two sources: keys already claimed by the evidence namespace use the candidates the Server sends as-is;
/// keys that are not claimed are filled in with the fallback candidates below.
enum OfficialTruthAdapter: CapabilityTruthAdapter {
    static func candidates(_ input: CapabilityTruthInput) -> [CapabilityEvidenceFacade.Candidate] {
        guard let official = input.official else { return [] }
        let resolved = official.resolved
        var candidates = resolved.capabilityEvidenceCandidates
        for key in input.keys {
            guard !resolved.capabilityEvidenceViewMalformed,
                  !resolved.capabilityEvidenceOwnedKeys.contains(key),
                  let legacy = legacyCandidate(
                    key: key, providerKind: input.providerKind, official: official,
                    query: input.query
                  ) else { continue }
            candidates.append(legacy)
        }
        return candidates
    }

    /// Thinking fact: the catalog entry's capabilities contain reasoning; only when the catalog misses is the model-facts reasoning read,
    /// and having neither = false.
    static func thinking(_ source: CapabilityDisplaySource) -> Bool {
        if let entry = source.officialEntry { return entry.capabilities.contains(.reasoning) }
        return source.modelFacts?.reasoning ?? false
    }

    /// The user's own explicit local declaration for an official hand-entered model (catalog miss and no answer from modelFacts); nil = no declaration.
    /// Models inside the catalog do not come here: tool_call only trusts catalog evidence and never falls back to the top-level `toolCall`.
    static func handEnteredToolCallDeclaration(_ model: AIModel) -> Bool? {
        guard model.isManual else { return nil }
        return model.toolCall
    }

    /// Official fallback candidate for a key the evidence namespace has not claimed.
    ///
    /// `tool_call` only trusts candidates from the evidence namespace (same rule as `ToolCallCapabilityPolicy.catalogVerdict`),
    /// so no fallback candidate is produced here: missing or expired is unknown, and the catalog's top-level `toolCall` is not used as a fallback.
    /// `web_search` and the three input keys consume only the exact v2 verdict of `CapabilityControlResolution`; unknown stays unknown,
    /// using the same criterion as the model library badge, the model control panel and the composer chip.
    private static func legacyCandidate(
        key: String,
        providerKind: ProviderKind,
        official: CapabilityTruthInput.Official,
        query: CapabilityEvidenceFacade.Query
    ) -> CapabilityEvidenceFacade.Candidate? {
        let resolved = official.resolved
        let verdict: (CapabilityEvidenceFacade.Support, CapabilityEvidenceFacade.Source, CapabilityEvidenceFacade.Grade)?
        switch key {
        case "tool_call":
            // Official tool_call only trusts evidence candidates; the top-level toolCall is no longer a fallback.
            verdict = nil
        case "web_search":
            // Same source as the model library badge / model control panel: only the v2 exact verdict counts
            // (including unavailable); unknown no longer revives automatic fields through the legacy profile.
            switch official.webState() {
            case .autoAvailable, .managedOnly:
                verdict = (.supported, .serverProfile, .declared)
            case .unavailable:
                verdict = (.unsupported, .serverProfile, .declared)
            case .customOnly, .unknown:
                // customOnly = can only go out through the user's own custom fragment, with no automatically executable verdict;
                // unknown = honestly no evidence. Neither produces a candidate; both are left for the facade to judge as omit_unknown.
                verdict = nil
            }
        case CapabilityEvidenceFacade.visionInputKey,
             CapabilityEvidenceFacade.fileInputKey,
             CapabilityEvidenceFacade.videoInputKey:
            // The three input keys only trust the recipe verdict: a missing key / unknown produces no candidate and no longer falls back to the legacy `capabilities` catalog bit.
            switch official.inputState(key) {
            case .autoAvailable:
                verdict = (.supported, .serverProfile, .declared)
            case .managedOnly, .unavailable:
                // Managed-only is not something this connection can send: same rule as the facade projection's model_absent.
                verdict = (.unsupported, .serverProfile, .declared)
            case .customOnly, .unknown:
                verdict = nil
            }
        default:
            // A level key may carry a local word (`fast`) or a v2 word (`low`); both go through the single reverse mapping.
            if key.hasPrefix("reasoning_level/"),
               let rawLevel = CapabilityEvidenceProductionAdapter.trimmedNonEmpty(
                   String(key.dropFirst("reasoning_level/".count))
               ),
               let mode = ReasoningMode.fromIntent(rawLevel),
               CapabilityEvidenceProductionAdapter.trimmedNonEmpty(resolved.profiles.reasoning) != nil {
                // If the Server declared a thinking ladder for this model, that is **official evidence**: a level on the ladder = supported,
                // a level off the ladder = explicitly unsupported (the "explicitly unsupported with official evidence" side).
                // Previously a level off the ladder became "no candidate", indistinguishable from "we found no documentation",
                // and once the escape hatch was opened, a model like gpt-5-pro that accepts only a single level would have been sent anyway.
                verdict = official.reasoningModes.contains(mode)
                    ? (.supported, .serverProfile, .effectVerified)
                    : (.unsupported, .serverProfile, .declared)
            } else {
                verdict = nil
            }
        }
        guard let verdict else { return nil }
        return .init(
            key: key, support: verdict.0, source: verdict.1, grade: verdict.2,
            scope: .providerModelTransport, providerKind: providerKind.rawValue,
            modelID: query.effectiveModelID, transport: query.effectiveTransport,
            metadataRevision: official.metadataRevision
        )
    }
}
