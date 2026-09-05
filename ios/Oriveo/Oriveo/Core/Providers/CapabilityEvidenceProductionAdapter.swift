import CryptoKit
import Foundation

enum ProviderCapabilityIdentityStore {
    struct Identity: Codable, Equatable, Sendable {
        let connectionGeneration: String
        let credentialEpoch: String
    }

    private static let defaultsKey = "provider_capability_identity.v1"
    private static let lock = NSLock()

    static func identity(providerID: UUID, partitionID: String) -> Identity {
        lock.lock(); defer { lock.unlock() }
        var values = load()
        let key = key(providerID: providerID, partitionID: partitionID)
        if let existing = values[key] { return existing }
        let created = Identity(connectionGeneration: token(), credentialEpoch: token())
        values[key] = created
        save(values)
        return created
    }

    static func advanceConnectionGeneration(providerID: UUID, partitionID: String) {
        mutate(providerID: providerID, partitionID: partitionID) { current in
            Identity(connectionGeneration: token(), credentialEpoch: current.credentialEpoch)
        }
    }

    static func advanceCredentialEpoch(providerID: UUID, partitionID: String) {
        mutate(providerID: providerID, partitionID: partitionID) { current in
            Identity(connectionGeneration: current.connectionGeneration, credentialEpoch: token())
        }
    }

    static func tombstone(providerID: UUID, partitionID: String) {
        mutate(providerID: providerID, partitionID: partitionID) { _ in
            Identity(connectionGeneration: token(), credentialEpoch: token())
        }
    }

    #if DEBUG
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    #endif

    private static func mutate(providerID: UUID, partitionID: String, _ transform: (Identity) -> Identity) {
        lock.lock(); defer { lock.unlock() }
        var values = load()
        let storageKey = key(providerID: providerID, partitionID: partitionID)
        let current = values[storageKey] ?? Identity(connectionGeneration: token(), credentialEpoch: token())
        values[storageKey] = transform(current)
        save(values)
    }

    private static func key(providerID: UUID, partitionID: String) -> String { "\(partitionID)|\(providerID.uuidString)" }
    private static func token() -> String { UUID().uuidString.lowercased() }
    private static func load() -> [String: Identity] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([String: Identity].self, from: data) else { return [:] }
        return values
    }
    private static func save(_ values: [String: Identity]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: defaultsKey)
    }
}

struct CapabilityEvidenceRequestIdentity: Sendable, Equatable {
    let query: CapabilityEvidenceFacade.Query
    /// Server capability runtime revision actually selected for this request. It is deliberately
    /// separate from metadata/generation revisions and from preference LWW mutation revisions.
    let runtimeRevision: String?

    init(query: CapabilityEvidenceFacade.Query, runtimeRevision: String? = nil) {
        self.query = query
        self.runtimeRevision = runtimeRevision
    }

