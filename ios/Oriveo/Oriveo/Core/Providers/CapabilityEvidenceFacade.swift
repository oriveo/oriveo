import Foundation

enum CapabilityEvidenceFacade {
    /// The three input capability keys: the facade holds the only definition, and callers reference the constants rather than bare literals.
    static let visionInputKey = "vision_input"
    static let fileInputKey = "file_input"
    static let videoInputKey = "video_input"
    enum Support: String, Codable, Sendable {
        case supported
        case unsupported
        case unknown
    }

    enum Source: String, Codable, Sendable {
        case serverTyped = "server_typed"
        case serverProfile = "server_profile"
        /// Per-model declaration from the subscription proxy's `/models` (`SubscriptionTruthAdapter`); produced only locally on the client.
        case upstreamDeclaration = "upstream_declaration"
        /// The server `model-facts` (models.dev) dictionary; a second-hand source for subscription tiers on a cold start, produced only locally on the client.
        case modelFacts = "model_facts"
        case relayVerification = "relay_verification"
        case relayDeclaration = "relay_declaration"
        case runtimeObservation = "runtime_observation"
        case operatorOverride = "operator_override"
        case legacyMetadata = "legacy_metadata"
        /// The model is not in the authoritative catalog of this form (a subscription catalog produces it). It is not a
        /// capability conclusion and takes no part in priority ordering; its job is to pin the key at unknown and not send it
        /// outbound, even when the user turned it on explicitly.
        case catalogAbsent = "catalog_absent"
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
        case catalogAbsent = "catalog_absent"
    }

