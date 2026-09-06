import Foundation
import Testing
@testable import Oriveo

private final class CapabilityDispatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

@Suite("capability evidence facade contract", .serialized)
struct CapabilityEvidenceContractTests {
    @Test("Golden Cases Match Contract")
    func goldenCasesMatchContract() throws {
        let contract = try Self.loadContract()
        #expect(contract.version == 1)
        #expect(contract.cases.count >= 18)
        let caseIDs = Set(contract.cases.map(\.caseId))
        for required in [
            "official.explicit.no_evidence_allows",
            "official.explicit.legacy_unverified_allows",
            "official.explicit.official_unsupported_still_omits",
            "official.explicit.runtime_rejected_still_omits",
            "official.explicit.conflict_still_omits",
            "relay.explicit.accepted_unverified",
        ] {
            #expect(caseIDs.contains(required))
        }

        for item in contract.cases {
            let result = CapabilityEvidenceFacade.resolve(
                key: item.expect.key,
                query: item.query.asFacadeQuery(),
                candidates: item.candidates.map { $0.asFacadeCandidate() }
            )
            #expect(result.key == item.expect.key, "\(item.caseId): key")
            #expect(result.support.rawValue == item.expect.support, "\(item.caseId): support")
            #expect(result.source.rawValue == item.expect.source, "\(item.caseId): source")
            #expect(result.grade.rawValue == item.expect.grade, "\(item.caseId): grade")
            #expect(result.requestPolicy.rawValue == item.expect.requestPolicy, "\(item.caseId): requestPolicy")
            #expect(result.reasonCode.rawValue == item.expect.reasonCode, "\(item.caseId): reasonCode")
            #expect(result.policyEvidence?.source.rawValue == item.expect.policyEvidence?.source, "\(item.caseId): policy evidence source")
            #expect(result.policyEvidence?.grade.rawValue == item.expect.policyEvidence?.grade, "\(item.caseId): policy evidence grade")
        }
    }