    static func make(
        provider: Provider,
        model: AIModel,
        partitionID: String,
        hasExplicitValue: Bool,
        effectiveTransport: String? = nil,
        metadataETag: String? = MetadataClient.shared.syncMetadataETag()
    ) -> Self {
        let identity = ProviderCapabilityIdentityStore.identity(providerID: provider.id, partitionID: partitionID)
        let metadataInput = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: provider.kind
        )
        let transport = effectiveTransport
            ?? (provider.kind == .relay ? nil : metadataInput.resolved?.transport)
            ?? ""
        let profile: GenerationProfileRef?
        if provider.kind == .relay,
           CapabilityEvidenceFacade.isConcreteTransport(transport),
           let relayTransport = RelayTransport(rawValue: transport) {
            profile = LocalEngineGenerationProfiles.profile(
                for: provider.relayRequested?.engineProfile, transport: relayTransport
            )
        } else {
            profile = metadataInput.resolved?.generationProfile
        }
        let metadataRevision = metadataETag ?? metadataInput.metadataRevision
        let runtimeRevision = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        ).runtime?.revision
        return .init(query: .init(
            partitionID: partitionID,
            connectionInstanceID: provider.id.uuidString,
            connectionGeneration: identity.connectionGeneration,
            credentialEpoch: identity.credentialEpoch,
            providerKind: provider.kind.rawValue,
            modelID: model.id,
            canonicalModelID: metadataInput.resolved?.canonicalModelId ?? model.canonicalModelId,
            effectiveTransport: transport,
            endpointFingerprint: nil,
            metadataRevision: metadataRevision,
            generationRevision: profile?.revision ?? metadataRevision,
            now: Int64(Date().timeIntervalSince1970 * 1_000),
            hasExplicitValue: hasExplicitValue
        ), runtimeRevision: runtimeRevision)
    }

    func resolvingFinalDispatch(
        _ url: URL?,
        effectiveTransport: String,
        metadataRevision: String?,
        generationRevision: String?
    ) -> Self? {
        guard let fingerprint = CapabilityEvidenceProductionAdapter.endpointFingerprint(url),
              CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport) else { return nil }
        return .init(query: .init(
            partitionID: query.partitionID, connectionInstanceID: query.connectionInstanceID,
            connectionGeneration: query.connectionGeneration, credentialEpoch: query.credentialEpoch,
            providerKind: query.providerKind, modelID: query.modelID, canonicalModelID: query.canonicalModelID,
            effectiveTransport: effectiveTransport, endpointFingerprint: fingerprint,
            metadataRevision: metadataRevision, generationRevision: generationRevision,
            now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: query.hasExplicitValue
        ), runtimeRevision: runtimeRevision)
    }

    func resolvingRuntimeRevision(_ revision: String) -> Self? {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .init(query: query, runtimeRevision: trimmed)
    }

    /// Narrows the identity once the production builder has settled on a transport, which happens
    /// before a URL exists. A non-concrete transport returns `nil` rather than recording evidence
    /// under a placeholder that would later match the wrong dispatch.
    func resolvingCapabilityRuntimeTransport(_ transport: String) -> Self? {
        let trimmed = transport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CapabilityEvidenceFacade.isConcreteTransport(trimmed) else { return nil }
        return .init(query: .init(
            partitionID: query.partitionID,
            connectionInstanceID: query.connectionInstanceID,
            connectionGeneration: query.connectionGeneration,
            credentialEpoch: query.credentialEpoch,
            providerKind: query.providerKind,
            modelID: query.modelID,
            canonicalModelID: query.canonicalModelID,
            effectiveTransport: trimmed,
            endpointFingerprint: query.endpointFingerprint,
            metadataRevision: query.metadataRevision,
            generationRevision: query.generationRevision,
            now: query.now,
            hasExplicitValue: query.hasExplicitValue
        ), runtimeRevision: runtimeRevision)
    }

    func resolvingFinalEndpoint(_ url: URL?) -> Self? {
        resolvingFinalDispatch(
            url,
            effectiveTransport: query.effectiveTransport,
            metadataRevision: query.metadataRevision,
            generationRevision: query.generationRevision
        )
    }
}

struct GenerationParameterEvidenceProjection: Sendable, Equatable {
    let profile: GenerationProfileRef?
    let resolutions: [String: CapabilityEvidenceFacade.Resolution]
    let hasCompleteConnectionIdentity: Bool

    func resolution(for parameterID: String) -> CapabilityEvidenceFacade.Resolution? {
        resolutions[UnsupportedParamClassifier.normalize(parameterID)]
    }

    func permitsOutbound(_ parameterID: String) -> Bool {
        let normalized = UnsupportedParamClassifier.normalize(parameterID)
        guard hasCompleteConnectionIdentity,
              let parameter = profile?.parameters?.first(where: {
                  UnsupportedParamClassifier.normalize($0.id ?? "") == normalized
              }),
              let wire = profile?.wire?[normalized],
              !wire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let resolution = resolution(for: parameterID),
              GenerationParameterSupportPresentation.entry(for:
                  GenerationParameterSupportPresentation.effectiveSupport(
                      declared: parameter.support, resolution: resolution
                  )
              ).control == .editable else { return false }
        let policy = resolution.requestPolicy
        return policy == .allow || policy == .allowExplicitUnverified
    }

