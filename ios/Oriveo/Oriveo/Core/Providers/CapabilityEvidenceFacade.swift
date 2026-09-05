import Foundation

enum CapabilityEvidenceFacade {
    enum Support: String, Codable, Sendable {
        case supported
        case unsupported
        case unknown
    }

    enum Source: String, Codable, Sendable {
        case serverTyped = "server_typed"
        case serverProfile = "server_profile"
        case relayVerification = "relay_verification"
        case relayDeclaration = "relay_declaration"
        case runtimeObservation = "runtime_observation"
        case operatorOverride = "operator_override"
        case legacyMetadata = "legacy_metadata"
        case none
    }

    enum Grade: String, Codable, Sendable {
        case machineVerified = "machine_verified"
        case effectVerified = "effect_verified"
        case observed
        case declared
        case `operator`
        case acceptedUnverified = "accepted_unverified"
        case legacyUnverified = "legacy_unverified"
        case none
    }

    enum Scope: String, Codable, Sendable {
        case providerModelTransport = "provider_model_transport"
        case connectionModelTransport = "connection_model_transport"
        case exactRequest = "exact_request"
    }

    enum RequestPolicy: String, Codable, Sendable {
        case allow
        case omitUnsupported = "omit_unsupported"
        case omitUnknown = "omit_unknown"
        case allowExplicitUnverified = "allow_explicit_unverified"
        case omitRuntimeRejected = "omit_runtime_rejected"
    }

    enum ReasonCode: String, Codable, Sendable {
        case missingEvidence = "missing_evidence"
        case expired
        case conflict
        case transportMismatch = "transport_mismatch"
        case staleGeneration = "stale_generation"
        case runtimeRejected = "runtime_rejected"
        case userAcceptedUnverified = "user_accepted_unverified"
        case legacyPayload = "legacy_payload"
        case unsupported
        case supported
    }

    struct Query: Equatable, Sendable {
        let partitionID: String
        let connectionInstanceID: String
        let connectionGeneration: String
        let credentialEpoch: String
        let providerKind: String
        let modelID: String
        let canonicalModelID: String?
        let effectiveTransport: String
        let endpointFingerprint: String?
        let metadataRevision: String?
        let generationRevision: String?
        let now: Int64
        let hasExplicitValue: Bool

        init(
            partitionID: String,
            connectionInstanceID: String,
            connectionGeneration: String,
            credentialEpoch: String,
            providerKind: String,
            modelID: String,
            canonicalModelID: String? = nil,
            effectiveTransport: String,
            endpointFingerprint: String? = nil,
            metadataRevision: String? = nil,
            generationRevision: String? = nil,
            now: Int64,
            hasExplicitValue: Bool
        ) {
            self.partitionID = partitionID
            self.connectionInstanceID = connectionInstanceID
            self.connectionGeneration = connectionGeneration
            self.credentialEpoch = credentialEpoch
            self.providerKind = providerKind
            self.modelID = modelID
            self.canonicalModelID = canonicalModelID
            self.effectiveTransport = effectiveTransport
            self.endpointFingerprint = endpointFingerprint
            self.metadataRevision = metadataRevision
            self.generationRevision = generationRevision
            self.now = now
            self.hasExplicitValue = hasExplicitValue
        }

        var effectiveModelID: String { canonicalModelID?.nonEmpty ?? modelID }
    }

    struct Candidate: Codable, Hashable, Sendable {
        let key: String
        let support: Support
        let source: Source
        let grade: Grade
        let scope: Scope
        let policy: RequestPolicy?
        /// The raw upstream verdict, kept verbatim even when `support` collapses it to
        /// `.unknown`. `generationPolicyFor` needs it to tell "nothing was declared" apart from
        /// an explicit negative such as `fixed` or `mode_dependent`.
        let declaredSupport: String?
        let partitionID: String?
        let providerKind: String
        let modelID: String
        let transport: String
        let connectionInstanceID: String?
        let connectionGeneration: String?
        let credentialEpoch: String?
        let endpointFingerprint: String?
        let metadataRevision: String?
        let generationRevision: String?
        let observedAt: Int64?
        let expiresAt: Int64?

