import Foundation
import Testing
@testable import Oriveo

@Suite("Generation parameter value lifecycle", .serialized)
struct GenerationParameterLifecycleTests {
    private static let metadataRevision = "etag-lifecycle"
    private static let generationRevision = "generation-lifecycle"


    @Test("Fixture Coverage Is Locked")
    func fixtureCoverageIsLocked() throws {
        let contract = try Self.loadContract()
        #expect(contract.lifecycleCases.count >= 17)
        let ids = contract.lifecycleCases.map(\.caseId)
        #expect(Set(ids).count == ids.count)
        let caseIDs = Set(ids)
        for required in [
            "official.declared.unknown",
            "official.declared.accepted",
            "official.declared.accepted_unverified",
            "official.declared.unsupported",
            "official.declared.fixed",
            "official.declared.mode_dependent",
        ] {
            #expect(caseIDs.contains(required))
        }
        for (caseId, lifecycle) in [
            ("official.declared.unknown", "active"),
            ("official.declared.accepted", "active"),
            ("official.declared.accepted_unverified", "active"),
            ("official.declared.unsupported", "dormant"),
            ("official.declared.fixed", "dormant"),
            ("official.declared.mode_dependent", "dormant"),
        ] {
            #expect(
                contract.lifecycleCases.first { $0.caseId == caseId }?.expect.lifecycle == lifecycle,
                "\(caseId) expected value changed; revisit decision D1-d③ before changing the contract"
            )
        }
        #expect(contract.lifecycleCases.contains { !$0.intent.declared })
        #expect(contract.lifecycleCases.contains { $0.intent.wire == nil })
        #expect(contract.lifecycleCases.contains { $0.intent.storedState == "omit" })
        #expect(Set(contract.lifecycleCases.map(\.expect.lifecycle)) == ["active", "dormant"])
        #expect(
            Set(contract.lifecycleCases.compactMap(\.intent.support)).contains("supported"),
            "fixture must cover the supported verdict that the production projection admits"
        )
    }

    @Test("Cases Match Production Verdict")
    func casesMatchProductionVerdict() async throws {
        let contract = try Self.loadContract()

        for item in contract.lifecycleCases {
            let hasExplicitIntent = item.intent.storedState != "inherit"
            let profile = try await Self.profileFromProductionMetadata(for: item)
            let provider = Self.provider(
                kind: item.intent.providerKind,
                relayTransport: item.caseId == "relay.undeclared_after_transport_correction"
                    ? .openaiResponses
                    : .openaiChatCompletions
            )
            let model = Self.model(profile: profile)
            let identity = Self.identity(
                provider: provider,
                model: model,
                hasExplicitValue: hasExplicitIntent
            )

            let active = GenerationParameterLifecycle.activeParameterIDs(
                provider: provider,
                model: model,
                identity: identity,
                explicitParameterIDs: hasExplicitIntent ? [item.intent.parameterId] : []
            )
            let expectedActive = item.expect.lifecycle == "active"
            #expect(
                active.contains(item.intent.parameterId) == expectedActive,
                "\(item.caseId): activeParameterIDs disagrees with the contract"
            )

            let override = item.intent.storedState == "omit"
                ? GenerationParameterOverride(state: .omit)
                : GenerationParameterOverride(state: .value, value: .number(0.4))
            let split = GenerationParameterLifecycle.partition(
                provider: provider,
                model: model,
                values: .init(values: [item.intent.parameterId: override]),
                identity: identity
            )
            #expect(split.dormantIDs.contains(item.intent.parameterId) == !expectedActive, "\(item.caseId): partition")
            #expect((split.active.values[item.intent.parameterId] != nil) == expectedActive)
        }

        await MetadataClient.shared.resetForTesting()
    }

    /// (`ProfileParamsResolver.applyGenerationParameters` → `permitsOutbound`),
    @Test("Official Unknown With Explicit Value Reaches The Body")
    func officialUnknownWithExplicitValueReachesTheBody() async throws {
        let profile = try await Self.profileFromProductionMetadata(parameters: [
            (id: "temperature", support: "unknown", wire: "temperature"),
        ], generationRecipeRef: "openrouter.chat.generation.v1")
        let provider = Self.provider(kind: "official")
        let model = Self.model(profile: profile)

        #expect(GenerationParameterLifecycle.activeParameterIDs(
            provider: provider, model: model, explicitParameterIDs: ["temperature"]
        ).contains("temperature"))

        let body = try Self.officialBody(profile: profile, model: model, transport: "openai_chat")
        #expect(body["temperature"] as? Double == 0.4)

        #expect(!CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, explicitParameterIDs: []
        ).permitsOutbound("temperature"), "Admitted without an explicit intent — the outbound gate did not judge")

        await MetadataClient.shared.resetForTesting()
    }

    @Test(
        "D1-d③ reverse assertion: the four official-denied states still do not go outbound when set explicitly",
        arguments: ["unsupported", "fixed", "mode_dependent", "future_supported"]
    )
    func officialNegativeSupportsStayDormantEvenWhenExplicit(_ support: String) async throws {
        let profile = try await Self.profileFromProductionMetadata(parameters: [
            (id: "temperature", support: support, wire: "temperature"),
        ])
        let provider = Self.provider(kind: "official")
        let model = Self.model(profile: profile)

        #expect(!GenerationParameterLifecycle.activeParameterIDs(
            provider: provider, model: model, explicitParameterIDs: ["temperature"]
        ).contains("temperature"), "\(support) was judged active — admitting was implemented as always-true")

        let body = try Self.officialBody(profile: profile, model: model)
        #expect(body["temperature"] == nil)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("relay unknown omit removes a field through the production chat encoder")
    func relayUnknownOmitReachesProductionBody() async throws {
        let contract = try Self.loadContract()
        let item = try #require(contract.lifecycleCases.first { $0.caseId == "relay.declared.unknown_omit" })
        #expect(item.intent.storedState == "omit")
        #expect(item.intent.support == "unknown")
        #expect(item.expect.lifecycle == "active")

        let profile = try await Self.profileFromProductionMetadata(for: item)
        let provider = Self.provider(kind: "relay")
        let model = Self.model(profile: profile)
        let identity = try #require(Self.identity(provider: provider, model: model, hasExplicitValue: false))
        var body: [String: Any] = ["model": Self.modelID, "temperature": 0.7]
        let request = URLRequest(url: URL(string: "https://relay.test/v1/chat/completions")!)
        CapabilityEvidenceRequestContext.$current.withValue(identity) {
            #expect(ProfileParamsResolver.applyGenerationParameters(
                to: &body,
                options: ChatRequestOptions(
                    generationParameters: .init(values: ["temperature": .init(state: .omit)]),
                    generationProfile: profile,
                    relayRequested: provider.relayRequested
                ),
                finalRequest: request,
                effectiveTransport: RelayTransport.openaiChatCompletions.rawValue
            ))
        }
        #expect(body["temperature"] == nil)

        await MetadataClient.shared.resetForTesting()
    }


    @Test("Revalidation Is Per Parameter Not Per Record")
    func revalidationIsPerParameterNotPerRecord() async throws {
        let suiteName = "generation-parameter-lifecycle-d24-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        let conversationID = UUID()

        let before = try await Self.profileFromProductionMetadata(parameters: [
            (id: "temperature", support: "supported", wire: "temperature"),
            (id: "top_p", support: "supported", wire: "top_p"),
        ])
        store.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.4)),
            "top_p": .init(state: .value, value: .number(0.8)),
        ]), providerID: providerID, modelID: Self.modelID, profileFingerprint: "before|openai_chat_completions")
        let providerBefore = Self.provider(kind: "official", id: providerID)
        #expect(GenerationParameterLifecycle.activeParameterIDs(
            provider: providerBefore,
            model: Self.model(profile: before)
        ) == ["temperature", "top_p"])

        let after = try await Self.profileFromProductionMetadata(parameters: [
            (id: "temperature", support: "supported", wire: "temperature"),
        ])
        let modelAfter = Self.model(profile: after)
        let stored = try #require(
            store.modelDefaults(
                providerID: providerID,
                modelID: Self.modelID,
                profileFingerprint: "after|anthropic_messages"
            ),
            "Changing the fingerprint made the whole record unreadable, which loses every value at once and leaves orphaned records behind"
        )
        #expect(stored.values.count == 2)

        let split = GenerationParameterLifecycle.partition(
            provider: providerBefore,
            model: modelAfter,
            values: stored
        )
        #expect(split.dormantIDs == ["top_p"])
        #expect(split.active.values["temperature"]?.value == .number(0.4))

        let active = GenerationParameterLifecycle.activeParameterIDs(provider: providerBefore, model: modelAfter)
        let resolved = store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: Self.modelID,
            conversationID: conversationID,
            profileFingerprint: "after|anthropic_messages",
            activeParameterIDs: active
        )
        #expect(resolved?.values["temperature"]?.value == .number(0.4))
        #expect(resolved?.values["top_p"] == nil)

        let withTransient = store.resolve(
            transient: .init(values: ["top_p": .init(state: .value, value: .number(0.1))]),
            providerID: providerID,
            modelID: Self.modelID,
            conversationID: conversationID,
            profileFingerprint: "after|anthropic_messages",
            activeParameterIDs: active
        )
        #expect(withTransient?.values["top_p"]?.value == .number(0.1))

        let restored = try await Self.profileFromProductionMetadata(parameters: [
            (id: "temperature", support: "supported", wire: "temperature"),
            (id: "top_p", support: "supported", wire: "top_p"),
        ])
        let modelRestored = Self.model(profile: restored)
        #expect(GenerationParameterLifecycle.partition(
            provider: providerBefore,
            model: modelRestored,
            values: stored
        ).dormantIDs.isEmpty)
        #expect(store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: Self.modelID,
            conversationID: conversationID,
            profileFingerprint: "restored|openai_chat_completions",
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: providerBefore,
                model: modelRestored
            )
        )?.values["top_p"]?.value == .number(0.8))

        await MetadataClient.shared.resetForTesting()
    }


    @Test("Transport Correction Migrates Instead Of Orphaning")
    func transportCorrectionMigratesInsteadOfOrphaning() throws {
        let suiteName = "generation-parameter-lifecycle-c6-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = UUID()

        let requested = Self.relayProvider(id: providerID, transport: .openaiChatCompletions)
        let corrected = Self.relayProvider(id: providerID, transport: .anthropicMessages)
        let model = requested.models[0]
        let fingerprintBefore = GenerationParameterProfileFingerprint.make(provider: requested, model: model)
        let fingerprintAfter = GenerationParameterProfileFingerprint.make(provider: corrected, model: model)
        #expect(fingerprintBefore != fingerprintAfter)

        store.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.4)),
            "frequency_penalty": .init(state: .value, value: .number(0.5)),
        ]), providerID: providerID, modelID: model.id, profileFingerprint: fingerprintBefore)

        let stored = try #require(
            store.modelDefaults(providerID: providerID, modelID: model.id, profileFingerprint: fingerprintAfter),
            "the record became unreadable after the transport was corrected, which silently orphans it"
        )
        let correctedIdentity = try #require(Self.identity(provider: corrected, model: model, hasExplicitValue: true))
        let split = GenerationParameterLifecycle.partition(
            provider: corrected, model: model, values: stored, identity: correctedIdentity
        )
        #expect(split.dormantIDs == ["frequency_penalty"])
        #expect(split.active.values["temperature"]?.value == .number(0.4))

        let profile = try #require(GenerationParameterAvailability.profile(
            provider: corrected, model: model, identity: correctedIdentity
        ))
        let resolved = try #require(store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: model.id,
            conversationID: UUID(),
            profileFingerprint: fingerprintAfter,
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: corrected, model: model, identity: correctedIdentity,
                explicitParameterIDs: ["temperature", "frequency_penalty"]
            )
        ))
        var body: [String: Any] = ["model": model.id]
        let applied = CapabilityEvidenceRequestContext.$current.withValue(correctedIdentity) {
            ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: ChatRequestOptions(
                generationParameters: resolved,
                generationProfile: profile,
                relayRequested: corrected.relayRequested
            ),
            finalRequest: URLRequest(url: URL(string: "https://relay.test/v1/messages")!),
            effectiveTransport: RelayTransport.anthropicMessages.rawValue
        ) }
        #expect(applied)
        #expect(body["temperature"] as? Double == 0.4)
        #expect(body["frequency_penalty"] == nil)

        store.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.9)),
            "frequency_penalty": .init(state: .value, value: .number(0.5)),
        ]), providerID: providerID, modelID: model.id, profileFingerprint: fingerprintAfter)
        let payload = GenerationParameterSyncContract.exportPayload(
            settings: store, presets: presets, defaults: defaults
        )
        #expect(payload.records.count == 1)
        #expect(store.modelDefaults(
            providerID: providerID,
            modelID: model.id,
            profileFingerprint: fingerprintBefore
        )?.values["temperature"]?.value == .number(0.9))

        #expect(payload.schemaVersion == 1)
        #expect(payload.records[0].values["frequency_penalty"]?.value == .number(0.5))
    }


    @Test("Presets Are Field Wise Not Fingerprint Bound")
    func presetsAreFieldWiseNotFingerprintBound() throws {
        let suiteName = "generation-parameter-preset-d35-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let presets = GenerationParameterPresetStore(defaults: defaults)
        let providerID = UUID()

        let requested = Self.relayProvider(id: providerID, transport: .openaiChatCompletions)
        let corrected = Self.relayProvider(id: providerID, transport: .anthropicMessages)
        let model = requested.models[0]
        let fingerprintBefore = GenerationParameterProfileFingerprint.make(provider: requested, model: model)
        let fingerprintAfter = GenerationParameterProfileFingerprint.make(provider: corrected, model: model)
        #expect(fingerprintBefore != fingerprintAfter)

        store.setModelDefaults(.init(values: [
            "temperature": .init(state: .value, value: .number(0.4)),
            "frequency_penalty": .init(state: .value, value: .number(0.5)),
        ]), providerID: providerID, modelID: model.id, profileFingerprint: fingerprintBefore)
        let panelValues = try #require(
            store.modelDefaults(providerID: providerID, modelID: model.id, profileFingerprint: fingerprintAfter)
        )
        #expect(
            GenerationParameterLifecycle.partition(
                provider: corrected,
                model: model,
                values: panelValues,
                identity: try #require(Self.identity(provider: corrected, model: model, hasExplicitValue: true))
            ).dormantIDs
                == ["frequency_penalty"]
        )

        let preset = presets.save(
            name: "Precise",
            providerID: providerID,
            modelID: model.id,
            profileFingerprint: fingerprintAfter,
            values: panelValues
        )
        #expect(
            preset.values.values["frequency_penalty"]?.value == .number(0.5),
            "Clipping a preset by this device's dormant judgment = device A's profile turns off a sendable value for device B"
        )

        #expect(
            presets.list(providerID: providerID, modelID: model.id, profileFingerprint: fingerprintBefore).map(\.id)
                == [preset.id]
        )
        let applied = try #require(
            presets.apply(preset, providerID: providerID, modelID: model.id, profileFingerprint: fingerprintBefore)
        )
        store.setModelDefaults(applied, providerID: providerID, modelID: model.id, profileFingerprint: fingerprintBefore)

        let requestedIdentity = try #require(Self.identity(provider: requested, model: model, hasExplicitValue: true))
        let profile = try #require(GenerationParameterAvailability.profile(
            provider: requested, model: model, identity: requestedIdentity
        ))
        let resolved = try #require(store.resolve(
            transient: nil,
            providerID: providerID,
            modelID: model.id,
            conversationID: UUID(),
            profileFingerprint: fingerprintBefore,
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: requested, model: model, identity: requestedIdentity,
                explicitParameterIDs: ["temperature", "frequency_penalty"]
            )
        ))
        var body: [String: Any] = ["model": model.id]
        #expect(CapabilityEvidenceRequestContext.$current.withValue(requestedIdentity) {
            ProfileParamsResolver.applyGenerationParameters(
            to: &body,
            options: ChatRequestOptions(
                generationParameters: resolved,
                generationProfile: profile,
                relayRequested: requested.relayRequested
            ),
            finalRequest: URLRequest(url: URL(string: "https://relay.test/v1/chat/completions")!),
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue
        ) })
        #expect(body["frequency_penalty"] as? Double == 0.5)

        #expect(presets.apply(
            preset,
            providerID: providerID,
            modelID: "another-model",
            profileFingerprint: fingerprintBefore
        ) == nil)
        #expect(presets.list(
            providerID: providerID,
            modelID: "another-model",
            profileFingerprint: fingerprintBefore,
            portableParameterIDs: ["top_p"]
        ).isEmpty)

        #expect(try Self.loadContract().lifecycleRules.presets.count >= 4)
    }


    @Test("Summary Copy Carries No Implementation Words")
    func summaryCopyCarriesNoImplementationWords() throws {
        let table = try Self.loadStringsTable("Providers")
        // The escaped entries are the CJK words for "dormant" and "frozen"; escapes keep this file free of ideographs.
        let banned = ["dormant", "\u{4F11}\u{7720}", "\u{51BB}\u{7ED3}", "\u{51CD}\u{7D50}", "inactive"]
        let formatted = [
            "%d parameters you set are kept and won't be sent right now.",
            "Restored %d parameters",
        ]
        for key in formatted + ["View"] {
            let localizations = try #require(table[key], "missing key: \(key)")
            #expect(localizations.count == 16)
            for (language, value) in localizations {
                #expect(!value.isEmpty)
                for word in banned {
                    #expect(
                        value.range(of: word, options: .caseInsensitive) == nil,
                        "\(key)/\(language) contains implementation word '\(word)'"
                    )
                }
                if formatted.contains(key) {
                    #expect(value.contains("%d"))
                    #expect(!value.contains("{count}"))
                }
            }
        }
        #expect(try Self.loadStringsTable("Localizable")["Clear"]?.count == 16)
    }

    // MARK: - Fixtures

    private static let modelID = "lifecycle-model"

    private static func provider(
        kind: String,
        id: UUID = UUID(),
        relayTransport: RelayTransport = .openaiChatCompletions
    ) -> Provider {
        Provider(
            id: id,
            kind: kind == "relay" ? .relay : .openRouter,
            status: .connected,
            models: [],
            catalogModels: [],
            apiKey: "key",
            apiKeyPreview: "...key",
            baseURLText: kind == "relay" ? "https://relay.test/v1" : nil,
            relayRequested: kind == "relay" ? RelayRequestedConfig(transport: relayTransport) : nil
        )
    }

    private static func relayProvider(id: UUID, transport: RelayTransport) -> Provider {
        Provider(
            id: id,
            kind: .relay,
            status: .connected,
            models: [model(profile: nil)],
            catalogModels: [],
            apiKey: "key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
    }

    private static func model(profile: GenerationProfileRef?) -> AIModel {
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.generationProfile = profile
        return model
    }

    private static func profileFromProductionMetadata(
        for item: LifecycleContract.Case
    ) async throws -> GenerationProfileRef {
        let parameters: [(id: String, support: String, wire: String?)] = item.intent.declared
            ? [(id: item.intent.parameterId, support: item.intent.support ?? "unknown", wire: item.intent.wire)]
            : [(id: "stop", support: "supported", wire: "stop")]
        return try await profileFromProductionMetadata(parameters: parameters)
    }

    private static func profileFromProductionMetadata(
        parameters: [(id: String, support: String, wire: String?)],
        generationRecipeRef: String? = nil
    ) async throws -> GenerationProfileRef {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try metadataJSON(parameters: parameters, generationRecipeRef: generationRecipeRef),
            metadataETag: metadataRevision
        )
        let resolved = await MetadataClient.shared.resolveCatalogModel(modelID: modelID, providerKind: .openRouter)
        return try #require(resolved?.generationProfile, "The production resolve chain did not produce a profile")
    }

    private static func metadataJSON(
        parameters: [(id: String, support: String, wire: String?)],
        generationRecipeRef: String? = nil
    ) throws -> String {
        var wireEntries = parameters.compactMap { item in
            item.wire.map { #""\#(item.id)": "\#($0)""# }
        }
        if wireEntries.isEmpty { wireEntries = [#""stop": "stop""#] }
        let declared = parameters.map {
            #"{"id": "\#($0.id)", "support": "\#($0.support)", "source": "authoritative_metadata"}"#
        }.joined(separator: ", ")
        var runtimeEntry = ""
        var controlsEntry = ""
        var template = "lifecycle_fixture"
        if let generationRecipeRef {
            let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
            let controls = try CapabilityRuntimeFixtures.controlsJSON(
                .init(capability: "generation", recipeRef: generationRecipeRef)
            )
            runtimeEntry = #""capabilityRuntime": \#(runtime),"#
            controlsEntry = #""capabilityControls": \#(controls),"#
            template = "openai_chat_completions"
        }
        return """
        {
          "version": 1,
          "contractVersion": 1,
          \(runtimeEntry)
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {},
              "templates": {
                "\(template)": {
                  "transport": "openai_chat_completions",
                  "wire": {\(wireEntries.joined(separator: ", "))}
                }
              }
            }
          },
          "providers": {
            "openRouter": {
              "resolveMap": {"\(modelID)": "\(modelID)"},
              "models": {
                "\(modelID)": {
                  "canonicalModelId": "\(modelID)",
                  "transport": "openai_chat_completions",
                  \(controlsEntry)
                  "profiles": {
                    "generation": {
                      "template": "\(template)",
                      "revision": "\(generationRevision)",
                      "parameters": [\(declared)]
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    private static func officialBody(
        profile: GenerationProfileRef,
        model: AIModel,
        transport: String = "openai_chat_completions"
    ) throws -> [String: Any] {
        let hasExplicitValue = true
        let identity = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "lifecycle-user",
            connectionInstanceID: UUID().uuidString,
            connectionGeneration: "lifecycle-generation",
            credentialEpoch: "lifecycle-epoch",
            providerKind: ProviderKind.openRouter.rawValue,
            modelID: model.id,
            canonicalModelID: model.canonicalModelId,
            effectiveTransport: transport,
            now: 1_000,
            hasExplicitValue: hasExplicitValue
        ))
        var body: [String: Any] = ["model": modelID]
        let applied = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            ProfileParamsResolver.applyGenerationParameters(
                to: &body,
                options: ChatRequestOptions(
                    generationParameters: .init(values: [
                        "temperature": .init(state: hasExplicitValue ? .value : .inherit, value: .number(0.4)),
                    ]),
                    generationProfile: profile
                ),
                finalRequest: URLRequest(url: URL(string: "https://openrouter.test/api/v1/chat/completions")!),
                effectiveTransport: transport
            )
        }
        #expect(applied)
        return body
    }

    private static func identity(
        provider: Provider,
        model: AIModel,
        hasExplicitValue: Bool
    ) -> CapabilityEvidenceRequestIdentity? {
        guard provider.kind == .relay else { return nil }
        guard let transport = provider.relayRequested?.transport.rawValue else { return nil }
        return .init(query: .init(
            partitionID: "lifecycle-user",
            connectionInstanceID: provider.id.uuidString,
            connectionGeneration: "lifecycle-generation",
            credentialEpoch: "lifecycle-epoch",
            providerKind: ProviderKind.relay.rawValue,
            modelID: model.id,
            canonicalModelID: model.canonicalModelId,
            effectiveTransport: transport,
            endpointFingerprint: "ep_lifecycle",
            metadataRevision: metadataRevision,
            generationRevision: model.generationProfile?.revision ?? metadataRevision,
            now: 1_000,
            hasExplicitValue: hasExplicitValue
        ))
    }

    private static func repositoryRoot() throws -> URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("shared").path) { return folder }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func loadContract() throws -> LifecycleContract {
        let url = try repositoryRoot()
            .appendingPathComponent("shared")
            .appendingPathComponent("model-contracts")
            .appendingPathComponent("generation_parameter_contract.v1.json")
        return try JSONDecoder().decode(LifecycleContract.self, from: Data(contentsOf: url))
    }

    private static func loadStringsTable(_ name: String) throws -> [String: [String: String]] {
        let url = try repositoryRoot()
            .appendingPathComponent("ios/Oriveo/Oriveo/\(name).xcstrings")
        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Localization: Decodable {
                    struct Unit: Decodable { let value: String }
                    let stringUnit: Unit?
                }
                let localizations: [String: Localization]?
            }
            let strings: [String: Entry]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return catalog.strings.mapValues { entry in
            (entry.localizations ?? [:]).compactMapValues { $0.stringUnit?.value }
        }
    }

    struct LifecycleContract: Decodable {
        let lifecycleCases: [Case]
        let lifecycleRules: Rules

        struct Rules: Decodable {
            let presets: [String]
        }

        struct Case: Decodable {
            let caseId: String
            let intent: Intent
            let expect: Expectation
        }

        struct Intent: Decodable {
            let providerKind: String
            let parameterId: String
            let declared: Bool
            let storedState: String
            let support: String?
            let wire: String?
        }

        struct Expectation: Decodable {
            let lifecycle: String
        }
    }
}