    func isVisible(
        _ parameter: GenerationParameterRef,
        scope: GenerationParameterEntryScope
    ) -> Bool {
        guard let id = parameter.id else { return false }
        if scope == .connectionDefaults { return true }
        guard hasCompleteConnectionIdentity,
              profile?.wire?[id]?.isEmpty == false,
              let resolution = resolution(for: id) else { return false }
        return GenerationParameterSupportPresentation.entry(for:
            GenerationParameterSupportPresentation.effectiveSupport(
                declared: parameter.support, resolution: resolution
            )
        ).control == .editable
    }

    func isEditable(
        _ parameter: GenerationParameterRef,
        scope: GenerationParameterEntryScope = .connectionDefaults
    ) -> Bool {
        guard let id = parameter.id,
              hasCompleteConnectionIdentity,
              profile?.wire?[id]?.isEmpty == false,
              let resolution = resolution(for: id) else { return false }
        return GenerationParameterSupportPresentation.entry(for:
            GenerationParameterSupportPresentation.effectiveSupport(
                declared: parameter.support, resolution: resolution
            )
        ).control == .editable
    }
}

enum CapabilityEvidenceRequestContext {
    @TaskLocal static var current: CapabilityEvidenceRequestIdentity?

    static func scope(for request: URLRequest) -> CapabilityEvidenceRequestIdentity? {
        current?.resolvingFinalEndpoint(request.url)
    }

    static func scope(
        for request: URLRequest,
        effectiveTransport: String,
        metadataRevision: String?,
        generationRevision: String?
    ) -> CapabilityEvidenceRequestIdentity? {
        current?.resolvingFinalDispatch(
            request.url,
            effectiveTransport: effectiveTransport,
            metadataRevision: metadataRevision,
            generationRevision: generationRevision
        )
    }

    static func generationScope(
        for request: URLRequest,
        effectiveTransport: String,
        relayEngineProfile: String?,
        relayDeclaredProfile: GenerationProfileRef?
    ) -> CapabilityEvidenceRequestIdentity? {
        guard let current,
              let providerKind = ProviderKind(rawValue: current.query.providerKind) else { return nil }

        if providerKind == .relay {
            guard let transport = RelayTransport(rawValue: effectiveTransport) else { return nil }
            let local = LocalEngineGenerationProfiles.profile(
                for: relayEngineProfile, transport: transport
            )
            let profile = CapabilityEvidenceProductionAdapter.mergeRelayDeclaration(
                local, relayDeclaredProfile
            )
            let metadataRevision = MetadataClient.shared.syncMetadataETag()
            return current.resolvingFinalDispatch(
                request.url,
                effectiveTransport: effectiveTransport,
                metadataRevision: metadataRevision,
                generationRevision: profile?.revision ?? metadataRevision
            )
        }

        let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: current.query.modelID, providerKind: providerKind
        )
        return current.resolvingFinalDispatch(
            request.url,
            effectiveTransport: effectiveTransport,
            metadataRevision: input.metadataRevision,
            generationRevision: input.resolved?.generationProfile?.revision ?? input.metadataRevision
        )
    }
}

enum CapabilityEvidenceProductionAdapter {
    static func endpointFingerprint(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return nil }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path.isEmpty ? "/" : components.path
        let normalized = "\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "ep_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func relayGenerationCandidates(profile: GenerationProfileRef, query: CapabilityEvidenceFacade.Query) -> [CapabilityEvidenceFacade.Candidate] {
        var normalized = profile
        normalized.parameters = profile.parameters?.map { parameter in
            var copy = parameter
            if query.providerKind == ProviderKind.relay.rawValue {
                copy.source = "relay_declared"
                if copy.support != "unsupported", copy.support != "fixed",
                   copy.support != "mode_dependent", copy.support != "future_supported" {
                    copy.support = "accepted_unverified"
                }
            }
            return copy
        }
        return CapabilityEvidenceFacade.generationParameterCandidates(from: normalized, query: query)
    }