        init(
            key: String,
            support: Support,
            source: Source,
            grade: Grade,
            scope: Scope,
            policy: RequestPolicy? = nil,
            declaredSupport: String? = nil,
            partitionID: String? = nil,
            providerKind: String,
            modelID: String,
            transport: String,
            connectionInstanceID: String? = nil,
            connectionGeneration: String? = nil,
            credentialEpoch: String? = nil,
            endpointFingerprint: String? = nil,
            metadataRevision: String? = nil,
            generationRevision: String? = nil,
            observedAt: Int64? = nil,
            expiresAt: Int64? = nil
        ) {
            self.key = key
            self.support = support
            self.source = source
            self.grade = grade
            self.scope = scope
            self.policy = policy
            self.declaredSupport = declaredSupport
            self.partitionID = partitionID
            self.providerKind = providerKind
            self.modelID = modelID
            self.transport = transport
            self.connectionInstanceID = connectionInstanceID
            self.connectionGeneration = connectionGeneration
            self.credentialEpoch = credentialEpoch
            self.endpointFingerprint = endpointFingerprint
            self.metadataRevision = metadataRevision
            self.generationRevision = generationRevision
            self.observedAt = observedAt
            self.expiresAt = expiresAt
        }
    }

    struct PolicyEvidence: Equatable, Sendable {
        let source: Source
        let grade: Grade
    }

    struct Resolution: Equatable, Sendable {
        let key: String
        let support: Support
        let source: Source
        let grade: Grade
        let requestPolicy: RequestPolicy
        let reasonCode: ReasonCode
        let policyEvidence: PolicyEvidence?
    }

    static func generationParameterCandidates(
        from profile: GenerationProfileRef,
        query: Query
    ) -> [Candidate] {
        guard let parameters = profile.parameters else { return [] }
        let transport = profile.transport?.nonEmpty ?? query.effectiveTransport
        guard isConcreteTransport(transport) else { return [] }
        return parameters.compactMap { parameter in
            guard let id = parameter.id?.nonEmpty else { return nil }
            let rawSupport = parameter.support?.nonEmpty ?? "unknown"
            let rawSource = parameter.source?.nonEmpty ?? ""
            let source = source(forGenerationSource: rawSource)
            let isAuthoritativeMetadata = rawSource == "authoritative_metadata"
            let support: Support
            let grade: Grade

            switch rawSupport {
            case Support.supported.rawValue:
                support = .supported
                grade = isAuthoritativeMetadata ? .effectVerified : .declared
            case Support.unsupported.rawValue:
                support = .unsupported
                grade = isAuthoritativeMetadata ? .effectVerified : .declared
            case "accepted", "accepted_unverified":
                support = .unknown
                grade = source == .relayDeclaration ? .acceptedUnverified : .declared
            default:
                // fixed / mode_dependent are not capability negatives. A missing explicit
                // supported/unsupported verdict remains fail-safe unknown.
                support = .unknown
                grade = isAuthoritativeMetadata ? .effectVerified : .declared
            }

            return Candidate(
                key: "generation_parameter/\(id)",
                support: support,
                source: source,
                grade: grade,
                scope: query.providerKind == "relay" ? .connectionModelTransport : .providerModelTransport,
                declaredSupport: rawSupport,
                partitionID: query.providerKind == "relay" ? query.partitionID : nil,
                providerKind: query.providerKind,
                modelID: query.effectiveModelID,
                transport: transport,
                connectionInstanceID: query.providerKind == "relay" ? query.connectionInstanceID : nil,
                connectionGeneration: query.providerKind == "relay" ? query.connectionGeneration : nil,
                credentialEpoch: query.providerKind == "relay" ? query.credentialEpoch : nil,
                endpointFingerprint: query.providerKind == "relay" ? query.endpointFingerprint : nil,
                metadataRevision: query.metadataRevision,
                generationRevision: query.generationRevision
            )
        }
    }

