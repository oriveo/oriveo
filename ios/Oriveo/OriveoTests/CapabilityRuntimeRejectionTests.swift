import Foundation
import Testing
@testable import Oriveo

/// Exact runtime rejection contract. The durable cache is discriminated by source and exact
/// runtime identity; recipe recovery filters only the located requestOp pointers.
@Suite("Capability runtime rejection", .serialized)
struct CapabilityRuntimeRejectionTests {
    private func identity(
        connectionID: String = "p1",
        modelID: String = "gpt-5.4",
        transport: String = "openai_responses",
        runtimeRevision: String = "d1-runtime",
        endpoint: String = "ep_official",
        metadataRevision: String = "etag-1",
        generationRevision: String = "etag-1"
    ) -> CapabilityEvidenceRequestIdentity {
        CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: connectionID, connectionGeneration: "cg1",
            credentialEpoch: "ce1", providerKind: "openAI", modelID: modelID,
            canonicalModelID: modelID, effectiveTransport: transport,
            endpointFingerprint: endpoint, metadataRevision: metadataRevision,
            generationRevision: generationRevision,
            now: Int64(Date().timeIntervalSince1970 * 1_000), hasExplicitValue: true
        ), runtimeRevision: runtimeRevision)
    }

    @Test("Capability Rejection Is Exact Recipe Pointer")
    func capabilityRejectionIsExactRecipePointer() throws {
        UnsupportedParamCache.shared.resetForTesting()
        let identity = identity()

        #expect(UnsupportedParamCache.shared.markCapabilityRejected(
            providerKind: .openAI, modelID: "gpt-5.4", source: .providerRecipe,
            owner: "web", recipeRef: "fixture.exact.web.v1",
            setting: "/web_search_options", capabilityKey: "web_search",
            endpointFingerprint: "ep_official", identity: identity
        ))
        #expect(UnsupportedParamCache.shared.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4",
            owner: "web", recipeRef: "fixture.exact.web.v1", identity: identity
        ) == ["/web_search_options"])
        #expect(UnsupportedParamCache.shared.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4",
            owner: "web", recipeRef: "other.recipe", identity: identity
        ).isEmpty)

        #expect(UnsupportedParamCache.shared.droppedParams(
            providerKind: .openAI, modelID: "gpt-5.4",
            endpointFingerprint: "ep_official", identity: identity
        ).isEmpty)
        UnsupportedParamCache.shared.resetForTesting()
    }

    @Test("Tracker Reaches Rejected State")
    func trackerReachesRejectedState() throws {
        let runtime = try Self.runtimeEnvelope()
        let recipe = try #require(runtime.recipes["openai.responses.web.v1"])
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(
            recipe: recipe, runtime: runtime, finalTransport: "openai_responses",
            deltaRootKeys: ["tools", "tool_choice"], capabilityKeys: ["web_search"]
        )
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        #expect(tracker.terminalResult().states["web"] == .unconfirmed)

        let rejections = tracker.recordUpstreamRejection(
            statusCode: 400,
            errorData: Data(#"{"error":{"param":"tools"}}"#.utf8)
        )
        #expect(rejections.map(\.capabilityKeys) == [["web_search"]])
        #expect(rejections.map(\.runtimeRevision) == ["d1-runtime"])
        #expect(tracker.terminalResult().states["web"] == .rejected)
    }

    @Test("Unattributed Parameter Learns Nothing")
    func unattributedParameterLearnsNothing() throws {
        let runtime = try Self.runtimeEnvelope()
        let recipe = try #require(runtime.recipes["openai.responses.web.v1"])
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(
            recipe: recipe, runtime: runtime, finalTransport: "openai_responses",
            deltaRootKeys: ["tools", "tool_choice"], capabilityKeys: ["web_search"]
        )
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        #expect(tracker.recordUpstreamRejection(
            statusCode: 400,
            errorData: Data(#"{"error":{"param":"temperature"}}"#.utf8)
        ).isEmpty)
        #expect(tracker.terminalResult().states["web"] == .unconfirmed)
    }

    @Test("Shared Fixture Non Learning Failures")
    func sharedFixtureNonLearningFailures() throws {
        let fixture = try Self.sharedRuntimeFixture()
        let failures = try #require(fixture["nonLearningFailures"] as? [String])
        let shared = try Self.sharedExactRecipeRuntime()
        for failure in failures {
            let tracker = CapabilityExecutionTracker()
            tracker.recordCompiledDelta(
                recipe: shared.recipe, runtime: shared.runtime, finalTransport: "openai_responses",
                deltaRootKeys: ["web_search_options", "include"],
                ownedPointers: Set(shared.recipe.requestOps.compactMap(\.pointer)),
                capabilityKeys: ["web_search"]
            )
            tracker.confirmFinalWireEncoded()
            tracker.confirmRequestDispatched()
            switch failure {
            case "401", "403", "429":
                #expect(tracker.recordUpstreamRejection(
                    statusCode: Int(failure) ?? 0, errorData: shared.errorData
                ).isEmpty)
            case "5xx":
                #expect(tracker.recordUpstreamRejection(statusCode: 500, errorData: shared.errorData).isEmpty)
            case "stream_interrupted", "background_interrupted":
                tracker.recordUpstreamResponse()
                #expect(tracker.recordUpstreamRejection(statusCode: 400, errorData: shared.errorData).isEmpty)
            case "side_effect_started":
                tracker.recordSideEffect()
                #expect(tracker.recordUpstreamRejection(statusCode: 400, errorData: shared.errorData).isEmpty)
            case "network", "timeout", "cancelled":
                break // These paths have no structured HTTP response and never call the learner.
            default:
                Issue.record("Unhandled shared non-learning failure: \(failure)")
            }
            #expect(tracker.terminalResult().states["web"] == .unconfirmed)
            #expect(tracker.terminalResult().recoveryDescriptors == nil)
        }
    }

    @Test("Capability Rejected Candidates Never Writes Defaults")
    func capabilityRejectedCandidatesNeverWritesDefaults() throws {
        let suite = "CapabilityRejectedReadOnlyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let current = identity()

        func snapshot() -> [String: Data] {
            (defaults.persistentDomain(forName: suite) ?? [:]).compactMapValues { $0 as? Data }
        }
        func read() {
            _ = cache.capabilityRejectedCandidates(
                providerKind: .openAI, modelID: current.query.effectiveModelID,
                endpointFingerprint: current.query.endpointFingerprint, identity: current
            )
        }

        let empty = snapshot()
        read()
        read()
        #expect(snapshot() == empty)

        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: current.query.effectiveModelID,
            source: .providerRecipe, owner: "web", recipeRef: "fixture.exact.web.v1",
            setting: "/web_search_options", capabilityKey: "web_search",
            endpointFingerprint: current.query.endpointFingerprint, identity: current
        ))
        let persisted = snapshot()
        #expect(persisted != empty)

        read()
        read()
        read()
        #expect(snapshot() == persisted)
    }

    @Test("Rejection Cache Cold Start And Identity Isolation")
    func rejectionCacheColdStartAndIdentityIsolation() throws {
        let suite = "CapabilityRuntimeRejectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UnsupportedParamCache(defaults: defaults)
        let current = identity()
        #expect(first.markCapabilityRejected(
            providerKind: .openAI, modelID: current.query.effectiveModelID,
            source: .providerRecipe, owner: "web", recipeRef: "fixture.exact.web.v1",
            setting: "/web_search_options", capabilityKey: "web_search",
            endpointFingerprint: "ep_official", identity: current
        ))

        let restored = UnsupportedParamCache(defaults: defaults)
        #expect(restored.recipeRejectedPointers(
            providerKind: .openAI, modelID: current.query.effectiveModelID,
            owner: "web", recipeRef: "fixture.exact.web.v1", identity: current
        ) == ["/web_search_options"])
        let nextRuntime = CapabilityEvidenceRequestIdentity(
            query: current.query, runtimeRevision: "d1-runtime-next"
        )
        #expect(restored.recipeRejectedPointers(
            providerKind: .openAI, modelID: nextRuntime.query.effectiveModelID,
            owner: "web", recipeRef: "fixture.exact.web.v1", identity: nextRuntime
        ).isEmpty)
    }

    @Test("Recovery Descriptor Persists With Failed Message")
    func recoveryDescriptorPersistsWithFailedMessage() throws {
        let original = CapabilityExecutionResult(
            states: ["web": .rejected],
            recoveryDescriptors: [.init(
                source: .providerRecipe, owner: "web", recipeRef: "fixture.exact.web.v1",
                locatedPointers: ["/web_search_options"], runtimeRevision: "runtime-r7"
            )]
        )
        let encoded = try #require(RecordMappers.encodeCapabilityExecution(original))
        let restored = try #require(RecordMappers.decodeCapabilityExecution(encoded))
        #expect(restored == original)

        // schema v1/local rows without a descriptor remain readable and never invent a CTA target.
        let legacy = try #require(RecordMappers.decodeCapabilityExecution(
            #"{"states":{"web":"rejected"}}"#
        ))
        #expect(legacy.states["web"] == .rejected)
        #expect(legacy.recoveryDescriptors == nil)
    }

    @Test("Exact Runtime Identity Does Not Use Legacy Revisions")
    func exactRuntimeIdentityDoesNotUseLegacyRevisions() throws {
        let suite = "CapabilityRuntimeIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let stored = identity()
        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: "gpt-5.4", source: .providerRecipe,
            owner: "web", recipeRef: "fixture.exact.web.v1", setting: "/web_search_options",
            endpointFingerprint: stored.query.endpointFingerprint, identity: stored
        ))

        let legacyRevisionOnlyChanged = identity(
            endpoint: "ep-next", metadataRevision: "metadata-next", generationRevision: "generation-next"
        )
        #expect(cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "web",
            recipeRef: "fixture.exact.web.v1", identity: legacyRevisionOnlyChanged
        ) == ["/web_search_options"])
        for mismatch in [
            identity(connectionID: "p2"),
            identity(modelID: "gpt-5.4-next"),
            identity(transport: "openai_chat"),
            identity(runtimeRevision: "d1-runtime-next"),
        ] {
            #expect(cache.recipeRejectedPointers(
                providerKind: .openAI, modelID: mismatch.query.effectiveModelID,
                owner: "web", recipeRef: "fixture.exact.web.v1", identity: mismatch
            ).isEmpty)
        }
    }

    @Test("Recovery Descriptor Cannot Cross Runtime Identity")
    func recoveryDescriptorCannotCrossRuntimeIdentity() throws {
        let suite = "CapabilityRecoveryIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let stored = identity()
        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: "gpt-5.4", source: .providerRecipe,
            owner: "web", recipeRef: "fixture.exact.web.v1", setting: "/web_search_options",
            endpointFingerprint: nil, identity: stored
        ))
        let descriptor = CapabilityRecoveryDescriptor(
            source: .providerRecipe, owner: "web", recipeRef: "fixture.exact.web.v1",
            locatedPointers: ["/web_search_options"], runtimeRevision: "d1-runtime"
        )
        let exactDormant = cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "web",
            recipeRef: "fixture.exact.web.v1", identity: stored
        )
        #expect(CapabilityRecoveryDescriptorValidation.validated(
            descriptor, providerKind: .openAI, identity: stored, cache: cache
        ) == descriptor)
        #expect(CapabilityRecipeRequestCompiler.runtimeOwnedOmission(
            dormantPointers: exactDormant, source: .providerRecipe, owner: "web",
            recipeRef: "fixture.exact.web.v1", runtimeRevision: "d1-runtime",
            descriptor: descriptor
        ) == ["/web_search_options"])

        for mismatch in [
            identity(connectionID: "p2"),
            identity(modelID: "gpt-5.4-next"),
            identity(transport: "openai_chat"),
            identity(runtimeRevision: "d1-runtime-next"),
        ] {
            let dormant = cache.recipeRejectedPointers(
                providerKind: .openAI, modelID: mismatch.query.effectiveModelID, owner: "web",
                recipeRef: "fixture.exact.web.v1", identity: mismatch
            )
            #expect(dormant.isEmpty)
            #expect(CapabilityRecoveryDescriptorValidation.validated(
                descriptor, providerKind: .openAI, identity: mismatch, cache: cache
            ) == nil)
            #expect(CapabilityRecipeRequestCompiler.runtimeOwnedOmission(
                dormantPointers: dormant, source: .providerRecipe, owner: "web",
                recipeRef: "fixture.exact.web.v1", runtimeRevision: mismatch.runtimeRevision ?? "",
                descriptor: descriptor
            ) == [])
        }
    }

    @Test("Relay Auto Identity Waits For Resolved Transport")
    func relayAutoIdentityWaitsForResolvedTransport() {
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [], catalogModels: [],
            apiKey: "", apiKeyPreview: "", relayRequested: .init(transport: .auto)
        )
        #expect(CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
            provider: provider, resolvedFinalTransport: nil
        ) == nil)
        let responses = CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
            provider: provider, resolvedFinalTransport: "openai_responses"
        )
        let anthropic = CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
            provider: provider, resolvedFinalTransport: "anthropic_messages"
        )
        #expect(responses == "openai_responses")
        #expect(anthropic == "anthropic_messages")
        #expect(CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "model/a", finalTransport: responses ?? "", runtimeRevision: "runtime-r7"
        ).wireValue != CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "model/a", finalTransport: anthropic ?? "", runtimeRevision: "runtime-r7"
        ).wireValue)
    }

    @Test("Custom And Recipe Sources Remain Isolated")
    func customAndRecipeSourcesRemainIsolated() throws {
        let suite = "CapabilityRuntimeSourceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let current = identity()
        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: "gpt-5.4", source: .custom,
            owner: "generation", setting: "owner:generation",
            endpointFingerprint: nil, identity: current
        ))
        #expect(cache.customRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "generation", identity: current
        ) == ["owner:generation"])
        #expect(cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "generation",
            recipeRef: "fixture.generation.v1", identity: current
        ).isEmpty)

        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: "gpt-5.4", source: .providerRecipe,
            owner: "generation", recipeRef: "fixture.generation.v1", setting: "/temperature",
            endpointFingerprint: nil, identity: current
        ))
        #expect(cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "generation",
            recipeRef: "fixture.generation.v1", identity: current
        ) == ["/temperature"])
        #expect(cache.customRejectedPointers(
            providerKind: .openAI, modelID: "gpt-5.4", owner: "generation", identity: current
        ) == ["owner:generation"])
    }

    @Test("Deletion Clears Rejection And Prevents Preference Resurrection")
    func deletionClearsRejectionAndPreventsPreferenceResurrection() throws {
        let suite = "CapabilityDeletionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let current = identity(connectionID: "CONNECTION-A", modelID: "model/a")
        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: "model/a", source: .providerRecipe,
            owner: "web", recipeRef: "fixture.exact.web.v1", setting: "/web_search_options",
            endpointFingerprint: nil, identity: current
        ))
        cache.clearCapabilityRejections(connectionID: "CONNECTION-A")
        #expect(cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: "model/a", owner: "web",
            recipeRef: "fixture.exact.web.v1", identity: current
        ).isEmpty)

        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        let conversationID = UUID()
        let skillID = UUID()
        let wire = CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "model/a", finalTransport: "openai_responses",
            runtimeRevision: "runtime-r7"
        ).wireValue
        let value = CapabilityPreferenceValues(web: .automatic, reasoningIntent: "deep")
        store.setConnectionCapabilityPreferences(
            value, providerID: providerID, modelID: "model/a", transportIdentity: wire
        )
        store.setCapabilityPreferences(
            value, providerID: providerID, modelID: "model/a", conversationID: nil,
            transportIdentity: wire
        )
        store.setCapabilityPreferences(
            value, providerID: providerID, modelID: "model/a", conversationID: conversationID,
            transportIdentity: wire
        )
        store.setCapabilityPreferences(
            value, providerID: providerID, modelID: "model/a", conversationID: nil,
            skillID: skillID, transportIdentity: wire
        )
        let oldRemote = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(oldRemote.records.count == 4)

        store.removeCapabilityScopes(providerID: providerID)
        let deleted = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(deleted.records.isEmpty)
        #expect(deleted.tombstones?.count == 4)
        let merged = CapabilityPreferenceSyncContract.merge(oldRemote, settings: store)
        #expect(merged.records.isEmpty)
        #expect(merged.tombstones?.count == 4)
    }

    @Test("Shared Capability Sync Fixture Round Trips Production Store")
    func sharedCapabilitySyncFixtureRoundTripsProductionStore() throws {
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.findFile(
            components: ["shared", "model-contracts", "capability_preference_sync.v1.json"]
        ))) as? [String: Any])
        let payloadObject = try #require(fixture["payload"] as? [String: Any])
        let payload = try #require(CapabilityPreferenceSyncContract.decode(jsonObject: payloadObject))
        #expect(payload.schemaVersion == 2)
        #expect(payload.records.count == 4)

        let suite = "SharedCapabilitySyncV2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let merged = CapabilityPreferenceSyncContract.merge(payload, settings: store)
        #expect(merged.schemaVersion == payload.schemaVersion)
        #expect(merged.records.sorted { $0.recordId < $1.recordId }
            == payload.records.sorted { $0.recordId < $1.recordId })
        #expect((merged.tombstones ?? []).sorted { $0.recordId < $1.recordId }
            == (payload.tombstones ?? []).sorted { $0.recordId < $1.recordId })

        let providerID = try #require(UUID(uuidString: "9A1195DE-3AF9-5888-ABC8-B8177C458C07"))
        let connection = try #require(payload.records.first { $0.scope == "connection" })
        #expect(store.connectionCapabilityPreferences(
            providerID: providerID,
            modelID: try #require(connection.modelId),
            transportIdentity: connection.transportIdentity
        )?.web == .off)
        let model = try #require(payload.records.first { $0.scope == "connection_model" })
        #expect(store.capabilityPreferences(
            providerID: providerID, modelID: try #require(model.modelId), conversationID: nil,
            transportIdentity: model.transportIdentity
        )?.reasoningIntent == "off")
        let conversation = try #require(payload.records.first { $0.scope == "conversation_connection_model" })
        guard let conversationIDText = conversation.conversationId,
              let conversationID = UUID(uuidString: conversationIDText) else {
            Issue.record("Shared sync conversation scope must carry a valid conversationId")
            return
        }
        #expect(store.capabilityPreferences(
            providerID: providerID, modelID: try #require(conversation.modelId),
            conversationID: conversationID,
            transportIdentity: conversation.transportIdentity
        )?.web == .force)
        let skill = try #require(payload.records.first { $0.scope == "skill_agent" })
        guard let skillIDText = skill.skillId,
              let skillID = UUID(uuidString: skillIDText) else {
            Issue.record("Shared sync skill scope must carry a valid skillId")
            return
        }
        #expect(store.capabilityPreferences(
            providerID: providerID, modelID: try #require(skill.modelId), conversationID: nil,
            skillID: skillID,
            transportIdentity: skill.transportIdentity
        )?.reasoningIntent == "off")

        let cases = try #require(fixture["recordIdCases"] as? [[String: Any]])
        for item in cases {
            let encoded = CapabilityPreferenceRuntimeIdentity(
                canonicalModelID: try #require(item["canonicalModelId"] as? String),
                finalTransport: try #require(item["finalTransport"] as? String),
                runtimeRevision: try #require(item["runtimeRevision"] as? String)
            ).wireValue
            #expect(encoded == item["transportIdentity"] as? String)
        }
    }

    @Test("Legacy Capability Identity Remains Dormant Across Cold Start And Merge")
    func legacyCapabilityIdentityRemainsDormantAcrossColdStartAndMerge() throws {
        let suite = "LegacyCapabilityIdentity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providerID = UUID()
        let legacy = LegacyCapabilityRecord(
            scope: .connectionModel, providerID: providerID, modelID: "model/a",
            conversationID: nil, skillID: nil, transportIdentity: "openai_responses",
            values: .init(web: .automatic, reasoningIntent: "deep"), updatedAt: Date(),
            revision: 99, mutationID: "legacy-mutation"
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "capability_preference_settings.v1")

        let restored = GenerationParameterSettingsStore(defaults: defaults)
        let currentWire = CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: "model/a", finalTransport: "openai_responses",
            runtimeRevision: "runtime-r7"
        ).wireValue
        #expect(restored.capabilityPreferences(
            providerID: providerID, modelID: "model/a", conversationID: nil,
            transportIdentity: currentWire
        ) == nil)
        #expect(restored.capabilityPreferences(
            providerID: providerID, modelID: "model/a", conversationID: nil,
            transportIdentity: "openai_responses"
        ) == nil)

        _ = CapabilityPreferenceSyncContract.merge(
            .init(schemaVersion: 2, records: [], tombstones: nil), settings: restored
        )
        let retained = try JSONDecoder().decode(
            [LegacyCapabilityRecord].self,
            from: try #require(defaults.data(forKey: "capability_preference_settings.v1"))
        )
        #expect(retained.contains { $0.transportIdentity == "openai_responses" && $0.revision == 99 })
    }

    @Test("Shared Fixture Seven Scope Resolution")
    func sharedFixtureSevenScopeResolution() throws {
        let fixture = try Self.sharedRuntimeFixture()
        let cases = try #require(fixture["resolutionCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["caseId"] as? String == "seven_scopes_resolve_each_owner_independently" })
        let layers = try #require(item["layers"] as? [String: Any])
        let expected = try #require(item["expected"] as? [String: Any])
        let values: (String) -> CapabilityPreferenceValues? = { key in
            guard let layer = layers[key] as? [String: Any] else { return nil }
            let webRaw = layer["web"] as? String
            let web = webRaw.flatMap(CapabilityWebPreference.init(rawValue:)) ?? .inherit
            let reasoning = layer["reasoning"] as? String
            return .init(web: web, reasoningIntent: reasoning == "provider_default" ? nil : reasoning)
        }
        let resolved = CapabilityPreferenceValueResolver.resolve(
            singleSend: values("single_send"),
            conversation: values("conversation_connection_model"),
            skill: values("skill_agent"),
            connectionModel: values("connection_model"),
            connection: values("connection"),
            providerRecipe: values("provider_recipe"),
            providerDefault: values("provider_default")
        )
        #expect(resolved.web.rawValue == expected["web"] as? String)
        #expect(resolved.reasoningIntent == expected["reasoning"] as? String)

        let expectedGeneration = try #require(expected["generation"] as? [String: Any])
        let scopeKeys: [(RequestPreferenceScope, String)] = [
            (.singleSend, "single_send"),
            (.conversationConnectionModel, "conversation_connection_model"),
            (.skillAgent, "skill_agent"),
            (.connectionModel, "connection_model"),
            (.connection, "connection"),
            (.providerRecipe, "provider_recipe"),
            (.providerDefault, "provider_default"),
        ]
        for (parameter, expectedValue) in expectedGeneration {
            let resolvedParameter = RequestPreferenceResolver.resolve(layers: scopeKeys.map { scope, key in
                let generation = (layers[key] as? [String: Any])?["generation"] as? [String: Any]
                return RequestPreferenceLayer(
                    scope: scope,
                    override: generation?[parameter].map(Self.preferenceOverride) ?? .inherit
                )
            })
            #expect(Self.foundationValue(resolvedParameter.override) as? NSObject == expectedValue as? NSObject)
        }
    }

    @Test("Shared Fixture Exact Recipe Rejection And Resend")
    func sharedFixtureExactRecipeRejectionAndResend() throws {
        let shared = try Self.sharedExactRecipeRuntime()
        let tracker = CapabilityExecutionTracker()
        tracker.recordCompiledDelta(
            recipe: shared.recipe, runtime: shared.runtime, finalTransport: "openai_responses",
            deltaRootKeys: ["web_search_options", "include"],
            ownedPointers: Set(shared.recipe.requestOps.compactMap(\.pointer)),
            capabilityKeys: ["web_search"]
        )
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        let rejections = tracker.recordUpstreamRejection(statusCode: 400, errorData: shared.errorData)
        let rejection = try #require(rejections.first)
        #expect(rejections.count == 1)
        #expect(rejection.source == .providerRecipe)
        #expect(rejection.recipeRef == shared.recipe.id)
        #expect(rejection.locatedPointers == shared.expectedOmitted)
        let terminal = tracker.terminalResult()
        #expect(terminal.states["web"] == .rejected)
        let descriptor = try #require(terminal.recoveryDescriptors?.first)

        var initial: [String: Any] = [:]
        let first = CapabilityRecipeRequestCompiler.compile(
            recipe: shared.recipe, to: &initial, providerKind: "openAI",
            transport: "openai_responses", capability: "web", selectedIntent: nil
        )
        #expect(first.applied)
        for pointer in shared.expectedOmitted.union(shared.expectedPreserved) {
            #expect(Self.value(at: pointer, in: initial) != nil)
        }

        let requestIdentity = identity(modelID: "model/a", runtimeRevision: shared.runtime.revision)
        let suite = "SharedExactRecipeCache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        for pointer in rejection.locatedPointers {
            #expect(cache.markCapabilityRejected(
                providerKind: .openAI, modelID: requestIdentity.query.effectiveModelID,
                source: .providerRecipe, owner: rejection.owner, recipeRef: rejection.recipeRef,
                setting: pointer, capabilityKey: "web_search", endpointFingerprint: nil,
                identity: requestIdentity
            ))
        }
        let dormant = cache.recipeRejectedPointers(
            providerKind: .openAI, modelID: requestIdentity.query.effectiveModelID,
            owner: "web", recipeRef: shared.recipe.id, identity: requestIdentity
        )
        let normalDecision = CapabilityRecipeRequestCompiler.runtimeOwnedOmission(
            dormantPointers: dormant, source: .providerRecipe, owner: "web",
            recipeRef: shared.recipe.id, runtimeRevision: shared.runtime.revision,
            descriptor: nil
        )
        #expect(normalDecision == nil)
        let normalBody: [String: Any] = normalDecision == nil ? [:] : initial
        #expect(Self.canonicalJSON(normalBody) == Self.canonicalJSON(shared.expectedNormalBody))

        #expect(shared.oneRequestResendLatch)
        let explicitDecision = CapabilityRecipeResendContext.$recoveryDescriptor.withValue(descriptor) {
            CapabilityRecipeRequestCompiler.runtimeOwnedOmission(
                dormantPointers: dormant, source: .providerRecipe, owner: "web",
                recipeRef: shared.recipe.id, runtimeRevision: shared.runtime.revision,
                descriptor: CapabilityRecipeResendContext.recoveryDescriptor
            )
        }
        #expect(CapabilityRecipeResendContext.recoveryDescriptor == nil)
        var resend: [String: Any] = [:]
        let resent = CapabilityRecipeRequestCompiler.compile(
            recipe: shared.recipe, to: &resend, providerKind: "openAI",
            transport: "openai_responses", capability: "web", selectedIntent: nil,
            omittingPointers: try #require(explicitDecision)
        )
        #expect(resent.applied)
        for pointer in shared.expectedOmitted { #expect(Self.value(at: pointer, in: resend) == nil) }
        for pointer in shared.expectedPreserved { #expect(Self.value(at: pointer, in: resend) != nil) }
    }

    @Test("Final Pointer Ownership Is Source Isolated")
    func finalPointerOwnershipIsSourceIsolated() throws {
        let shared = try Self.sharedExactRecipeRuntime()

        let overlapping = CapabilityExecutionTracker()
        overlapping.freezeRuntimeEnvelope(shared.runtime, controls: [
            "web": .init(state: "auto_available", recipeRef: shared.recipe.id, reasonCode: nil, sourceRefs: nil, availableIntents: nil, customControlRefs: nil),
        ])
        overlapping.recordCompiledDelta(
            recipe: shared.recipe, runtime: shared.runtime, finalTransport: "openai_responses",
            deltaRootKeys: ["web_search_options", "include"],
            ownedPointers: ["/web_search_options", "/include"], capabilityKeys: ["web_search"]
        )
        overlapping.recordCustomDelta(
            owner: "web", pointers: ["/web_search_options"], finalTransport: "openai_responses"
        )
        overlapping.confirmFinalWireEncoded()
        overlapping.confirmRequestDispatched()
        let overlapRejections = overlapping.recordUpstreamRejection(
            statusCode: 400, errorData: shared.errorData
        )
        #expect(overlapRejections.map(\.source) == [.custom])

        let distinct = CapabilityExecutionTracker()
        distinct.freezeRuntimeEnvelope(shared.runtime, controls: [
            "web": .init(state: "auto_available", recipeRef: shared.recipe.id, reasonCode: nil, sourceRefs: nil, availableIntents: nil, customControlRefs: nil),
        ])
        distinct.recordCompiledDelta(
            recipe: shared.recipe, runtime: shared.runtime, finalTransport: "openai_responses",
            deltaRootKeys: ["web_search_options", "include"],
            ownedPointers: ["/web_search_options", "/include"], capabilityKeys: ["web_search"]
        )
        distinct.recordCustomDelta(owner: "web", pointers: ["/custom_only"], finalTransport: "openai_responses")
        distinct.confirmFinalWireEncoded()
        distinct.confirmRequestDispatched()
        let distinctRejections = distinct.recordUpstreamRejection(statusCode: 400, errorData: shared.errorData)
        #expect(distinctRejections.map(\.source) == [.providerRecipe])
    }

    @Test("Shared Fixture Exact Custom Rejection")
    func sharedFixtureExactCustomRejection() throws {
        let fixture = try Self.sharedRuntimeFixture()
        let cases = try #require(fixture["rejectionCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["caseId"] as? String == "custom_exact_400_offers_explicit_resend" })
        let owner = try #require(item["locatedOwner"] as? String)
        let pointersByOwner = try #require(item["customAppliedPointers"] as? [String: [String]])
        let expectedPointers = Set(try #require(pointersByOwner[owner]))
        let finalCases = try #require(fixture["finalBodyCases"] as? [[String: Any]])
        let exactBodyCase = try #require(finalCases.first { $0["caseId"] as? String == "exact_recipe_all_owners" })
        let preferences = try #require(exactBodyCase["preferences"] as? [String: Any])
        let rawFragment = try JSONSerialization.data(
            withJSONObject: try #require(preferences[owner] as? [String: Any])
        )
        let compiledDelta = try SafeCustomFragmentCompiler.compile(
            raw: String(decoding: rawFragment, as: UTF8.self),
            owner: owner,
            declaredOwners: Dictionary(uniqueKeysWithValues: expectedPointers.map { ($0, owner) })
        ).get()
        let pointers = Set(CapabilityRecipeExecution.redactedPointers(compiledDelta))
        #expect(pointers == expectedPointers)
        let error = try JSONSerialization.data(withJSONObject: try #require(item["error"]))
        let runtime = try Self.customRuntime(owner: owner, pointers: pointers)
        let recipe = try #require(runtime.recipes["fixture.custom.\(owner).v1"])
        let controls = [
            owner: MetadataClient.CapabilityControl(
                state: "auto_available", recipeRef: recipe.id, reasonCode: nil,
                sourceRefs: nil, availableIntents: nil, customControlRefs: nil
            ),
        ]
        let tracker = CapabilityExecutionTracker()
        tracker.freezeRuntimeEnvelope(runtime, controls: controls)
        tracker.recordCustomDelta(owner: owner, pointers: pointers, finalTransport: "openai_responses")
        tracker.confirmFinalWireEncoded()
        tracker.confirmRequestDispatched()
        let rejection = try #require(tracker.recordUpstreamRejection(statusCode: 400, errorData: error).first)
        #expect(rejection.source == .custom)
        #expect(rejection.owner == owner)
        #expect(rejection.locatedPointers == pointers)
        let descriptor = try #require(tracker.terminalResult().recoveryDescriptors?.first)

        let expected = try #require(item["expected"] as? [String: Any])
        let expectedNormal = try #require(expected["normalSendAutomaticFields"] as? [String: Any])
        let explicitResend = try #require(expected["explicitResend"] as? [String: Any])
        #expect(explicitResend["oneRequestResendLatch"] as? Bool == true)
        #expect(explicitResend["omitCustomFragmentIdentity"] as? String == "owner:\(owner)")
        let suite = "SharedCustomCache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UnsupportedParamCache(defaults: defaults)
        let current = identity(modelID: "model/a", runtimeRevision: descriptor.runtimeRevision)
        #expect(cache.markCapabilityRejected(
            providerKind: .openAI, modelID: current.query.effectiveModelID,
            source: .custom, owner: owner, setting: "owner:\(owner)",
            endpointFingerprint: nil, identity: current
        ))
        #expect(CapabilityRecoveryDescriptorValidation.validated(
            descriptor, providerKind: .openAI, identity: current, cache: cache
        ) == descriptor)
        let normalBody = CapabilityRecipeExecution.activeCustomDelta(
            compiledDelta, owner: owner, providerKind: .openAI,
            transport: "openai_responses", identity: current, cache: cache
        )
        #expect(Self.canonicalJSON(normalBody) == Self.canonicalJSON(expectedNormal))

        let mismatch = CapabilityExecutionTracker()
        mismatch.freezeRuntimeEnvelope(runtime, controls: controls)
        mismatch.recordCustomDelta(owner: owner, pointers: pointers, finalTransport: "openai_responses")
        mismatch.confirmFinalWireEncoded()
        mismatch.confirmRequestDispatched()
        #expect(mismatch.recordUpstreamRejection(
            statusCode: 400, errorData: Data(#"{"error":{"param":"top_p"}}"#.utf8)
        ).isEmpty)

        let ambiguousRuntime = try Self.customRuntime(owner: owner, pointers: pointers, secondOwner: "web")
        let ambiguous = CapabilityExecutionTracker()
        ambiguous.freezeRuntimeEnvelope(ambiguousRuntime, controls: [
            owner: .init(state: "auto_available", recipeRef: "fixture.custom.\(owner).v1", reasonCode: nil, sourceRefs: nil, availableIntents: nil, customControlRefs: nil),
            "web": .init(state: "auto_available", recipeRef: "fixture.custom.web.v1", reasonCode: nil, sourceRefs: nil, availableIntents: nil, customControlRefs: nil),
        ])
        ambiguous.recordCustomDelta(owner: owner, pointers: pointers, finalTransport: "openai_responses")
        ambiguous.recordCustomDelta(owner: "web", pointers: pointers, finalTransport: "openai_responses")
        ambiguous.confirmFinalWireEncoded()
        ambiguous.confirmRequestDispatched()
        #expect(ambiguous.recordUpstreamRejection(statusCode: 400, errorData: error).isEmpty)
    }

    @Test("Shared Fixture Production Parser Facts")
    func sharedFixtureProductionParserFacts() throws {
        let fixture = try Self.sharedRuntimeFixture()
        let cases = try #require(fixture["resultFactCases"] as? [[String: Any]])
        for item in cases where [
            "nonempty_citation_from_production_parser_is_observed",
            "nonempty_reasoning_from_production_parser_is_observed",
        ].contains(item["caseId"] as? String) {
            let expected = try #require(item["expected"] as? String)
            let event = try #require((item["events"] as? [[String: Any]])?.first)
            var context = StreamContext()
            let strategy = OpenAIResponsesStrategy()
            let producerEvent: CapabilityExecutionProducerEvent
            let nonEmpty: Bool
            if event["type"] as? String == "citations" {
                let url = try #require((((event["citations"] as? [[String: Any]])?.first)?["url"] as? String))
                _ = strategy.parseStreamLine(
                    #"data: {"type":"response.output_text.annotation.added","annotation":{"type":"url_citation","url":"\#(url)","title":"fixture","start_index":0,"end_index":1}}"#,
                    ctx: &context, shape: nil
                )
                producerEvent = .citations
                nonEmpty = !(context.citationsAccumulator.snapshot ?? []).isEmpty
            } else {
                let content = try #require(event["content"] as? String)
                let parsed = strategy.parseStreamLine(
                    #"data: {"type":"response.reasoning.delta","delta":"\#(content)"}"#,
                    ctx: &context, shape: nil
                )
                producerEvent = .reasoning
                nonEmpty = parsed.contains { if case let .reasoning(value) = $0 { return !value.isEmpty }; return false }
            }
            let classification = RequestPreferenceResolver.classifyResult(.init(
                wireApplied: true, providerAccepted: true,
                evidenceKinds: nonEmpty ? [producerEvent == .citations
                    ? RequestObservationEvidence.citation.rawValue
                    : RequestObservationEvidence.thinkingBlock.rawValue] : [],
                recovered: false
            ))
            #expect(classification.state.rawValue == expected)
        }
    }

    @Test("Shared Fixture Production Final Body")
    func sharedFixtureProductionFinalBody() async throws {
        UnsupportedParamCache.shared.resetForTesting()
        let fixture = try Self.sharedRuntimeFixture()
        let cases = try #require(fixture["finalBodyCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["caseId"] as? String == "exact_recipe_all_owners" })
        let runtimeIdentity = try #require(item["identity"] as? [String: String])
        let preferences = try #require(item["preferences"] as? [String: Any])
        let generation = try #require(preferences["generation"] as? [String: Any])
        let expectedBody = try #require(item["expectedFinalBody"] as? [String: Any])
        let expectedDispatch = try #require(item["expectedDispatch"] as? [String: Any])
        let modelID = try #require(runtimeIdentity["canonicalModelId"])
        let runtimeRevision = try #require(runtimeIdentity["runtimeRevision"])

        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try Self.productionMetadataJSON(modelID: modelID, runtimeRevision: runtimeRevision),
            metadataETag: runtimeRevision
        )
        defer { RequestShapeContractURLProtocol.requestHandler = nil }
        let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(
            modelID: modelID, providerKind: .openAI
        ))
        var options = ChatRequestOptions(
            generationParameters: .init(values: generation.compactMapValues { value in
                guard let number = value as? NSNumber else { return nil }
                return .init(state: .value, value: .number(number.doubleValue))
            }),
            generationProfile: resolved.generationProfile
        )
        options.capabilityPreferences = .init(
            web: CapabilityWebPreference(rawValue: preferences["web"] as? String ?? "") ?? .off,
            reasoningIntent: preferences["reasoning"] as? String
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestShapeContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        nonisolated(unsafe) var captured: URLRequest?
        RequestShapeContractURLProtocol.requestHandler = { request in
            captured = request
            return (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://fixture.invalid")!, statusCode: 400,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":{"param":"temperature"}}"#.utf8)
            )
        }
        nonisolated(unsafe) var requested = CapabilityExecutionResult.empty
        let tracker = CapabilityExecutionTracker { requested = $0 }
        let requestIdentity = identity(
            connectionID: runtimeIdentity["connectionId"] ?? "",
            modelID: modelID,
            transport: runtimeIdentity["finalTransport"] ?? "",
            runtimeRevision: runtimeRevision
        )
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .openAI,
            providerName: ProviderKind.openAI.displayName, modelName: modelID, state: .delivered
        )
        do {
            try await CapabilityEvidenceRequestContext.$current.withValue(requestIdentity) {
                try await CapabilityExecutionRuntime.$current.withValue(tracker) {
                    for try await _ in OpenAIService(session: session).sendMessageStream(
                        apiKey: "fixture-key", modelID: modelID, messages: [message],
                        reasoningMode: .deep, webSearchEnabled: true,
                        supportsImageGeneration: false, requestOptions: options
                    ) {}
                }
            }
        } catch {
            // The fixture response intentionally contains no SSE completion event. The captured
            // production request is the assertion target.
        }
        guard let request = captured else {
            Issue.record("Production OpenAI builder did not issue a request")
            return
        }
        let data = try #require(Self.requestBodyData(request))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Self.canonicalJSON(body) == Self.canonicalJSON(expectedBody))
        #expect(Set(requested.states.keys) == Set(expectedDispatch["requestedOwners"] as? [String] ?? []))
        let terminal = tracker.terminalResult()
        #expect(terminal.states["generation"] == .rejected)
        #expect(terminal.recoveryDescriptors?.first?.owner == "generation")
        #expect(terminal.recoveryDescriptors?.first?.locatedPointers == ["/temperature"])
        UnsupportedParamCache.shared.resetForTesting()
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Shared Fixture Unknown Runtime Plain Chat Body")
    func sharedFixtureUnknownRuntimePlainChatBody() async throws {
        let fixture = try Self.sharedRuntimeFixture()
        let cases = try #require(fixture["finalBodyCases"] as? [[String: Any]])
        let item = try #require(cases.first {
            $0["caseId"] as? String == "unknown_or_killed_runtime_plain_chat_remains_valid"
        })
        let identity = try #require(item["identity"] as? [String: String])
        let expectedBody = try #require(item["expectedFinalBody"] as? [String: Any])
        let modelID = try #require(identity["canonicalModelId"])
        let runtimeRevision = try #require(identity["runtimeRevision"])
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try Self.plainMetadataJSON(modelID: modelID, runtimeRevision: runtimeRevision),
            metadataETag: runtimeRevision
        )
        defer { RequestShapeContractURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestShapeContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        nonisolated(unsafe) var captured: URLRequest?
        RequestShapeContractURLProtocol.requestHandler = { request in
            captured = request
            return (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://fixture.invalid")!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
                )!, Data()
            )
        }
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .openAI,
            providerName: ProviderKind.openAI.displayName, modelName: modelID, state: .delivered
        )
        do {
            for try await _ in OpenAIService(session: session).sendMessageStream(
                apiKey: "fixture-key", modelID: modelID, messages: [message],
                reasoningMode: .max, webSearchEnabled: true,
                supportsImageGeneration: false, requestOptions: .init()
            ) {}
        } catch {}
        guard let request = captured else {
            Issue.record("Production OpenAI builder did not issue a request")
            return
        }
        guard let requestData = Self.requestBodyData(request) else {
            Issue.record("Production OpenAI request did not carry an HTTP body")
            return
        }
        guard let body = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            Issue.record("Production OpenAI request body was not a JSON object")
            return
        }
        #expect(Self.canonicalJSON(body) == Self.canonicalJSON(expectedBody))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Reasoning Intent Round Trip")
    func reasoningIntentRoundTrip() {
        #expect(ReasoningMode.fromIntent("low") == .fast)
        #expect(ReasoningMode.fast.intentToken == "low")
        #expect(ReasoningMode.fromIntent("off") == nil)
        #expect(ReasoningMode.fromIntent("automatic") == nil)
        #expect(ReasoningMode.fromIntent(nil) == nil)
        for mode in ReasoningMode.allCases where mode != .automatic {
            #expect(ReasoningMode.fromIntent(mode.intentToken) == mode)
        }
        #expect(CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(
            capability: .reasoning, selectedIntent: "low"
        ) == ["reasoning_level/fast"])
        #expect(CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(
            capability: .web, selectedIntent: "force"
        ) == ["web_search"])
    }

    private static func sharedRuntimeFixture() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: findFile(
            components: ["shared", "model-contracts", "model_control_runtime.v1.json"]
        ))) as? [String: Any])
    }

    private struct LegacyCapabilityRecord: Codable {
        let scope: CapabilityPreferenceScope
        let providerID: UUID
        let modelID: String
        let conversationID: UUID?
        let skillID: UUID?
        let transportIdentity: String
        let values: CapabilityPreferenceValues
        let updatedAt: Date
        let revision: Int
        let mutationID: String
    }

    nonisolated private static func preferenceOverride(_ value: Any) -> RequestPreferenceOverride {
        if let string = value as? String {
            return string == "inherit" ? .inherit : .value(.string(string))
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" { return .value(.bool(number.boolValue)) }
            let double = number.doubleValue
            return double.rounded() == double ? .value(.int(number.intValue)) : .value(.double(double))
        }
        return .inherit
    }

    private static func foundationValue(_ value: RequestPreferenceOverride) -> Any? {
        guard case .value(let value) = value else { return nil }
        func convert(_ value: RequestPreferenceJSONValue) -> Any {
            switch value {
            case .null: return NSNull()
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .array(let values): return values.map(convert)
            case .object(let values): return values.mapValues(convert)
            }
        }
        return convert(value)
    }

    private static func value(at pointer: String, in root: Any) -> Any? {
        guard pointer.first == "/" else { return nil }
        let segments = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
        var current: Any = root
        for segment in segments {
            if let object = current as? [String: Any], let next = object[segment] {
                current = next
            } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private static func sharedExactRecipeRuntime() throws -> (
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        recipe: MetadataClient.CapabilityRecipe,
        errorData: Data,
        expectedNormalBody: [String: Any],
        oneRequestResendLatch: Bool,
        expectedOmitted: Set<String>,
        expectedPreserved: Set<String>
    ) {
        let fixture = try sharedRuntimeFixture()
        let cases = try #require(fixture["rejectionCases"] as? [[String: Any]])
        let item = try #require(cases.first {
            $0["caseId"] as? String == "structured_exact_recipe_locator_offers_explicit_resend"
        })
        var recipeObject = try #require(item["recipe"] as? [String: Any])
        let recipeRef = try #require(recipeObject["recipeRef"] as? String)
        let recoveryRef = try #require(recipeObject["errorRecoveryRef"] as? String)
        let protocolName = try #require(recipeObject["protocol"] as? String)
        let evidenceRef = "\(recipeRef).response-evidence"
        recipeObject["id"] = recipeRef
        recipeObject["providerKind"] = "openAI"
        recipeObject["transport"] = ["protocol": protocolName]
        recipeObject["executionKind"] = "request_overlay"
        recipeObject["responseEvidenceRef"] = evidenceRef
        recipeObject["errorRecoveryRef"] = recoveryRef
        let recovery = try #require(item["errorRecoveryDefinition"] as? [String: Any])
        let responseEvidence: [String: Any] = [
            "capability": recipeObject["capability"] ?? "web",
            "protocol": protocolName,
            "responseParserKind": recipeObject["responseParserKind"] ?? "fixture_web_v1",
            "signals": [[
                "kind": "citation", "producerEvent": "citations",
                "pointer": "/citations", "nonEmpty": true,
            ]],
        ]
        let envelopeObject: [String: Any] = [
            "schemaVersion": 2,
            "revision": "runtime-r7",
            "generatedAt": "2026-08-14T00:00:00Z",
            "recipes": [recipeRef: recipeObject],
            "controlDefinitions": [:],
            "sourceIndex": [:],
            "responseEvidenceDefinitions": [evidenceRef: responseEvidence],
            "errorRecoveryDefinitions": [recoveryRef: recovery],
        ]
        let runtime = try JSONDecoder().decode(
            MetadataClient.CapabilityRuntimeEnvelope.self,
            from: JSONSerialization.data(withJSONObject: envelopeObject)
        )
        let expected = try #require(item["expected"] as? [String: Any])
        let explicitResend = try #require(expected["explicitResend"] as? [String: Any])
        let error = try #require(item["error"])
        return (
            runtime,
            try #require(runtime.recipes[recipeRef]),
            try JSONSerialization.data(withJSONObject: error),
            try #require(expected["normalSendAutomaticFields"] as? [String: Any]),
            explicitResend["oneRequestResendLatch"] as? Bool == true,
            Set(explicitResend["omittedPointers"] as? [String] ?? []),
            Set(explicitResend["preservedPointers"] as? [String] ?? [])
        )
    }

    private static func customRuntime(
        owner: String,
        pointers: Set<String>,
        secondOwner: String? = nil
    ) throws -> MetadataClient.CapabilityRuntimeEnvelope {
        var recipes: [String: Any] = [:]
        var evidence: [String: Any] = [:]
        for currentOwner in [owner, secondOwner].compactMap({ $0 }) {
            let recipeRef = "fixture.custom.\(currentOwner).v1"
            let evidenceRef = "\(recipeRef).evidence"
            recipes[recipeRef] = [
                "id": recipeRef,
                "providerKind": "openAI",
                "transport": ["protocol": "openai_responses"],
                "capability": currentOwner,
                "executionKind": "request_overlay",
                "requestOps": pointers.map { ["op": "set", "pointer": $0, "value": true] },
                "responseParserKind": "fixture_\(currentOwner)_v1",
                "responseEvidenceRef": evidenceRef,
            ]
            evidence[evidenceRef] = [
                "capability": currentOwner,
                "protocol": "openai_responses",
                "responseParserKind": "fixture_\(currentOwner)_v1",
                "signals": [],
            ]
        }
        let envelope: [String: Any] = [
            "schemaVersion": 2,
            "revision": "runtime-r7",
            "generatedAt": "2026-08-14T00:00:00Z",
            "recipes": recipes,
            "controlDefinitions": [:],
            "sourceIndex": [:],
            "responseEvidenceDefinitions": evidence,
            "errorRecoveryDefinitions": [:],
        ]
        return try JSONDecoder().decode(
            MetadataClient.CapabilityRuntimeEnvelope.self,
            from: JSONSerialization.data(withJSONObject: envelope)
        )
    }

    private static func productionMetadataJSON(modelID: String, runtimeRevision: String) throws -> String {
        let runtimeData = try JSONEncoder().encode(runtimeEnvelope())
        var runtime = try #require(JSONSerialization.jsonObject(with: runtimeData) as? [String: Any])
        runtime["revision"] = runtimeRevision
        var recoveryDefinitions = runtime["errorRecoveryDefinitions"] as? [String: Any] ?? [:]
        recoveryDefinitions["openai.responses.generation"] = [
            "capability": "generation",
            "protocol": "openai_responses",
            "responseParserKind": "openai_responses_generation_v1",
            "locatorRules": [[
                "status": 400,
                "owner": "generation",
                "pointers": ["/temperature"],
                "errorFields": ["/error/param": "temperature"],
            ]],
        ]
        runtime["errorRecoveryDefinitions"] = recoveryDefinitions
        let generationProfile: [String: Any] = [
            "version": 1,
            "parameters": [
                "temperature": [
                    "id": "temperature", "group": "sampling", "valueSchema": "number",
                    "range": ["min": 0, "max": 2], "support": "supported",
                    "source": "authoritative_metadata",
                ],
            ],
            "templates": [
                "openai_responses": [
                    "transport": "openai_responses", "wire": ["temperature": "temperature"],
                ],
            ],
        ]
        let document: [String: Any] = [
            "version": 1,
            "profiles": ["generation": generationProfile],
            "providers": [
                "openAI": [
                    "resolveMap": [modelID: modelID],
                    "models": [modelID: [
                        "canonicalModelId": modelID,
                        "transport": "openai_responses",
                        "profiles": ["generation": [
                            "template": "openai_responses", "revision": runtimeRevision,
                            "parameters": [[
                                "id": "temperature", "support": "supported",
                                "source": "authoritative_metadata",
                            ]],
                        ]],
                        "capabilityControls": [
                            "web": ["state": "auto_available", "recipeRef": "openai.responses.web.v1"],
                            "reasoning": [
                                "state": "auto_available", "recipeRef": "openai.responses.reasoning.v1",
                                "availableIntents": ["low", "balanced", "deep", "max"],
                            ],
                            "generation": ["state": "auto_available", "recipeRef": "openai.responses.generation.v1"],
                        ],
                    ]],
                ],
            ],
            "capabilityRuntime": runtime,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func plainMetadataJSON(modelID: String, runtimeRevision: String) throws -> String {
        let document: [String: Any] = [
            "version": 1,
            "providers": [
                "openAI": [
                    "resolveMap": [modelID: modelID],
                    "models": [modelID: [
                        "canonicalModelId": modelID,
                        "transport": "openai_responses",
                        "capabilityControls": [
                            "web": ["state": "unknown", "reasonCode": "kill"],
                            "reasoning": ["state": "unknown", "reasonCode": "kill"],
                            "generation": ["state": "unknown", "reasonCode": "kill"],
                        ],
                    ]],
                ],
            ],
            "capabilityRuntime": [
                "schemaVersion": 2,
                "revision": runtimeRevision,
                "generatedAt": "2026-08-14T00:00:00Z",
                "recipes": [:],
                "controlDefinitions": [:],
                "sourceIndex": [:],
                "responseEvidenceDefinitions": [:],
                "errorRecoveryDefinitions": [:],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private static func canonicalJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "<invalid>"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func runtimeEnvelope() throws -> MetadataClient.CapabilityRuntimeEnvelope {
        let base = ["shared", "capabilityrecipe"]
        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: findFile(components: base + ["capability_runtime.v1.json"]))
        ) as? [String: Any] ?? [:]
        let results = try JSONSerialization.jsonObject(
            with: Data(contentsOf: findFile(components: base + ["capability_result_definitions.v1.json"]))
        ) as? [String: Any] ?? [:]
        let bindings = results["recipeBindings"] as? [String: [String: String]] ?? [:]
        var recipes = registry["recipes"] as? [String: [String: Any]] ?? [:]
        for (id, binding) in bindings {
            guard var recipe = recipes[id] else { continue }
            recipe["responseEvidenceRef"] = binding["responseEvidenceRef"]
            recipe["errorRecoveryRef"] = binding["errorRecoveryRef"]
            recipes[id] = recipe
        }
        var recoveryDefinitions: [String: Any] = [:]
        if let ref = bindings["openai.responses.web.v1"]?["errorRecoveryRef"],
           let evidence = (results["responseEvidenceDefinitions"] as? [String: [String: Any]])?[ref] {
            var recovery = evidence
            recovery["locatorRules"] = [[
                "status": 400,
                "owner": "web",
                "pointers": ["/tools/-"],
                "errorFields": ["/error/param": "tools"],
            ]]
            recoveryDefinitions[ref] = recovery
        }
        let envelope: [String: Any] = [
            "schemaVersion": 2,
            "revision": "d1-runtime",
            "generatedAt": "2026-08-13T00:00:00Z",
            "recipes": recipes,
            "controlDefinitions": registry["controlDefinitions"] ?? [:],
            "sourceIndex": registry["sourceIndex"] ?? [:],
            "responseEvidenceDefinitions": results["responseEvidenceDefinitions"] ?? [:],
            "errorRecoveryDefinitions": recoveryDefinitions,
        ]
        return try JSONDecoder().decode(
            MetadataClient.CapabilityRuntimeEnvelope.self,
            from: JSONSerialization.data(withJSONObject: envelope)
        )
    }

    private static func findFile(components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        preconditionFailure("Unable to locate \(components.joined(separator: "/"))")
    }
}