    static func generationProjection(
        provider: Provider,
        model persistedModel: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        explicitParameterIDs: Set<String> = []
    ) -> GenerationParameterEvidenceProjection {
        let profile: GenerationProfileRef?
        let baseQuery: CapabilityEvidenceFacade.Query?
        var modelCandidates: [CapabilityEvidenceFacade.Candidate] = []
        var ownedKeys: Set<String> = []
        var malformed = false

        if provider.kind == .relay {
            let schemaTransport = identity?.query.effectiveTransport
                ?? provider.relayRequested?.transport.rawValue
                ?? ""
            guard CapabilityEvidenceFacade.isConcreteTransport(schemaTransport),
                  let relayTransport = RelayTransport(rawValue: schemaTransport) else {
                return unknownGenerationProjection(profile: nil, hasCompleteConnectionIdentity: false)
            }
            let localProfile = LocalEngineGenerationProfiles.profile(
                for: provider.relayRequested?.engineProfile, transport: relayTransport
            )
            profile = mergeRelayDeclaration(localProfile, persistedModel.generationProfile)
            guard let identity,
                  trimmedNonEmpty(identity.query.endpointFingerprint) != nil,
                  CapabilityEvidenceFacade.isConcreteTransport(identity.query.effectiveTransport) else {
                return unknownGenerationProjection(profile: profile, hasCompleteConnectionIdentity: false)
            }
            baseQuery = identity.query
        } else {
            let metadataInput = MetadataClient.shared.syncCapabilityEvidenceModelInput(
                modelID: persistedModel.id, providerKind: provider.kind
            )
            profile = metadataInput.resolved?.generationProfile
            modelCandidates = metadataInput.resolved?.capabilityEvidenceCandidates ?? []
            ownedKeys = metadataInput.resolved?.capabilityEvidenceOwnedKeys ?? []
            malformed = metadataInput.resolved?.capabilityEvidenceViewMalformed ?? false
            guard profile?.revision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || metadataInput.metadataRevision != nil else {
                return unknownGenerationProjection(profile: profile, hasCompleteConnectionIdentity: true)
            }
            let transport = metadataInput.resolved?.transport ?? ""
            guard CapabilityEvidenceFacade.isConcreteTransport(transport) else {
                return unknownGenerationProjection(profile: profile, hasCompleteConnectionIdentity: true)
            }
            baseQuery = .init(
                partitionID: "", connectionInstanceID: "", connectionGeneration: "", credentialEpoch: "",
                providerKind: provider.kind.rawValue, modelID: persistedModel.id,
                canonicalModelID: metadataInput.resolved?.canonicalModelId, effectiveTransport: transport,
                metadataRevision: metadataInput.metadataRevision,
                generationRevision: profile?.revision ?? metadataInput.metadataRevision,
                now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: false
            )
        }

        guard let profile, let baseQuery else {
            return GenerationParameterEvidenceProjection(
                profile: profile, resolutions: [:],
                hasCompleteConnectionIdentity: provider.kind != .relay
            )
        }
        let parameterIDs = Set(profile.parameters?.compactMap { trimmedNonEmpty($0.id) }.map(UnsupportedParamClassifier.normalize) ?? [])
        var candidates = modelCandidates
        if provider.kind == .relay {
            candidates.append(contentsOf: relayGenerationCandidates(profile: profile, query: baseQuery))
        } else if !malformed {
            let legacy = CapabilityEvidenceFacade.generationParameterCandidates(from: profile, query: baseQuery)
            candidates.append(contentsOf: legacy.filter { !ownedKeys.contains($0.key) })
        }

        var resolutions: [String: CapabilityEvidenceFacade.Resolution] = [:]
        for parameterID in parameterIDs {
            let query = query(baseQuery, hasExplicitValue: explicitParameterIDs.contains(parameterID))
            resolutions[parameterID] = CapabilityEvidenceFacade.resolve(
                key: "generation_parameter/\(parameterID)", query: query, candidates: candidates
            )
        }
        return GenerationParameterEvidenceProjection(
            profile: profile, resolutions: resolutions,
            hasCompleteConnectionIdentity: provider.kind != .relay || isCompleteConnectionQuery(baseQuery)
        )
    }