    static func resolve(key: String, query: Query, candidates: [Candidate]) -> Resolution {
        let sameKey = candidates.filter { $0.key == key }
        let identityMatched = sameKey.filter { matchesIdentity($0, query: query) }
        let nonRuntime = identityMatched.filter { $0.policy != .omitRuntimeRejected }
        let liveCandidates = nonRuntime.filter { !isExpired($0, now: query.now) }
        let prioritized = liveCandidates.filter { sourcePriority($0.source) != nil }

        let verdict: Resolution
        if let highest = prioritized.compactMap({ sourcePriority($0.source) }).min() {
            let top = prioritized.filter { sourcePriority($0.source) == highest }
            let supports = Set(top.map(\.support))
            if supports.count > 1 {
                verdict = unknown(key: key, reason: .conflict)
            } else if let selected = top.sorted(by: deterministicOrder).first {
                verdict = policyFor(selected, query: query)
            } else {
                verdict = unknown(key: key, reason: .missingEvidence)
            }
        } else if sameKey.isEmpty, query.hasExplicitValue, !isGenerationParameterKey(key) {
            // Reached only when nothing at all is on record for this key. Evidence that exists
            // but was filtered out by identity, transport or revision is a real signal
            // (`transportMismatch` / `staleGeneration`) and must not be laundered into an
            // "accepted unverified" pass just because the user typed a value.
            verdict = Resolution(
                key: key, support: .unknown, source: .none, grade: .none,
                requestPolicy: .allowExplicitUnverified,
                reasonCode: .userAcceptedUnverified, policyEvidence: nil
            )
        } else {
            verdict = unknown(key: key, reason: fallbackReason(sameKey, query: query))
        }

        if let runtime = identityMatched.first(where: {
            $0.policy == .omitRuntimeRejected && !isExpired($0, now: query.now)
        }) {
            return Resolution(
                key: verdict.key,
                support: verdict.support,
                source: verdict.source,
                grade: verdict.grade,
                requestPolicy: .omitRuntimeRejected,
                reasonCode: .runtimeRejected,
                policyEvidence: PolicyEvidence(source: runtime.source, grade: runtime.grade)
            )
        }
        return verdict
    }

    private static func policyFor(_ candidate: Candidate, query: Query) -> Resolution {
        if isGenerationParameterKey(candidate.key) {
            return generationPolicyFor(candidate, query: query)
        }
        switch candidate.support {
        case .supported:
            return Resolution(
                key: candidate.key, support: candidate.support, source: candidate.source,
                grade: candidate.grade, requestPolicy: .allow, reasonCode: .supported, policyEvidence: nil
            )
        case .unsupported:
            return Resolution(
                key: candidate.key, support: candidate.support, source: candidate.source,
                grade: candidate.grade, requestPolicy: .omitUnsupported, reasonCode: .unsupported, policyEvidence: nil
            )
        case .unknown:
            return Resolution(
                key: candidate.key,
                support: candidate.support,
                source: candidate.source,
                grade: candidate.grade,
                requestPolicy: query.hasExplicitValue ? .allowExplicitUnverified : .omitUnknown,
                reasonCode: query.hasExplicitValue ? .userAcceptedUnverified : .missingEvidence,
                policyEvidence: nil
            )
        }
    }

    static func isGenerationParameterKey(_ key: String) -> Bool {
        key.hasPrefix("generation_parameter/")
    }

    /// Declared verdicts that are negative even though they resolve to `.unknown` support: the
    /// parameter is not freely settable, so an explicit user value is dropped rather than sent.
    private static let officialNegativeGenerationSupports: Set<String> = [
        "unsupported", "fixed", "mode_dependent", "future_supported",
    ]

    /// Decides whether an explicitly set generation parameter is sent upstream.
    ///
    /// `accepted` and `accepted_unverified` are not evidence of support — they only record that
    /// a request carrying the value was not rejected — so they arrive here as `.unknown` and
    /// pass only on the strength of the user having set the value deliberately.
    private static func generationPolicyFor(_ candidate: Candidate, query: Query) -> Resolution {
        switch candidate.support {
        case .supported:
            return Resolution(
                key: candidate.key, support: candidate.support, source: candidate.source,
                grade: candidate.grade, requestPolicy: .allow, reasonCode: .supported, policyEvidence: nil
            )
        case .unsupported:
            return Resolution(
                key: candidate.key, support: candidate.support, source: candidate.source,
                grade: candidate.grade, requestPolicy: .omitUnsupported, reasonCode: .unsupported,
                policyEvidence: nil
            )
        case .unknown:
            // `fixed`, `mode_dependent` and `future_supported` all resolve to `.unknown`
            // support, but each is an explicit "you cannot set this". Consult the raw
            // declaration so the value is omitted instead of being sent and bounced.
            let officialNegative = candidate.declaredSupport
                .map(officialNegativeGenerationSupports.contains) ?? false
            let allowed = query.hasExplicitValue && !officialNegative
            return Resolution(
                key: candidate.key, support: candidate.support, source: candidate.source,
                grade: candidate.grade,
                requestPolicy: allowed ? .allowExplicitUnverified : .omitUnknown,
                reasonCode: allowed ? .userAcceptedUnverified : .missingEvidence,
                policyEvidence: nil
            )
        }
    }