    struct Query: Equatable, Sendable {
        let partitionID: String
        let connectionInstanceID: String
        let connectionGeneration: String
        let credentialEpoch: String
        let providerKind: String
        /// The connection's credential form (the raw value of `ProviderAuthMode`). Form derivation needs it: the same
        /// providerKind can be an API Key instance or a subscription instance, and an entry that carries only providerKind cannot tell them apart.
        let authMode: String
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
            authMode: String,
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
            self.authMode = authMode
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
        } else if liveCandidates.contains(where: { $0.source == .catalogAbsent }) {
            // The authoritative catalog does not have this model: this is not "we found no information", so the
            // explicit escape hatch below does not apply, and it is not sent outbound even if the user turned it on explicitly.
            // It takes effect only when there is no valid candidate that carries a priority.
            verdict = Resolution(
                key: key, support: .unknown, source: .catalogAbsent, grade: .none,
                requestPolicy: .omitUnknown, reasonCode: .catalogAbsent, policyEvidence: nil
            )
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
        case .upstreamDeclaration: return 3
        case .modelFacts: return 4
        case .relayVerification: return 5
        case .relayDeclaration: return 6
        case .legacyMetadata: return 7
        case .runtimeObservation, .catalogAbsent, .none: return nil
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

extension CapabilityEvidenceFacade {
    /// A model that can only generate images and gives no text reply: metadata has imageGen but not text, or a Relay dedicated image model.
    /// The voice conversation entry (empty draft) uses it to stay greyed out.
    static func isImageOnlyModel(_ model: AIModel) -> Bool {
        if RelayRuntimeSupport.isDedicatedImageModel(model.id) { return true }
        return model.capabilities.contains(.imageGen) && !model.capabilities.contains(.text)
    }
}

// MARK: - Three input capability keys projection

extension CapabilityEvidenceFacade {
    /// The three input capability keys, in contract order.
    static let inputCapabilityKeys: [String] = [visionInputKey, fileInputKey, videoInputKey]

    /// The wire family implementation table compiled into this client; it matches, entry by entry, the families whose implementedBy includes ios in the shared wire-family contract.
    /// Any family string not in the table counts as not implemented here.
    static let implementedWireFamilies: Set<String> = [
        "openai_chat.image_url",
        "openai_chat.file",
        "openai_chat.video_url",
        "openai_responses.input_image",
        "openai_responses.input_file",
        "anthropic.image",
        "anthropic.document",
        "gemini.inline_data",
    ]

    static func implementsWireFamily(_ family: String) -> Bool {
        implementedWireFamilies.contains(family)
    }

    /// Normalized transport x input key -> wire family (the same table as the Web `WIRE_FAMILY_BY_TRANSPORT`).
    /// Returns nil for an unrecognized transport, or one with no matching family (for example video on Anthropic / Responses).
    static let inputWireFamilyByTransport: [String: [String: String]] = [
        visionInputKey: [
            "openai_chat": "openai_chat.image_url",
            "openai_responses": "openai_responses.input_image",
            "anthropic_messages": "anthropic.image",
            "gemini_generate_content": "gemini.inline_data",
        ],
        fileInputKey: [
            "openai_chat": "openai_chat.file",
            "openai_responses": "openai_responses.input_file",
            "anthropic_messages": "anthropic.document",
            "gemini_generate_content": "gemini.inline_data",
        ],
        videoInputKey: [
            "openai_chat": "openai_chat.video_url",
            "gemini_generate_content": "gemini.inline_data",
        ],
    ]

    /// Transports that can only send plain text (the same set as the Web `TEXT_ONLY_TRANSPORTS`): llama.cpp native folds the whole conversation into one prompt;
    /// Gemini Interactions sends no image parts from this client; DashScope native sends no media blocks from this client.
    static let textOnlyInputTransports: Set<String> = ["llamacpp_native", "gemini_interactions", "dashscope_native"]

    /// Transport name normalization: the catalog's `gemini_generate` and `gemini_generate_content` are the same transport.
    static func canonicalInputTransport(_ transport: String) -> String {
        transport == "gemini_generate" ? "gemini_generate_content" : transport
    }

    /// The wire family of an input key on the given transport; nil = unknown transport or this transport has no such family.
    static func inputWireFamily(key: String, transport: String?) -> String? {
        guard let transport else { return nil }
        return inputWireFamilyByTransport[key]?[canonicalInputTransport(transport)]
    }

    /// Protocol-level output limit rules: whether max_tokens is required, and the default when the model limit is unknown.
    struct ProtocolOutputDefault: Equatable, Sendable {
        let requiresMaxTokens: Bool
        let defaultMaxOutputTokens: Int?
    }

    /// Anthropic Messages requires max_tokens; this is used when the model limit is unknown.
    static let anthropicDefaultMaxOutputTokens = 8192

    /// The protocol default table of this client, matching the shared wire-family contract `protocols` entry by entry.
    /// OpenAI / Gemini families do not require max_tokens, and none is sent when the limit is unknown.
    static let protocolOutputDefaults: [String: ProtocolOutputDefault] = [
        "openai_chat": ProtocolOutputDefault(requiresMaxTokens: false, defaultMaxOutputTokens: nil),
        "openai_responses": ProtocolOutputDefault(requiresMaxTokens: false, defaultMaxOutputTokens: nil),
        "anthropic": ProtocolOutputDefault(requiresMaxTokens: true, defaultMaxOutputTokens: anthropicDefaultMaxOutputTokens),
        "gemini": ProtocolOutputDefault(requiresMaxTokens: false, defaultMaxOutputTokens: nil),
    ]

    /// The protocol default for a transport; a transport not in the table is treated as not requiring max_tokens.
    static func protocolOutputDefault(for transport: TransportKind) -> ProtocolOutputDefault? {
        protocolKey(for: transport).flatMap { protocolOutputDefaults[$0] }
    }

    /// Transport -> protocol key of the shared contract (wire_families and the rejection-signature table byProtocol use the same names);
    /// the wire family of the parameter negative cache `param:<name>` also records this key. nil for a transport not in the table.
    static func protocolKey(for transport: TransportKind) -> String? {
        switch transport {
        case .openaiChat: return "openai_chat"
        case .openaiResponses: return "openai_responses"
        case .anthropicMessages: return "anthropic"
        case .geminiGenerate, .geminiInteractions: return "gemini"
        default: return nil
        }
    }

    /// Official Anthropic places a cache_control breakpoint only when the model catalog declares this promptCache policy.
    static let anthropicExplicitPromptCachePolicy = "anthropic.explicit"

    /// Whether the official route places a breakpoint: a missing catalog / missing policyRef / non-explicit never places one. Relay does not go through here.
    static func placesOfficialAnthropicCacheBreakpoint(policyRef: String?) -> Bool {
        policyRef == anthropicExplicitPromptCachePolicy
    }

    /// Reasons an input capability is disabled; the raw value is the localization key (character for character the same as the shared fixture `disabled.*` literals).
    enum InputDisabledReason: String, Sendable, CaseIterable {
        case modelAbsent = "disabled.model_absent"
        case wireNotImplemented = "disabled.wire_not_implemented"
        case killSwitch = "disabled.kill_switch"
        case rejectedRecently = "disabled.rejected_recently"
        case userRemoved = "disabled.user_removed"
    }

    /// The recipe verdict of one input key; a nil value means the payload lacks this key (projected as unknown).
    struct InputVerdict: Equatable, Sendable {
        let state: CapabilityControlResolution.State
        let reasonCode: String?
        let wireFamily: String?

        init(state: CapabilityControlResolution.State, reasonCode: String? = nil, wireFamily: String? = nil) {
            self.state = state
            self.reasonCode = reasonCode
            self.wireFamily = wireFamily
        }
    }

    enum InputConnection: String, Sendable {
        case official
        case relay
    }

    /// User override (takes effect only on Relay connections).
    enum InputOverride: String, Sendable {
        case add
        case remove
    }

    /// The input capability projection: produced only by `inputCapabilityProjection` and cannot be constructed outside the facade.
    struct InputCapabilityProjection: Equatable, Sendable {
        enum Outbound: String, Sendable {
            case nativePart = "native_part"
            case placeholder
        }

        enum Hint: String, Sendable {
            case firstAttachOnce = "first_attach_once"
        }

        let visible: Bool
        let editable: Bool
        let outbound: Outbound
        let hint: Hint?
        let disabledReason: InputDisabledReason?

        fileprivate init(visible: Bool, editable: Bool, outbound: Outbound, hint: Hint?, disabledReason: InputDisabledReason?) {
            self.visible = visible
            self.editable = editable
            self.outbound = outbound
            self.hint = hint
            self.disabledReason = disabledReason
        }

        fileprivate static let available = InputCapabilityProjection(
            visible: true, editable: true, outbound: .nativePart, hint: nil, disabledReason: nil
        )
        fileprivate static let unknown = InputCapabilityProjection(
            visible: false, editable: true, outbound: .nativePart, hint: .firstAttachOnce, disabledReason: nil
        )
        fileprivate static func disabled(_ reason: InputDisabledReason) -> InputCapabilityProjection {
            .init(visible: false, editable: false, outbound: .placeholder, hint: nil, disabledReason: reason)
        }
    }

    /// Three-key projection. Priority: hard blocks (kill switch [unavailable only], family not implemented here, transport_not_* of an unavailable verdict) > Relay user override > negative cache > verdict.
    /// Official connections ignore overrides; `verdict == nil` (missing key) and unknown both project to "not shown, entry open, first-attach hint".
    static func inputCapabilityProjection(
        verdict: InputVerdict?,
        endImplements: Bool,
        override: InputOverride?,
        negativeCacheHit: Bool,
        connection: InputConnection
    ) -> InputCapabilityProjection {
        // Hard-block tier: kill switch (unavailable only), not implemented here, transport_not_* of an unavailable verdict;
        // placed before the Relay override and the negative cache, the same rule as Web / Android / desktop.
        if verdict?.state == .unavailable, verdict?.reasonCode == "provider_kill_switch" {
            return .disabled(.killSwitch)
        }
        guard endImplements else { return .disabled(.wireNotImplemented) }
        if verdict?.state == .unavailable, isTransportNotImplemented(verdict?.reasonCode) {
            return .disabled(.wireNotImplemented)
        }
        if connection == .relay, let override {
            switch override {
            case .add: return .available
            case .remove: return .disabled(.userRemoved)
            }
        }
        if negativeCacheHit { return .disabled(.rejectedRecently) }
        guard let verdict else { return .unknown }
        switch verdict.state {
        case .autoAvailable:
            return .available
        case .unavailable:
            return .disabled(inputDisabledReason(reasonCode: verdict.reasonCode))
        case .managedOnly, .customOnly:
            // Managed-only / reachable only through custom fragments: this connection has no conclusion to send automatically, so it counts as the model lacking the capability, as on Web / Android.
            return .disabled(.modelAbsent)
        case .unknown:
            return .unknown
        }
    }

    /// Reason mapping of unavailable: transport_not_* -> not implemented here; everything else is model_absent.
    private static func inputDisabledReason(reasonCode: String?) -> InputDisabledReason {
        if isTransportNotImplemented(reasonCode) { return .wireNotImplemented }
        if reasonCode == "provider_kill_switch" { return .killSwitch }
        return .modelAbsent
    }

    private static func isTransportNotImplemented(_ reasonCode: String?) -> Bool {
        reasonCode == "transport_not_supported" || reasonCode == "transport_not_implemented"
    }
}

// MARK: - Attachment import entry

extension CapabilityEvidenceFacade {
    /// The entry result shared by album / file / video import and the Relay native file override.
    /// image / nativeFile / video look only at the editable flag of the three-key projection; textFileInline does not belong to file_input.
    struct AttachmentImportEntry: Equatable, Sendable {
        let image: Bool
        let video: Bool
        let nativeFile: Bool
        let textFileInline: Bool

        static let closed = AttachmentImportEntry(image: false, video: false, nativeFile: false, textFileInline: false)
    }

    /// Entry function: the three keys take the editable flag of the projection (a missing projection means closed); textFileInline reads metadata for official / subscription,
    /// and for Relay reads the first-send protocol envelope (true when there is no envelope). The only place in the facade that reads the legacy attachment fields.
    /// The input envelope of the Relay first-send protocol is injected by the caller (the facade does no I/O) and is evaluated by the first-send protocol only for the Relay form.
    static func attachmentImportEntry(
        provider: Provider,
        model: AIModel,
        projection: CapabilityEvidenceProjection,
        relayInputEnvelope: (RelayTransport) -> RelayRuntimeSupport.AttachmentSupport?
    ) -> AttachmentImportEntry {
        func editable(_ key: String) -> Bool { projection.inputProjection(for: key)?.editable ?? false }
        let textFileInline: Bool
        switch ProviderForm.of(provider) {
        case .relay:
            textFileInline = relayInputEnvelope(
                RelayFirstSendTransport.current(provider: provider, model: model)
            )?.textFileInline ?? true
        case .official, .subscription:
            textFileInline = provider.kind.attachmentSupport.textFileInline
        }
        return AttachmentImportEntry(
            image: editable(visionInputKey),
            video: editable(videoInputKey),
            nativeFile: editable(fileInputKey),
            textFileInline: textFileInline
        )
    }
}