    static func mergeRelayDeclaration(
        _ local: GenerationProfileRef?,
        _ declared: GenerationProfileRef?
    ) -> GenerationProfileRef? {
        guard var local else { return declared }
        guard let declared,
              declared.transport == nil || declared.transport == local.transport else { return local }
        let declarations: [String: GenerationParameterRef] = Dictionary(
            uniqueKeysWithValues: (declared.parameters ?? []).compactMap { parameter in
            guard let id = trimmedNonEmpty(parameter.id) else { return nil }
            return (UnsupportedParamClassifier.normalize(id), parameter)
            }
        )
        local.parameters = local.parameters?.map { parameter in
            guard let id = trimmedNonEmpty(parameter.id),
                  let declaration = declarations[UnsupportedParamClassifier.normalize(id)] else { return parameter }
            var merged = parameter
            merged.support = declaration.support
            merged.source = declaration.source
            if let group = declaration.group { merged.group = group }
            return merged
        }
        // A declared profile that carries a wire map owns the writable paths for this
        // connection. In particular, an explicitly missing key must not inherit a
        // local template path and become editable/outbound by accident.
        if let declaredWire = declared.wire { local.wire = declaredWire }
        if let revision = declared.revision { local.revision = revision }
        return local
    }

    static func generationRequestProjection(
        identity: CapabilityEvidenceRequestIdentity?,
        relayEngineProfile: String?,
        relayDeclaredProfile: GenerationProfileRef? = nil,
        explicitParameterIDs: Set<String>
    ) -> GenerationParameterEvidenceProjection {
        guard let identity,
              let providerKind = ProviderKind(rawValue: identity.query.providerKind),
              trimmedNonEmpty(identity.query.endpointFingerprint) != nil,
              CapabilityEvidenceFacade.isConcreteTransport(identity.query.effectiveTransport) else {
            return unknownGenerationProjection(profile: nil, hasCompleteConnectionIdentity: false)
        }

        let query = identity.query
        let profile: GenerationProfileRef?
        let candidates: [CapabilityEvidenceFacade.Candidate]
        let ownedKeys: Set<String>
        let malformed: Bool

        if providerKind == .relay {
            guard let transport = RelayTransport(rawValue: query.effectiveTransport) else {
                return unknownGenerationProjection(profile: nil, hasCompleteConnectionIdentity: false)
            }
            profile = mergeRelayDeclaration(
                LocalEngineGenerationProfiles.profile(for: relayEngineProfile, transport: transport),
                relayDeclaredProfile
            )
            guard let profile,
                  (profile.revision ?? query.metadataRevision) == query.generationRevision else {
                return unknownGenerationProjection(profile: profile, hasCompleteConnectionIdentity: false)
            }
            candidates = relayGenerationCandidates(profile: profile, query: query)
            ownedKeys = []
            malformed = false
        } else {
            let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
                modelID: query.modelID, providerKind: providerKind
            )
            guard let resolved = input.resolved else {
                return unknownGenerationProjection(profile: nil, hasCompleteConnectionIdentity: true)
            }
            profile = resolved.generationProfile
            guard query.metadataRevision == input.metadataRevision,
                  query.generationRevision == (profile?.revision ?? query.metadataRevision) else {
                return unknownGenerationProjection(profile: profile, hasCompleteConnectionIdentity: true)
            }
            candidates = resolved.capabilityEvidenceCandidates
            ownedKeys = resolved.capabilityEvidenceOwnedKeys
            malformed = resolved.capabilityEvidenceViewMalformed
        }

        guard let profile else {
            return unknownGenerationProjection(
                profile: nil, hasCompleteConnectionIdentity: providerKind != .relay
            )
        }
        let parameterIDs = Set(
            profile.parameters?.compactMap { trimmedNonEmpty($0.id) }
                .map(UnsupportedParamClassifier.normalize) ?? []
        )
        var allCandidates = candidates
        if providerKind != .relay, !malformed {
            let legacy = CapabilityEvidenceFacade.generationParameterCandidates(from: profile, query: query)
            allCandidates.append(contentsOf: legacy.filter { !ownedKeys.contains($0.key) })
        }