    @Test("Missing Partition Cannot Match Connection Evidence")
    func missingPartitionCannotMatchConnectionEvidence() {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "relay-1", connectionGeneration: "cg3",
            credentialEpoch: "ce8", providerKind: "relay", modelID: "local-model",
            effectiveTransport: "openai_chat_completions", endpointFingerprint: "ep_abc",
            metadataRevision: "local-7", now: 1_000, hasExplicitValue: true
        )
        let unpartitioned = CapabilityEvidenceFacade.Candidate(
            key: "generation_parameter/temperature", support: .supported, source: .relayDeclaration,
            grade: .declared, scope: .connectionModelTransport, providerKind: "relay",
            modelID: "local-model", transport: "openai_chat_completions",
            connectionInstanceID: "relay-1", connectionGeneration: "cg3", credentialEpoch: "ce8",
            endpointFingerprint: "ep_abc", metadataRevision: "local-7"
        )
        let result = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature", query: query, candidates: [unpartitioned]
        )
        #expect(result.support == .unknown)
        #expect(result.requestPolicy == .omitUnknown)
        #expect(result.reasonCode == .missingEvidence)
    }

    @Test("Missing Endpoint Cannot Match Connection Evidence")
    func missingEndpointCannotMatchConnectionEvidence() {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "relay-1", connectionGeneration: "cg3",
            credentialEpoch: "ce8", providerKind: "relay", modelID: "local-model",
            effectiveTransport: "openai_chat_completions", endpointFingerprint: nil,
            metadataRevision: "local-7", now: 1_000, hasExplicitValue: true
        )
        let candidate = CapabilityEvidenceFacade.Candidate(
            key: "tool_call", support: .supported, source: .relayVerification,
            grade: .effectVerified, scope: .connectionModelTransport, partitionID: "u1",
            providerKind: "relay", modelID: "local-model", transport: "openai_chat_completions",
            connectionInstanceID: "relay-1", connectionGeneration: "cg3", credentialEpoch: "ce8",
            endpointFingerprint: nil, metadataRevision: "local-7"
        )
        let result = CapabilityEvidenceFacade.resolve(key: "tool_call", query: query, candidates: [candidate])
        #expect(result.support == .unknown)
        #expect(result.requestPolicy == .omitUnknown)
    }

    @Test("Empty Local Identity Cannot Match Connection Evidence")
    func emptyLocalIdentityCannotMatchConnectionEvidence() {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "", connectionInstanceID: "", connectionGeneration: "", credentialEpoch: "",
            providerKind: "relay", modelID: "local-model", effectiveTransport: "openai_chat_completions",
            endpointFingerprint: "ep_final", metadataRevision: "local-7", now: 1_000, hasExplicitValue: true
        )
        let candidate = CapabilityEvidenceFacade.Candidate(
            key: "tool_call", support: .supported, source: .relayVerification,
            grade: .effectVerified, scope: .connectionModelTransport, partitionID: "",
            providerKind: "relay", modelID: "local-model", transport: "openai_chat_completions",
            connectionInstanceID: "", connectionGeneration: "", credentialEpoch: "",
            endpointFingerprint: "ep_final", metadataRevision: "local-7"
        )
        let result = CapabilityEvidenceFacade.resolve(key: "tool_call", query: query, candidates: [candidate])
        #expect(result.support == .unknown)
        #expect(result.requestPolicy == .omitUnknown)
    }

    @Test("Unknown Transport Cannot Match Evidence")
    func unknownTransportCannotMatchEvidence() {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "p1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "openAI", modelID: "gpt-5", effectiveTransport: "unknown",
            metadataRevision: "etag-1", now: 1_000, hasExplicitValue: true
        )
        let candidate = CapabilityEvidenceFacade.Candidate(
            key: "generation_parameter/temperature", support: .supported, source: .serverTyped,
            grade: .machineVerified, scope: .providerModelTransport, providerKind: "openAI",
            modelID: "gpt-5", transport: "unknown", metadataRevision: "etag-1"
        )
        let result = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature", query: query, candidates: [candidate]
        )
        #expect(result.support == .unknown)
        #expect(result.requestPolicy == .omitUnknown)
    }

    @Test("Metadata Namespace Presence Is Fail Closed")
    func metadataNamespacePresenceIsFailClosed() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.evidenceMetadataJSON(view: nil))
        var resolved = try #require(await MetadataClient.shared.resolveCatalogModel(
            modelID: "gpt-5", providerKind: .openAI
        ))
        #expect(!resolved.capabilityEvidenceViewPresent)
        #expect(!resolved.capabilityEvidenceViewMalformed)

        try await MetadataClient.shared.loadForTesting(json: Self.evidenceMetadataJSON(view: "null"))
        resolved = try #require(await MetadataClient.shared.resolveCatalogModel(
            modelID: "gpt-5", providerKind: .openAI
        ))
        #expect(resolved.capabilityEvidenceViewPresent)
        #expect(resolved.capabilityEvidenceViewMalformed)

        try await MetadataClient.shared.loadForTesting(json: Self.evidenceMetadataJSON(
            view: #"{"schema":"capability-evidence-view/v1","candidates":[]}"#
        ))
        resolved = try #require(await MetadataClient.shared.resolveCatalogModel(
            modelID: "gpt-5", providerKind: .openAI
        ))
        #expect(resolved.capabilityEvidenceViewPresent)
        #expect(!resolved.capabilityEvidenceViewMalformed)
        #expect(resolved.capabilityEvidenceCandidates.isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Malformed Candidate Owns Safe Key And Withdrawal Clears Projection")
    func malformedCandidateOwnsSafeKeyAndWithdrawalClearsProjection() async throws {
        await MetadataClient.shared.resetForTesting()
        let malformedCandidate = #"{"schema":"capability-evidence-view/v1","candidates":[{"key":"tool_call","support":"supported","source":"private_source","grade":"machine_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt-5","transport":"openai_responses"},{"key":"private/provenance","source":"server_typed"}]}"#
        try await MetadataClient.shared.loadForTesting(json: Self.evidenceMetadataJSON(view: malformedCandidate))
        let persisted = TestFactories.makeModel(id: "gpt-5")
        var current = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .openAI)
        #expect(current.capabilityEvidenceViewPresent)
        #expect(!current.capabilityEvidenceViewMalformed)
        #expect(current.capabilityEvidenceOwnedKeys == ["tool_call"])
        #expect(current.capabilityEvidenceCandidates.isEmpty)

        try await MetadataClient.shared.loadForTesting(json: Self.evidenceMetadataJSON(view: nil))
        current = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(current, providerKind: .openAI)
        #expect(!current.capabilityEvidenceViewPresent)
        #expect(current.capabilityEvidenceOwnedKeys.isEmpty)
        #expect(current.capabilityEvidenceCandidates.isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Normalized Production Generation Profile Feeds Facade")
    func normalizedProductionGenerationProfileFeedsFacade() async throws {
        let shapes = try Self.loadProductionShapes()
        let rawProfile = try #require(shapes.sources.generationProfile?.payload)
        let serverModel = try #require(shapes.sources.serverMetadata?.payload.providers["openAI"]?.models["gpt-5.4"])

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: Self.metadataJSON(
            serverModel: serverModel,
            rawProfile: rawProfile
        ))
        let resolved = await MetadataClient.shared.resolveCatalogModel(modelID: "gpt-5.4", providerKind: .openAI)
        let normalized = try #require(resolved?.generationProfile)

        #expect(normalized.transport == "openai_responses")
        #expect(normalized.wire?["temperature"] == "temperature")
        #expect(normalized.parameters?.map(\.id) == ["temperature", "top_p", "min_p"])

        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "p1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "openAI", modelID: "gpt-5.4", canonicalModelID: "gpt-5.4",
            effectiveTransport: "openai_responses", metadataRevision: "9001", generationRevision: "fixture-gen",
            now: 1_000, hasExplicitValue: true
        )
        let candidates = CapabilityEvidenceFacade.generationParameterCandidates(from: normalized, query: query)
        let temperature = CapabilityEvidenceFacade.resolve(key: "generation_parameter/temperature", query: query, candidates: candidates)
        #expect(temperature.support == .supported)
        #expect(temperature.source == .serverProfile)
        #expect(temperature.grade == .effectVerified)
        #expect(temperature.requestPolicy == .allow)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Production Profile Feeds Facade Without Inventing Support")
    func relayProductionProfileFeedsFacadeWithoutInventingSupport() throws {
        let profile = try #require(LocalEngineGenerationProfiles.profile(
            for: "vllm",
            transport: .openaiChatCompletions
        ))
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "relay-1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "private-model", effectiveTransport: "openai_chat_completions",
            endpointFingerprint: "ep_final", metadataRevision: "m1", generationRevision: "m1",
            now: 1_000, hasExplicitValue: true
        )
        let candidates = CapabilityEvidenceProductionAdapter.relayGenerationCandidates(profile: profile, query: query)
        let result = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature", query: query, candidates: candidates
        )
        #expect(result.support == .unknown)
        #expect(result.source == .relayDeclaration)
        #expect(result.grade == .acceptedUnverified)
        #expect(result.requestPolicy == .allowExplicitUnverified)
    }

    @Test("Runtime Producer Candidate Overlays Request Policy Only")
    func runtimeProducerCandidateOverlaysRequestPolicyOnly() throws {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "p1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "openAI", modelID: "gpt-5", effectiveTransport: "openai_responses",
            endpointFingerprint: "ep_final", metadataRevision: "m1", generationRevision: "g1",
            now: 1_000, hasExplicitValue: true
        )
        let identity = CapabilityEvidenceRequestIdentity(query: query)
        let supported = CapabilityEvidenceFacade.Candidate(
            key: "generation_parameter/temperature", support: .supported, source: .serverProfile,
            grade: .effectVerified, scope: .providerModelTransport, providerKind: "openAI",
            modelID: "gpt-5", transport: "openai_responses", metadataRevision: "m1", generationRevision: "g1"
        )
        let runtime = try #require(CapabilityEvidenceProductionAdapter.runtimeRejectedCandidate(
            parameterID: "temperature", identity: identity, observedAt: Date(timeIntervalSince1970: 900)
        ))
        let result = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature", query: query, candidates: [supported, runtime]
        )
        #expect(result.support == .supported)
        #expect(result.requestPolicy == .omitRuntimeRejected)
        #expect(result.reasonCode == .runtimeRejected)
    }

    @Test("Runtime Self Heal Producer Feeds Facade And Fails Closed Without Revision")
    func runtimeSelfHealProducerFeedsFacadeAndFailsClosedWithoutRevision() throws {
        let query = CapabilityEvidenceFacade.Query(
            partitionID: "u1", connectionInstanceID: "p1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "openAI", modelID: "gpt-5", effectiveTransport: "openai_responses",
            endpointFingerprint: "ep_final", metadataRevision: "etag-200", generationRevision: nil,
            now: 1_000, hasExplicitValue: true
        )
        let identity = CapabilityEvidenceRequestIdentity(query: query)
        UnsupportedParamCache.shared.resetForTesting()
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .openAI, modelID: "gpt-5", param: "temperature",
            endpointFingerprint: "ep_final", identity: identity
        ))
        let runtime = try #require(UnsupportedParamCache.shared.runtimeRejectedCandidate(
            providerKind: .openAI, modelID: "gpt-5", param: "temperature",
            endpointFingerprint: "ep_final", identity: identity
        ))
        let supported = CapabilityEvidenceFacade.Candidate(
            key: "generation_parameter/temperature", support: .supported, source: .serverProfile,
            grade: .effectVerified, scope: .providerModelTransport, providerKind: "openAI",
            modelID: "gpt-5", transport: "openai_responses", metadataRevision: "etag-200"
        )
        let resolved = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature", query: query, candidates: [supported, runtime]
        )
        #expect(resolved.support == .supported)
        #expect(resolved.requestPolicy == .omitRuntimeRejected)
        #expect(UnsupportedParamCache.shared.facadeDroppedParams(
            providerKind: .openAI, modelID: "gpt-5", endpointFingerprint: "ep_final", identity: identity
        ) == ["temperature"])

        let noRevision = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "p1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "openAI", modelID: "gpt-5", effectiveTransport: "openai_responses",
            endpointFingerprint: "ep_final", metadataRevision: nil, generationRevision: nil,
            now: 1_000, hasExplicitValue: true
        ))
        #expect(!UnsupportedParamCache.shared.markUnsupported(
            providerKind: .openAI, modelID: "gpt-5", param: "top_p",
            endpointFingerprint: "ep_final", identity: noRevision
        ))
        #expect(UnsupportedParamCache.shared.runtimeRejectedCandidate(
            providerKind: .openAI, modelID: "gpt-5", param: "top_p",
            endpointFingerprint: "ep_final", identity: noRevision
        ) == nil)
    }

    @Test("Metadata ETag And Keychain Lifecycle Advance Identity")
    func metadataETagAndKeychainLifecycleAdvanceIdentity() {
        ProviderCapabilityIdentityStore.resetForTesting()
        let providerID = UUID()
        let provider = TestFactories.makeProvider(id: providerID, kind: .openAI)
        let model = TestFactories.makeModel(id: "gpt-5")
        let request = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1", hasExplicitValue: true,
            metadataETag: "etag-200-a"
        )
        #expect(request.query.metadataRevision == "etag-200-a")
        #expect(request.query.generationRevision == "etag-200-a")

        let beforeSave = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "h5-capability-evidence")
        let otherAccountBefore = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "h5-capability-evidence-other")
        ProviderAPIKeyStore.save(apiKey: "h5-test-key", providerID: providerID, uid: "h5-capability-evidence")
        let afterSave = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "h5-capability-evidence")
        ProviderAPIKeyStore.delete(providerID: providerID, uid: "h5-capability-evidence")
        let afterDelete = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "h5-capability-evidence")
        let otherAccountAfter = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "h5-capability-evidence-other")

        #expect(afterSave.credentialEpoch != beforeSave.credentialEpoch)
        #expect(afterDelete.credentialEpoch != afterSave.credentialEpoch)
        #expect(afterDelete.connectionGeneration == afterSave.connectionGeneration)
        #expect(otherAccountAfter == otherAccountBefore)
    }

    @Test("Ordinary Session Persist Preserves Credential Epoch And Runtime Cache")
    func ordinarySessionPersistPreservesCredentialEpochAndRuntimeCache() throws {
        ProviderCapabilityIdentityStore.resetForTesting()
        UnsupportedParamCache.shared.resetForTesting()
        let uid = "h7-session-persist-\(UUID().uuidString)"
        let providerID = UUID()
        let model = TestFactories.makeModel(id: "persist-cache-model")
        var provider = TestFactories.makeProvider(
            id: providerID,
            kind: .openAI,
            models: [model],
            apiKey: "credential-a"
        )
        defer { AppSessionStore.clearPartition(for: uid) }

        ProviderAPIKeyStore.save(apiKey: provider.apiKey, providerID: providerID, uid: uid)
        let first = try #require(CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: uid,
            hasExplicitValue: true,
            effectiveTransport: "openai_responses",
            metadataETag: "persist-etag"
        ).resolvingFinalDispatch(
            URL(string: "https://api.openai.com/v1/responses"),
            effectiveTransport: "openai_responses",
            metadataRevision: "persist-etag",
            generationRevision: "persist-etag"
        ))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .openAI,
            modelID: model.id,
            param: "temperature",
            endpointFingerprint: first.query.endpointFingerprint,
            identity: first
        ))

        AppSessionStore.save(AppSessionSnapshot(
            selectedTab: .home,
            hasCompletedOnboarding: true,
            providers: [provider],
            lastUsedModelRef: nil
        ), for: uid)

        let afterPersist = ProviderCapabilityIdentityStore.identity(
            providerID: providerID,
            partitionID: uid
        )
        #expect(afterPersist.credentialEpoch == first.query.credentialEpoch)
        let second = try #require(CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: uid,
            hasExplicitValue: true,
            effectiveTransport: "openai_responses",
            metadataETag: "persist-etag"
        ).resolvingFinalDispatch(
            URL(string: "https://api.openai.com/v1/responses"),
            effectiveTransport: "openai_responses",
            metadataRevision: "persist-etag",
            generationRevision: "persist-etag"
        ))
        #expect(second.query.credentialEpoch == first.query.credentialEpoch)
        #expect(UnsupportedParamCache.shared.facadeDroppedParams(
            providerKind: .openAI,
            modelID: model.id,
            endpointFingerprint: second.query.endpointFingerprint,
            identity: second
        ) == ["temperature"])

        provider.apiKey = "credential-b"
        ProviderAPIKeyStore.save(apiKey: provider.apiKey, providerID: providerID, uid: uid)
        let afterReplacement = ProviderCapabilityIdentityStore.identity(
            providerID: providerID,
            partitionID: uid
        )
        #expect(afterReplacement.credentialEpoch != afterPersist.credentialEpoch)
        ProviderAPIKeyStore.delete(providerID: providerID, uid: uid)
        let afterDeletion = ProviderCapabilityIdentityStore.identity(
            providerID: providerID,
            partitionID: uid
        )
        #expect(afterDeletion.credentialEpoch != afterReplacement.credentialEpoch)
    }

    @Test("Missing ETag Clears Revision And Relay Dispatch Wins Over Profile")
    func missingETagClearsRevisionAndRelayDispatchWinsOverProfile() async {
        await MetadataClient.shared.resetForTesting()
        await MetadataClient.shared.replaceStoredETagForTesting("etag-old")
        #expect(MetadataClient.shared.syncMetadataETag() == "etag-old")
        await MetadataClient.shared.replaceStoredETagForTesting(nil)
        #expect(MetadataClient.shared.syncMetadataETag() == nil)

        let relay = TestFactories.makeProvider(id: UUID(), kind: .relay)
        let model = TestFactories.makeModel(id: "private-model")
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: relay, model: model, partitionID: "u1", hasExplicitValue: false,
            effectiveTransport: RelayTransport.anthropicMessages.rawValue, metadataETag: "etag-current"
        )
        #expect(identity.query.effectiveTransport == RelayTransport.anthropicMessages.rawValue)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Nil Profile Revision Uses Current ETag")
    func relayNilProfileRevisionUsesCurrentETag() async throws {
        await MetadataClient.shared.resetForTesting()
        await MetadataClient.shared.replaceStoredETagForTesting("relay-etag-v1")
        let initial = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "relay-1",
            connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "private-model",
            effectiveTransport: "", endpointFingerprint: nil,
            metadataRevision: "relay-etag-v1", generationRevision: "relay-etag-v1",
            now: 1_000, hasExplicitValue: true
        ))
        let request = URLRequest(url: try #require(URL(string: "https://relay.test/v1/chat/completions")))
        let scoped = try #require(CapabilityEvidenceRequestContext.$current.withValue(initial) {
            CapabilityEvidenceRequestContext.generationScope(
                for: request,
                effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
                relayEngineProfile: nil,
                relayDeclaredProfile: nil
            )
        })
        #expect(scoped.query.generationRevision == "relay-etag-v1")
        let projection = CapabilityEvidenceProductionAdapter.generationRequestProjection(
            identity: scoped,
            relayEngineProfile: nil,
            explicitParameterIDs: ["temperature"]
        )
        #expect(projection.permitsOutbound("temperature"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Persisted Negative Overrides Local Declaration")
    func relayPersistedNegativeOverridesLocalDeclaration() async throws {
        await MetadataClient.shared.resetForTesting()
        await MetadataClient.shared.replaceStoredETagForTesting("relay-etag-v1")
        let initial = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "relay-1",
            connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "private-model",
            effectiveTransport: "", endpointFingerprint: nil,
            metadataRevision: "relay-etag-v1", generationRevision: "relay-etag-v1",
            now: 1_000, hasExplicitValue: true
        ))
        let declared = GenerationProfileRef(
            parameters: [.init(id: "temperature", support: "unsupported", source: "relay_declared")],
            transport: RelayTransport.openaiChatCompletions.rawValue
        )
        let request = URLRequest(url: try #require(URL(string: "https://relay.test/v1/chat/completions")))
        let scoped = try #require(CapabilityEvidenceRequestContext.$current.withValue(initial) {
            CapabilityEvidenceRequestContext.generationScope(
                for: request,
                effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
                relayEngineProfile: nil,
                relayDeclaredProfile: declared
            )
        })
        let projection = CapabilityEvidenceProductionAdapter.generationRequestProjection(
            identity: scoped,
            relayEngineProfile: nil,
            relayDeclaredProfile: declared,
            explicitParameterIDs: ["temperature"]
        )
        #expect(projection.resolution(for: "temperature")?.support == .unsupported)
        #expect(!projection.permitsOutbound("temperature"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Runtime Candidate Uses Actual Dispatch Scope")
    func relayRuntimeCandidateUsesActualDispatchScope() async throws {
        await MetadataClient.shared.resetForTesting()
        await MetadataClient.shared.replaceStoredETagForTesting("relay-etag-v1")
        let initial = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "relay-1",
            connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "private-model",
            effectiveTransport: "", endpointFingerprint: nil,
            metadataRevision: "relay-etag-v1", generationRevision: "relay-etag-v1",
            now: 1_000, hasExplicitValue: true
        ))
        let request = URLRequest(url: try #require(URL(string: "https://relay.test/v1/messages")))
        let scoped = try #require(CapabilityEvidenceRequestContext.$current.withValue(initial) {
            CapabilityEvidenceRequestContext.generationScope(
                for: request,
                effectiveTransport: RelayTransport.anthropicMessages.rawValue,
                relayEngineProfile: nil,
                relayDeclaredProfile: nil
            )
        })
        let runtime = try #require(CapabilityEvidenceProductionAdapter.runtimeRejectedCandidate(
            parameterID: "temperature", identity: scoped,
            observedAt: Date()
        ))
        #expect(runtime.transport == RelayTransport.anthropicMessages.rawValue)
        let resolved = CapabilityEvidenceFacade.resolve(
            key: "generation_parameter/temperature",
            query: scoped.query,
            candidates: [runtime]
        )
        #expect(resolved.requestPolicy == .omitRuntimeRejected)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Production Metadata Feeds General Capability Projection")
    func productionMetadataFeedsGeneralCapabilityProjection() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "profiles": {
            "reasoning": {"reasoning-profile": {"levels": ["fast", "deep"]}},
            "webSearch": {"web-profile": {"mergeParams": {"tools": [{"type":"web_search"}]}}}
          },
          "providers": {"openAI": {
            "resolveMap": {"capability-model":"capability-model"},
            "models": {"capability-model": {
              "canonicalModelId":"capability-model",
              "transport":"openai_responses",
              "capabilities":["text","image","web","reasoning"],
              "profiles":{"reasoning":"reasoning-profile","webSearch":"web-profile"},
              "toolCall":false,
              "capabilityEvidenceView": {
                "schema":"capability-evidence-view/v1",
                "candidates":[{
                  "key":"tool_call","support":"supported","source":"server_typed",
                  "grade":"machine_verified","scope":"provider_model_transport",
                  "providerKind":"openAI","modelId":"capability-model",
                  "transport":"openai_responses","observedAt":1786000000000,"expiresAt":4102444800000
                }]
              }
            }}
          }}
        }
        """, metadataETag: "capability-etag-v1")
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let persisted = TestFactories.makeModel(id: "capability-model")
        let current = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            persisted, providerKind: .openAI
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: current, partitionID: "u1",
            hasExplicitValue: true, metadataETag: "capability-etag-v1"
        )
        let request = URLRequest(url: try #require(URL(string: "https://api.test/v1/responses")))
        let keys: Set<String> = [
            "tool_call", "web_search", "vision_input",
            "reasoning_level/deep", "reasoning_level/max",
        ]
        let projection = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                request: request, effectiveTransport: "openai_responses",
                provider: provider, model: current, keys: keys, explicitKeys: keys
            )
        }
        #expect(projection.resolution(for: "tool_call")?.support == .supported)
        #expect(projection.resolution(for: "tool_call")?.source == .serverTyped)
        #expect(projection.permitsOutbound("web_search"))
        #expect(projection.permitsOutbound("vision_input"))
        #expect(projection.permitsOutbound("reasoning_level/deep"))
        #expect(!projection.permitsOutbound("reasoning_level/max"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Malformed Namespace Fails Closed For General Capabilities")
    func malformedNamespaceFailsClosedForGeneralCapabilities() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version":1,
          "providers":{"openAI":{"resolveMap":{"capability-model":"capability-model"},
            "models":{"capability-model":{
              "canonicalModelId":"capability-model","transport":"openai_responses",
              "capabilities":["text","image","web"],"profiles":{"webSearch":"web-profile"},
              "toolCall":true,"capabilityEvidenceView":null
            }}
          }}
        }
        """, metadataETag: "malformed-etag")
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            TestFactories.makeModel(id: "capability-model"), providerKind: .openAI
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: "malformed-etag"
        )
        let keys: Set<String> = ["tool_call", "web_search", "vision_input"]
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: keys, explicitKeys: keys
        )
        #expect(keys.allSatisfy { projection.resolution(for: $0)?.support == .unknown })
        #expect(keys.allSatisfy { !projection.permitsOutbound($0) })
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Final Chat Intent Filters Outbound Vision Copy After Evidence Withdrawal")
    func finalChatIntentFiltersOutboundVisionCopyAfterEvidenceWithdrawal() async throws {
        await MetadataClient.shared.resetForTesting()
        func payload(view: String) -> String {
            """
            {
              "version":11,
              "providers":{"openAI":{"resolveMap":{"vision-model":"vision-model"},
                "models":{"vision-model":{
                  "canonicalModelId":"vision-model","transport":"openai_responses",
                  "capabilities":["text","image"],"capabilityEvidenceView":\(view)
                }}
              }}
            }
            """
        }
        let supportedView = """
        {"schema":"capability-evidence-view/v1","candidates":[{
          "key":"vision_input","support":"supported","source":"server_typed",
          "grade":"machine_verified","scope":"provider_model_transport",
          "providerKind":"openAI","modelId":"vision-model","transport":"openai_responses",
          "observedAt":1786000000000,"expiresAt":4102444800000
        },{
          "key":"web_search","support":"supported","source":"server_typed",
          "grade":"machine_verified","scope":"provider_model_transport",
          "providerKind":"openAI","modelId":"vision-model","transport":"openai_responses",
          "observedAt":1786000000000,"expiresAt":4102444800000
        }]}
        """
        try await MetadataClient.shared.loadForTesting(
            json: payload(view: supportedView), metadataETag: "vision-etag-1"
        )
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            TestFactories.makeModel(id: "vision-model"), providerKind: .openAI
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: "vision-etag-1"
        )
        let original = TestFactories.makeMessage(
            providerID: provider.id, providerKind: .openAI, modelID: model.id,
            attachments: [TestFactories.makeImageAttachment()]
        )
        let messages = [original]
        let request = URLRequest(url: try #require(URL(string: "https://api.openai.com/v1/responses")))
        let allowedTelemetry = CapabilityDispatchCounter()
        let allowedOnce = CapabilityEvidenceDispatchOnce()
        let allowed = CapabilityEvidenceDispatchContext.$onWebSearchDispatched.withValue({
            allowedOnce.perform { allowedTelemetry.increment() }
        }) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                CapabilityEvidenceProductionAdapter.finalChatIntent(
                    messages: messages, request: request, effectiveTransport: "openai_responses",
                    model: model, requestedReasoningMode: .automatic, webSearchEnabled: true
                )
            }
        }
        #expect(allowed.outboundMessages.first?.attachments?.count == 1)
        #expect(allowed.webSearchEnabled)
        #expect(allowedTelemetry.value == 1)
        _ = CapabilityEvidenceDispatchContext.$onWebSearchDispatched.withValue({
            allowedOnce.perform { allowedTelemetry.increment() }
        }) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                CapabilityEvidenceProductionAdapter.finalChatIntent(
                    messages: messages, request: request, effectiveTransport: "openai_responses",
                    model: model, requestedReasoningMode: .automatic, webSearchEnabled: true
                )
            }
        }
        #expect(allowedTelemetry.value == 1)

        try await MetadataClient.shared.loadForTesting(
            json: payload(view: "null"), metadataETag: "vision-etag-2"
        )
        let deniedTelemetry = CapabilityDispatchCounter()
        let filtered = CapabilityEvidenceDispatchContext.$onWebSearchDispatched.withValue({
            deniedTelemetry.increment()
        }) {
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                CapabilityEvidenceProductionAdapter.finalChatIntent(
                    messages: messages, request: request, effectiveTransport: "openai_responses",
                    model: model, requestedReasoningMode: .automatic, webSearchEnabled: true
                )
            }
        }
        #expect(filtered.outboundMessages.first?.attachments == nil)
        #expect(!filtered.webSearchEnabled)
        #expect(deniedTelemetry.value == 0)
        #expect(messages.first?.attachments?.count == 1)
        await MetadataClient.shared.resetForTesting()
    }

    @MainActor
    @Test("Provider Mutation Invalidates Old Runtime Evidence")
    func providerMutationInvalidatesOldRuntimeEvidence() throws {
        ProviderCapabilityIdentityStore.resetForTesting()
        UnsupportedParamCache.shared.resetForTesting()
        let state = AppState(seedDemoData: false)
        let model = TestFactories.makeModel(id: "mutation-model")
        var provider = TestFactories.makeProvider(
            id: UUID(), kind: .openAI, models: [model],
            baseURLText: "https://first.example/v1"
        )
        #expect(state.providerManager.upsertProvider(provider))
        let partition = state.sessionPartitionUID
        let first = try #require(CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partition,
            hasExplicitValue: true, effectiveTransport: "openai_responses",
            metadataETag: "mutation-etag"
        ).resolvingFinalDispatch(
            URL(string: "https://first.example/v1/responses"),
            effectiveTransport: "openai_responses",
            metadataRevision: "mutation-etag", generationRevision: "mutation-etag"
        ))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .openAI, modelID: model.id, param: "temperature",
            endpointFingerprint: first.query.endpointFingerprint, identity: first
        ))
        #expect(UnsupportedParamCache.shared.facadeDroppedParams(
            providerKind: .openAI, modelID: model.id,
            endpointFingerprint: first.query.endpointFingerprint, identity: first
        ) == ["temperature"])

        provider.baseURLText = "https://second.example/v1"
        state.providerManager.updateProvider(provider)
        let currentProvider = try #require(state.provider(for: provider.id))
        let second = try #require(CapabilityEvidenceRequestIdentity.make(
            provider: currentProvider, model: model, partitionID: partition,
            hasExplicitValue: true, effectiveTransport: "openai_responses",
            metadataETag: "mutation-etag"
        ).resolvingFinalDispatch(
            URL(string: "https://second.example/v1/responses"),
            effectiveTransport: "openai_responses",
            metadataRevision: "mutation-etag", generationRevision: "mutation-etag"
        ))
        #expect(second.query.connectionGeneration != first.query.connectionGeneration)
        #expect(UnsupportedParamCache.shared.facadeDroppedParams(
            providerKind: .openAI, modelID: model.id,
            endpointFingerprint: second.query.endpointFingerprint, identity: second
        ).isEmpty)
    }

    @Test("Operator Negative Denies Every Final Capability")
    func operatorNegativeDeniesEveryFinalCapability() async throws {
        await MetadataClient.shared.resetForTesting()
        let keys = ["tool_call", "web_search", "vision_input", "reasoning_level/deep"]
        let candidates = keys.map { key in
            """
            {"key":"\(key)","support":"unsupported","source":"operator_override",
             "grade":"operator","scope":"provider_model_transport","providerKind":"openAI",
             "modelId":"operator-model","transport":"openai_responses"}
            """
        }.joined(separator: ",")
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version":12,
          "profiles":{
            "reasoning":{"reasoning-profile":{"levels":["deep"],"defaultLevel":"deep"}},
            "webSearch":{"web-profile":{"mergeParams":{"tools":[{"type":"web_search"}]}}}
          },
          "providers":{"openAI":{"resolveMap":{"operator-model":"operator-model"},
            "models":{"operator-model":{
              "canonicalModelId":"operator-model","transport":"openai_responses",
              "capabilities":["text","image","web","reasoning"],"toolCall":true,
              "profiles":{"reasoning":"reasoning-profile","webSearch":"web-profile"},
              "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[\(candidates)]}
            }}
          }}
        }
        """, metadataETag: "operator-etag")
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            TestFactories.makeModel(id: "operator-model"), providerKind: .openAI
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: true, metadataETag: "operator-etag"
        )
        let request = URLRequest(url: try #require(URL(string: "https://api.openai.com/v1/responses")))
        let messages = [TestFactories.makeMessage(
            providerID: provider.id, providerKind: .openAI, modelID: model.id,
            attachments: [TestFactories.makeImageAttachment()]
        )]
        let chatIntent = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            CapabilityEvidenceProductionAdapter.finalChatIntent(
                messages: messages, request: request, effectiveTransport: "openai_responses",
                model: model, requestedReasoningMode: .deep, webSearchEnabled: true
            )
        }
        let toolIntent = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                request: request, effectiveTransport: "openai_responses", model: model,
                keys: ["tool_call"], explicitKeys: ["tool_call"]
            )
        }
        #expect(!chatIntent.webSearchEnabled)
        #expect(chatIntent.reasoningMode == nil)
        #expect(chatIntent.outboundMessages.first?.attachments == nil)
        for key in keys where key != "tool_call" {
            #expect(chatIntent.projection.resolution(for: key)?.source == .operatorOverride)
            #expect(chatIntent.projection.resolution(for: key)?.support == .unsupported)
            #expect(!chatIntent.projection.permitsOutbound(key))
        }
        #expect(toolIntent.resolution(for: "tool_call")?.source == .operatorOverride)
        #expect(toolIntent.resolution(for: "tool_call")?.support == .unsupported)
        #expect(!toolIntent.permitsOutbound("tool_call"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay Missing Scope Fails Closed At Final Intent")
    func relayMissingScopeFailsClosedAtFinalIntent() throws {
        var model = TestFactories.makeModel(
            id: "private-model", capabilities: [.image, .web, .reasoning],
            reasoningModeAvailable: true
        )
        model.toolCall = true
        model.reasoningProfile = "relay-reasoning"
        model.webSearchProfile = "relay-web"
        let incomplete = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "", connectionInstanceID: "", connectionGeneration: "", credentialEpoch: "",
            providerKind: ProviderKind.relay.rawValue, modelID: model.id,
            effectiveTransport: RelayTransport.openaiResponses.rawValue,
            endpointFingerprint: nil, metadataRevision: nil, generationRevision: nil,
            now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: true
        ))
        let request = URLRequest(url: try #require(URL(string: "https://relay.example/v1/responses")))
        let messages = [TestFactories.makeMessage(
            providerKind: .relay, modelID: model.id,
            attachments: [TestFactories.makeImageAttachment()]
        )]
        let chatIntent = CapabilityEvidenceRequestContext.$current.withValue(incomplete) {
            CapabilityEvidenceProductionAdapter.finalChatIntent(
                messages: messages, request: request,
                effectiveTransport: RelayTransport.openaiResponses.rawValue,
                model: model, requestedReasoningMode: .deep, webSearchEnabled: true
            )
        }
        let toolIntent = CapabilityEvidenceRequestContext.$current.withValue(incomplete) {
            CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                request: request, effectiveTransport: RelayTransport.openaiResponses.rawValue,
                model: model, keys: ["tool_call"], explicitKeys: ["tool_call"]
            )
        }
        #expect(!chatIntent.webSearchEnabled)
        #expect(chatIntent.reasoningMode == nil)
        #expect(chatIntent.outboundMessages.first?.attachments == nil)
        #expect(!toolIntent.permitsOutbound("tool_call"))
        #expect(chatIntent.projection.resolutions.values.allSatisfy { $0.support == .unknown })
    }

    @Test("Clear Learned Runtime Evidence Uses Current Identity")
    func clearLearnedRuntimeEvidenceUsesCurrentIdentity() {
        UnsupportedParamCache.shared.resetForTesting()
        let first = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "relay-1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "local", effectiveTransport: "openai_chat_completions",
            endpointFingerprint: "ep_a", metadataRevision: "etag-a", generationRevision: nil,
            now: 1_000, hasExplicitValue: true
        ))
        let otherPartition = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u2", connectionInstanceID: "relay-1", connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: "relay", modelID: "local", effectiveTransport: "openai_chat_completions",
            endpointFingerprint: "ep_b", metadataRevision: "etag-a", generationRevision: nil,
            now: 1_000, hasExplicitValue: true
        ))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .relay, modelID: "local", param: "temperature",
            endpointFingerprint: "ep_a", identity: first
        ))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .relay, modelID: "local", param: "temperature",
            endpointFingerprint: "ep_b", identity: otherPartition
        ))
        UnsupportedParamCache.shared.clear(providerKind: .relay, modelID: "local", identity: first)
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay, modelID: "local", param: "temperature",
            endpointFingerprint: "ep_a", identity: first
        ))
        #expect(UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay, modelID: "local", param: "temperature",
            endpointFingerprint: "ep_b", identity: otherPartition
        ))
        #expect(!UnsupportedParamCache.shared.markUnsupported(
            providerKind: .relay, modelID: "local", param: "top_p", endpointFingerprint: "ep_a"
        ))
    }

    @Test("A Recovery Without A Runtime Identity Is Never Cached")
    func recoveryWithoutRuntimeIdentityIsNeverCached() {
        // No identity means no scope the entry could safely be reused in, so the parameter must
        // not be remembered as unsupported for the next request.
        UnsupportedParamCache.shared.resetForTesting()
        #expect(!UnsupportedParamSelfHealReporter.markDropped(
            providerKind: .relay, modelID: "private-model", param: "temperature",
            endpointFingerprint: "ep_final", identity: nil
        ))
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay, modelID: "private-model", param: "temperature", endpointFingerprint: "ep_final"
        ))
    }

    /// The wrapper must hand the upstream failure back untouched: without a runtime identity there
    /// is no scope in which stripping a parameter and retrying could be justified.
    @Test("Identityless Stream Wrapper Never Strips Or Retries")
    func identitylessStreamWrapperNeverStripsOrRetries() async throws {
        UnsupportedParamCache.shared.resetForTesting()
        var attempts = 0
        let stream: AsyncThrowingStream<String, Error> = UnsupportedParamSelfHeal.wrapStream(
            providerKind: .relay,
            modelID: "private-model",
            endpointFingerprint: "ep_final"
        ) { dropped in
            attempts += 1
            #expect(dropped.isEmpty)
            return AsyncThrowingStream<String, Error> { continuation in
                continuation.finish(throwing: ProviderServiceError.upstream(
                    statusCode: 400,
                    detail: "unknown parameter: temperature"
                ))
            }
        }
        var values: [String] = []
        var caught: Error?
        do {
            for try await value in stream { values.append(value) }
        } catch {
            caught = error
        }
        #expect(attempts == 1)
        #expect(values.isEmpty)
        if case .upstream(let statusCode, _)? = caught as? ProviderServiceError {
            #expect(statusCode == 400)
        } else {
            Issue.record("Upstream 400 must be rethrown as-is, got \(String(describing: caught))")
        }
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay, modelID: "private-model", param: "temperature", endpointFingerprint: "ep_final"
        ))
    }

    @Test("Identity Store Advances Without Using Provider Metadata")
    func identityStoreAdvancesWithoutUsingProviderMetadata() {
        ProviderCapabilityIdentityStore.resetForTesting()
        let providerID = UUID()
        let first = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "u1")
        ProviderCapabilityIdentityStore.advanceConnectionGeneration(providerID: providerID, partitionID: "u1")
        let afterConnection = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "u1")
        ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: providerID, partitionID: "u1")
        let afterCredential = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "u1")
        ProviderCapabilityIdentityStore.tombstone(providerID: providerID, partitionID: "u1")
        let recreated = ProviderCapabilityIdentityStore.identity(providerID: providerID, partitionID: "u1")

        #expect(first.connectionGeneration != afterConnection.connectionGeneration)
        #expect(afterConnection.credentialEpoch == first.credentialEpoch)
        #expect(afterCredential.connectionGeneration == afterConnection.connectionGeneration)
        #expect(afterCredential.credentialEpoch != afterConnection.credentialEpoch)
        #expect(recreated.connectionGeneration != afterCredential.connectionGeneration)
        #expect(recreated.credentialEpoch != afterCredential.credentialEpoch)
    }

    // MARK: - Fixture loading

    private static func loadContract() throws -> Contract {
        try loadJSON(relativePath: ["shared", "model-contracts", "capability_evidence_contract.v1.json"])
    }

    private static func loadProductionShapes() throws -> ProductionShapes {
        try loadJSON(relativePath: ["shared", "test-fixtures", "provider-capability-evidence", "production-shapes.v1.json"])
    }

    private static func loadJSON<T: Decodable>(relativePath: [String]) throws -> T {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = relativePath.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: candidate))
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func metadataJSON(serverModel: ProductionShapes.Model, rawProfile: ProductionShapes.GenerationProfile) throws -> String {
        let modelData = try JSONEncoder().encode(serverModel)
        let profileData = try JSONEncoder().encode(rawProfile)
        var modelObject = try #require(
            JSONSerialization.jsonObject(with: modelData) as? [String: Any]
        )
        var profiles = try #require(modelObject["profiles"] as? [String: Any])
        profiles["generation"] = try JSONSerialization.jsonObject(with: profileData)
        modelObject["profiles"] = profiles
        let normalizedInput = try JSONSerialization.data(withJSONObject: modelObject, options: [.sortedKeys])
        let modelJSON = try #require(String(data: normalizedInput, encoding: .utf8))
        return """
        {
          "version": 9001,
          "contractVersion": 1,
          "profiles": {
            "generation": {
              "version": 17,
              "parameters": {},
              "templates": {
                "\(rawProfile.template)": {"transport":"openai_responses","wire":{"temperature":"temperature","top_p":"top_p","min_p":"min_p"}}
              }
            }
          },
          "providers": {
            "openAI": {
              "resolveMap": {"gpt-5.4":"gpt-5.4"},
              "models": {"gpt-5.4": \(modelJSON)}
            }
          }
        }
        """
    }

    private static func evidenceMetadataJSON(view: String?) -> String {
        let viewMember = view.map { ",\"capabilityEvidenceView\":\($0)" } ?? ""
        return """
        {
          "version": 42,
          "contractVersion": 1,
          "capabilityContractVersion": 2,
          "providers": {
            "openAI": {
              "resolveMap": {"gpt-5":"gpt-5"},
              "models": {
                "gpt-5": {
                  "canonicalModelId":"gpt-5",
                  "transport":"openai_responses"\(viewMember)
                }
              }
            }
          }
        }
        """
    }

    struct Contract: Decodable {
        let version: Int
        let cases: [Case]

        struct Case: Decodable {
            let caseId: String
            let query: Query
            let candidates: [Candidate]
            let expect: Expectation
        }

        struct Query: Decodable {
            let partitionId: String
            let connectionInstanceId: String
            let connectionGeneration: String
            let credentialEpoch: String
            let providerKind: String
            let modelId: String
            let canonicalModelId: String?
            let effectiveTransport: String
            let endpointFingerprint: String?
            let metadataRevision: String?
            let generationRevision: String?
            let now: Int64
            let hasExplicitValue: Bool

            func asFacadeQuery() -> CapabilityEvidenceFacade.Query {
                CapabilityEvidenceFacade.Query(
                    partitionID: partitionId, connectionInstanceID: connectionInstanceId,
                    connectionGeneration: connectionGeneration, credentialEpoch: credentialEpoch,
                    providerKind: providerKind, modelID: modelId, canonicalModelID: canonicalModelId,
                    effectiveTransport: effectiveTransport, endpointFingerprint: endpointFingerprint,
                    metadataRevision: metadataRevision, generationRevision: generationRevision,
                    now: now, hasExplicitValue: hasExplicitValue
                )
            }
        }

        struct Candidate: Decodable {
            let key: String
            let support: String
            let source: String
            let grade: String
            let scope: String
            let policy: String?
            let partitionId: String?
            let providerKind: String
            let modelId: String
            let transport: String
            let connectionInstanceId: String?
            let connectionGeneration: String?
            let credentialEpoch: String?
            let endpointFingerprint: String?
            let metadataRevision: String?
            let generationRevision: String?
            let observedAt: Int64?
            let expiresAt: Int64?

            func asFacadeCandidate() -> CapabilityEvidenceFacade.Candidate {
                CapabilityEvidenceFacade.Candidate(
                    key: key, support: CapabilityEvidenceFacade.Support(rawValue: support) ?? .unknown,
                    source: CapabilityEvidenceFacade.Source(rawValue: source) ?? .none,
                    grade: CapabilityEvidenceFacade.Grade(rawValue: grade) ?? .none,
                    scope: CapabilityEvidenceFacade.Scope(rawValue: scope) ?? .providerModelTransport,
                    // Contract candidate `runtime_rejected` names the evidence fact; the facade's
                    // request-policy enum names its resulting outbound action.
                    policy: policy == "runtime_rejected"
                        ? .omitRuntimeRejected
                        : policy.flatMap(CapabilityEvidenceFacade.RequestPolicy.init(rawValue:)),
                    partitionID: partitionId, providerKind: providerKind, modelID: modelId, transport: transport,
                    connectionInstanceID: connectionInstanceId, connectionGeneration: connectionGeneration,
                    credentialEpoch: credentialEpoch, endpointFingerprint: endpointFingerprint,
                    metadataRevision: metadataRevision, generationRevision: generationRevision,
                    observedAt: observedAt, expiresAt: expiresAt
                )
            }
        }

        struct Expectation: Decodable {
            let key: String
            let support: String
            let source: String
            let grade: String
            let requestPolicy: String
            let reasonCode: String
            let policyEvidence: PolicyEvidence?
        }

        struct PolicyEvidence: Decodable {
            let source: String
            let grade: String
        }
    }

    struct ProductionShapes: Decodable {
        let sources: Sources

        struct Sources: Decodable {
            let serverMetadata: ServerMetadata?
            let generationProfile: GenerationProfileSource?
        }

        struct ServerMetadata: Decodable {
            let payload: ServerPayload
        }

        struct ServerPayload: Decodable {
            let providers: [String: ServerProvider]
        }

        struct ServerProvider: Decodable {
            let models: [String: Model]
        }

        struct GenerationProfileSource: Decodable {
            let payload: GenerationProfile
        }

        struct GenerationProfile: Codable {
            let template: String
            let parameters: [GenerationParameter]
        }

        struct GenerationParameter: Codable {
            let id: String
            let support: String
            let source: String
            let wire: String
        }

        struct Model: Codable {
            let canonicalModelId: String
            let aliases: [String]
            let transport: String
            let capabilities: [String]
            let toolCall: Bool
            let profiles: Profiles
        }

        struct Profiles: Codable {
            let reasoning: String
            let webSearch: String
            let generation: GenerationProfile
        }
    }
}