    private static func unknown(key: String, reason: ReasonCode) -> Resolution {
        Resolution(
            key: key, support: .unknown, source: .none, grade: .none,
            requestPolicy: .omitUnknown, reasonCode: reason, policyEvidence: nil
        )
    }

    private static func matchesIdentity(_ candidate: Candidate, query: Query) -> Bool {
        guard query.providerKind.nonEmpty != nil,
              query.effectiveModelID.nonEmpty != nil,
              candidate.providerKind.nonEmpty != nil,
              candidate.modelID.nonEmpty != nil,
              isConcreteTransport(query.effectiveTransport),
              isConcreteTransport(candidate.transport),
              candidate.providerKind == query.providerKind,
              candidate.modelID == query.effectiveModelID,
              candidate.transport == query.effectiveTransport else {
            return false
        }
        if let revision = candidate.metadataRevision, revision != query.metadataRevision { return false }
        if let revision = candidate.generationRevision, revision != query.generationRevision { return false }

        switch candidate.scope {
        case .providerModelTransport:
            return true
        case .connectionModelTransport, .exactRequest:
            // Connection-scoped facts must carry every local identity component. A missing field
            // is not a wildcard: treating it as one would let evidence recorded under another
            // account, or under a credential that has since been rotated, satisfy this query.
            guard query.partitionID.nonEmpty != nil,
                  query.connectionInstanceID.nonEmpty != nil,
                  query.connectionGeneration.nonEmpty != nil,
                  query.credentialEpoch.nonEmpty != nil,
                  query.endpointFingerprint?.nonEmpty != nil,
                  candidate.partitionID?.nonEmpty != nil,
                  candidate.connectionInstanceID?.nonEmpty != nil,
                  candidate.connectionGeneration?.nonEmpty != nil,
                  candidate.credentialEpoch?.nonEmpty != nil,
                  candidate.endpointFingerprint?.nonEmpty != nil else {
                return false
            }
            return candidate.partitionID == query.partitionID
                && candidate.connectionInstanceID == query.connectionInstanceID
                && candidate.connectionGeneration == query.connectionGeneration
                && candidate.credentialEpoch == query.credentialEpoch
                && candidate.endpointFingerprint == query.endpointFingerprint
        }
    }

    static func isConcreteTransport(_ transport: String) -> Bool {
        guard let normalized = transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty else {
            return false
        }
        return normalized != "unknown" && normalized != "auto" && normalized != "unavailable"
    }

    private static func isExpired(_ candidate: Candidate, now: Int64) -> Bool {
        guard let expiresAt = candidate.expiresAt else { return false }
        return expiresAt <= now
    }

    private static func fallbackReason(_ candidates: [Candidate], query: Query) -> ReasonCode {
        guard !candidates.isEmpty else { return .missingEvidence }
        if candidates.contains(where: { $0.providerKind == query.providerKind && $0.modelID == query.effectiveModelID && $0.transport != query.effectiveTransport }) {
            return .transportMismatch
        }
        if candidates.contains(where: {
            $0.providerKind == query.providerKind
                && $0.modelID == query.effectiveModelID
                && $0.transport == query.effectiveTransport
                && (($0.metadataRevision != nil && $0.metadataRevision != query.metadataRevision)
                    || ($0.generationRevision != nil && $0.generationRevision != query.generationRevision))
        }) {
            return .staleGeneration
        }
        if candidates.contains(where: { isExpired($0, now: query.now) }) { return .expired }
        if candidates.contains(where: { sourcePriority($0.source) == nil }) { return .legacyPayload }
        return .missingEvidence
    }

    private static func sourcePriority(_ source: Source) -> Int? {
        switch source {
        case .operatorOverride: return 0
        case .serverTyped: return 1
        case .serverProfile: return 2
        case .relayVerification: return 3
        case .relayDeclaration: return 4
        case .legacyMetadata: return 5
        case .runtimeObservation, .none: return nil
        }
    }

    private static func deterministicOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.grade.rawValue != rhs.grade.rawValue { return lhs.grade.rawValue < rhs.grade.rawValue }
        return (lhs.observedAt ?? 0) > (rhs.observedAt ?? 0)
    }

    private static func source(forGenerationSource raw: String) -> Source {
        switch raw {
        case "authoritative_metadata", "provider_metadata": return .serverProfile
        case "relay_declared": return .relayDeclaration
        case "runtime_feedback": return .runtimeObservation
        case "operator_override": return .operatorOverride
        default: return .legacyMetadata
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