        let resolutions = Dictionary(uniqueKeysWithValues: parameterIDs.map { parameterID in
            let parameterQuery = self.query(
                query, hasExplicitValue: explicitParameterIDs.contains(parameterID)
            )
            return (
                parameterID,
                CapabilityEvidenceFacade.resolve(
                    key: "generation_parameter/\(parameterID)",
                    query: parameterQuery,
                    candidates: allCandidates
                )
            )
        })
        return GenerationParameterEvidenceProjection(
            profile: profile,
            resolutions: resolutions,
            hasCompleteConnectionIdentity: providerKind != .relay || isCompleteConnectionQuery(query)
        )
    }

    private static func unknownGenerationProjection(
        profile: GenerationProfileRef?,
        hasCompleteConnectionIdentity: Bool
    ) -> GenerationParameterEvidenceProjection {
        let ids = profile?.parameters?.compactMap { trimmedNonEmpty($0.id) }.map(UnsupportedParamClassifier.normalize) ?? []
        let resolutions: [String: CapabilityEvidenceFacade.Resolution] = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, CapabilityEvidenceFacade.Resolution(
                key: "generation_parameter/\(id)", support: .unknown, source: .none, grade: .none,
                requestPolicy: .omitUnknown, reasonCode: .missingEvidence, policyEvidence: nil
            ))
        })
        return GenerationParameterEvidenceProjection(
            profile: profile, resolutions: resolutions,
            hasCompleteConnectionIdentity: hasCompleteConnectionIdentity
        )
    }

    static func isCompleteConnectionQuery(_ query: CapabilityEvidenceFacade.Query) -> Bool {
        trimmedNonEmpty(query.partitionID) != nil
            && trimmedNonEmpty(query.connectionInstanceID) != nil
            && trimmedNonEmpty(query.connectionGeneration) != nil
            && trimmedNonEmpty(query.credentialEpoch) != nil
            && trimmedNonEmpty(query.endpointFingerprint) != nil
            && CapabilityEvidenceFacade.isConcreteTransport(query.effectiveTransport)
    }

    static func query(
        _ source: CapabilityEvidenceFacade.Query, hasExplicitValue: Bool
    ) -> CapabilityEvidenceFacade.Query {
        .init(
            partitionID: source.partitionID, connectionInstanceID: source.connectionInstanceID,
            connectionGeneration: source.connectionGeneration, credentialEpoch: source.credentialEpoch,
            providerKind: source.providerKind, modelID: source.modelID, canonicalModelID: source.canonicalModelID,
            effectiveTransport: source.effectiveTransport, endpointFingerprint: source.endpointFingerprint,
            metadataRevision: source.metadataRevision, generationRevision: source.generationRevision,
            now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: hasExplicitValue
        )
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func runtimeRejectedCandidate(
        parameterID: String,
        identity: CapabilityEvidenceRequestIdentity,
        observedAt: Date = Date()
    ) -> CapabilityEvidenceFacade.Candidate? {
        runtimeRejectedCandidate(
            key: "generation_parameter/\(UnsupportedParamClassifier.normalize(parameterID))",
            identity: identity, observedAt: observedAt
        )
    }

    static func runtimeRejectedCandidate(
        capabilityKey: String,
        identity: CapabilityEvidenceRequestIdentity,
        observedAt: Date = Date()
    ) -> CapabilityEvidenceFacade.Candidate? {
        runtimeRejectedCandidate(key: capabilityKey, identity: identity, observedAt: observedAt)
    }

    private static func runtimeRejectedCandidate(
        key: String,
        identity: CapabilityEvidenceRequestIdentity,
        observedAt: Date
    ) -> CapabilityEvidenceFacade.Candidate? {
        let query = identity.query
        guard query.endpointFingerprint != nil, !query.effectiveTransport.isEmpty else { return nil }
        let observed = Int64(observedAt.timeIntervalSince1970 * 1_000)
        return .init(
            key: key,
            support: .unknown, source: .runtimeObservation, grade: .observed,
            scope: .exactRequest, policy: .omitRuntimeRejected,
            partitionID: query.partitionID, providerKind: query.providerKind, modelID: query.effectiveModelID,
            transport: query.effectiveTransport, connectionInstanceID: query.connectionInstanceID,
            connectionGeneration: query.connectionGeneration, credentialEpoch: query.credentialEpoch,
            endpointFingerprint: query.endpointFingerprint, metadataRevision: query.metadataRevision,
            generationRevision: query.generationRevision, observedAt: observed,
            expiresAt: observed + 24 * 60 * 60 * 1_000
        )
    }
}
