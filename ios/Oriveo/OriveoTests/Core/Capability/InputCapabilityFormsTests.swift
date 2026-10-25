import Foundation
import Testing
@testable import Oriveo

/// The connection forms (official / subscription / Relay) produce the three input-key projections through
/// production `capabilityProjection(provider:)`, and `permitsOutbound` follows the projection's outbound.
@Suite("InputCapabilityForms", .serialized, .sharedProcessState)
struct InputCapabilityFormsTests {
    private static let metadataETag = "input-capability-forms"
    private static let inputKeys: Set<String> = Set(CapabilityEvidenceFacade.inputCapabilityKeys)
    private static let vision = CapabilityEvidenceFacade.visionInputKey
    private static let video = CapabilityEvidenceFacade.videoInputKey

    // MARK: - Official

    private static func installOfficial(controls: String, transport: String? = "openai_chat") async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:input-forms", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"input-model": "input-model"},
            "models": {"input-model": {
              "canonicalModelId": "input-model",\(transport.map { #" "transport": "\#($0)","# } ?? "")
              "capabilities": ["text", "image", "file", "video"],
              "profiles": {},
              "capabilityControls": {\(controls)}
            }}
          }}
        }
        """, metadataETag: metadataETag)
    }

    private static func officialProjection() -> (CapabilityEvidenceProjection, Provider) {
        let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: false, metadataETag: metadataETag
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: inputKeys
        )
        return (projection, provider)
    }

    @Test("Official with missing controls: all three keys unknown, entry open, first-attach hint, and sent outbound")
    func officialMissingControlIsUnknownAndOutbound() async throws {
        try await Self.installOfficial(controls: "")
        let (projection, provider) = Self.officialProjection()
        #expect(ProviderForm.of(provider) == .official)

        for key in CapabilityEvidenceFacade.inputCapabilityKeys {
            let input = try #require(projection.inputProjection(for: key), "\(key)")
            #expect(!input.visible && input.editable, "\(key) entry open")
            #expect(input.outbound == .nativePart && input.hint == .firstAttachOnce, "\(key)")
            #expect(input.disabledReason == nil, "\(key)")
            #expect(projection.permitsOutbound(key), "\(key) unknown also goes outbound")
            #expect(projection.resolution(for: key)?.support == .unknown, "\(key) truth unchanged")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official auto + a family implemented on this end is shown; auto without wireFamily counts as unknown; an unimplemented family is disabled")
    func officialWireFamilyDecidesVisibility() async throws {
        // When the transport is known, a missing wireFamily falls back to the protocol family from the (key, transport)
        // table, the same as Web and Android; with no transport given here, it lands on "auto without wireFamily
        // counts as unknown".
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "auto_available", "wireFamily": "openai_chat.image_url"},
        "file_input": {"state": "auto_available"},
        "video_input": {"state": "auto_available", "wireFamily": "openai_chat.input_audio"}
        """, transport: nil)
        let (projection, _) = Self.officialProjection()

        let vision = try #require(projection.inputProjection(for: Self.vision))
        #expect(vision.visible && vision.editable && vision.outbound == .nativePart && vision.hint == nil)
        #expect(projection.permitsOutbound(Self.vision))

        let file = try #require(projection.inputProjection(for: CapabilityEvidenceFacade.fileInputKey))
        #expect(!file.visible && file.editable && file.hint == .firstAttachOnce)
        #expect(projection.permitsOutbound(CapabilityEvidenceFacade.fileInputKey))

        let video = try #require(projection.inputProjection(for: Self.video))
        #expect(video.disabledReason == .wireNotImplemented && video.outbound == .placeholder)
        #expect(!projection.permitsOutbound(Self.video))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official v2 negative-cache hit -> rejected_recently, not sent outbound")
    func officialNegativeCacheHitBlocksOutbound() async throws {
        let family = "openai_chat.image_url"
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "auto_available", "wireFamily": "\(family)", "sourceRefs": ["qwen.docs"]}
        """)
        let (before, provider) = Self.officialProjection()
        #expect(before.permitsOutbound(Self.vision), "Precondition: sent outbound while nothing is in the negative cache")
        let modelID = try #require(before.identity?.query.effectiveModelID)
        let connectionID = provider.id.uuidString
        defer { CapabilityNegativeCache.shared.clearConnection(connectionID) }

        CapabilityNegativeCache.shared.record(
            connectionId: connectionID, modelId: modelID, wireFamily: family,
            capabilityKey: Self.vision, signatureId: "openai.image_unsupported",
            verdictRevision: CapabilityNegativeCache.verdictRevision(.init(
                state: "auto_available", wireFamily: family, sourceRefs: ["qwen.docs"]
            ))
        )
        let (after, _) = Self.officialProjection(provider: provider)
        let input = try #require(after.inputProjection(for: Self.vision))
        #expect(input.disabledReason == .rejectedRecently)
        #expect(!input.visible && !input.editable && input.outbound == .placeholder)
        #expect(!after.permitsOutbound(Self.vision))
        await MetadataClient.shared.resetForTesting()
    }

    private static func officialProjection(provider: Provider) -> (CapabilityEvidenceProjection, Provider) {
        let model = provider.models[0]
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: false, metadataETag: metadataETag
        )
        return (CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: inputKeys
        ), provider)
    }

    // MARK: - Catalog-backed forms

    private static func catalogProjection(provider: Provider, model: AIModel) -> CapabilityEvidenceProjection {
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "input-forms", hasExplicitValue: false
        )
        return CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: inputKeys
        )
    }

    @Test("Subscription input follows the upstream first-hand input_modalities: vision as declared, undeclared files are not sent, Responses has no video family so video is not sent")
    func subscriptionFollowsFirstHandModalities() throws {
        for (modalities, wantsVision) in [(["text", "image"], true), (["text"], false)] {
            var provider = TestFactories.makeProvider(kind: .openAI, models: [])
            provider.authMode = .subscription
            #expect(ProviderForm.of(provider) == .subscription)
            // The legacy capability bit is the opposite of the first-hand declaration: the verdict only trusts first-hand and never reads the legacy bit.
            var model = TestFactories.makeModel(
                id: "gpt-5.6-sol", capabilities: wantsVision ? [.text] : [.text, .image]
            )
            model.upstreamInputModalities = modalities
            provider.catalogModels = [model]
            let projection = Self.catalogProjection(provider: provider, model: model)

            for key in CapabilityEvidenceFacade.inputCapabilityKeys {
                #expect(projection.inputProjection(for: key) != nil, "\(key)")
            }
            #expect(projection.permitsOutbound(Self.vision) == wantsVision)
            #expect(!projection.permitsOutbound(CapabilityEvidenceFacade.fileInputKey))
            #expect(!projection.permitsOutbound(Self.video))
            #expect(projection.inputProjection(for: Self.video)?.disabledReason == .wireNotImplemented)
        }
    }

    // MARK: - Relay

    /// The shared Relay metadata fixture; with `chatWithoutImage` the Chat Completions envelope is changed to reject images.
    private static func installRelayMetadata(chatWithoutImage: Bool = false) async throws {
        let data = try Data(contentsOf: try sharedFixtureURL("relay/metadata-fixture.json"))
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if chatWithoutImage {
            var runtime = try #require(root["relayRuntimeConfig"] as? [String: Any])
            var envelopes = try #require(runtime["transportEnvelopes"] as? [String: Any])
            var chat = try #require(envelopes["openai_chat_completions"] as? [String: Any])
            chat["image"] = false
            envelopes["openai_chat_completions"] = chat
            runtime["transportEnvelopes"] = envelopes
            root["relayRuntimeConfig"] = runtime
        }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        )
    }

    private static func relayModel(_ overrides: RelayCapabilityOverrides? = nil) -> AIModel {
        var model = AIModel(
            id: "relay-input-model", name: "relay-input-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.relayCapabilityOverrides = overrides
        return model
    }

    private static func relayProjection(
        transport: RelayTransport, model: AIModel
    ) -> (CapabilityEvidenceProjection, Provider) {
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
        let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider, model: model, partitionID: "input-forms"
        )
        return (CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: inputKeys
        ), provider)
    }

    /// The revision is the hash of the verdict synthesized by the facade, taken the same way on both the production read and write sides; without the verdict hash the read side would not match.
    private static func recordRelayVisionRejection(provider: Provider, model: AIModel, transport: RelayTransport) throws {
        let family = try #require(CapabilityEvidenceProductionAdapter.relayWireFamily(transport: transport, key: vision))
        let verdict = CapabilityEvidenceProductionAdapter.relayInputVerdict(
            key: vision,
            visionEvidence: RelayTruthAdapter.visionEvidence(model: model, consumesEngineDeclaration: false),
            wireFamily: family
        )
        CapabilityNegativeCache.shared.record(
            connectionId: provider.id.uuidString, modelId: model.id,
            wireFamily: family,
            capabilityKey: vision, signatureId: "relay.classified_rejected",
            verdictRevision: CapabilityNegativeCache.verdictRevision(verdict)
        )
    }

    @Test("Relay vision / file unknown: no badge, entry open, first-attach hint, and sent outbound; Responses has no video family, so video is not implemented")
    func relayUnknownIsOutbound() async throws {
        try await Self.installRelayMetadata()
        let (projection, provider) = Self.relayProjection(transport: .openaiResponses, model: Self.relayModel())
        #expect(ProviderForm.of(provider) == .relay)
        #expect(projection.identity != nil, "Precondition: an explicit transport has a UI identity")
        let video = try #require(projection.inputProjection(for: Self.video))
        #expect(video.disabledReason == .wireNotImplemented && !video.editable && video.outbound == .placeholder)
        for key in CapabilityEvidenceFacade.inputCapabilityKeys where key != Self.video {
            let input = try #require(projection.inputProjection(for: key), "\(key)")
            #expect(!input.visible && input.editable, "\(key) entry open")
            #expect(input.outbound == .nativePart && input.hint == .firstAttachOnce, "\(key)")
            #expect(input.disabledReason == nil, "\(key)")
            #expect(projection.permitsOutbound(key), "\(key) unknown also goes outbound")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay envelope image=false -> vision is wire_not_implemented and even a user add cannot override it; video has no envelope bit and is not blocked")
    func relayEnvelopeRejectsImage() async throws {
        try await Self.installRelayMetadata(chatWithoutImage: true)
        let (projection, _) = Self.relayProjection(
            transport: .openaiChatCompletions,
            model: Self.relayModel(RelayCapabilityOverrides(image: true, source: .user))
        )
        let vision = try #require(projection.inputProjection(for: Self.vision))
        #expect(vision.disabledReason == .wireNotImplemented)
        #expect(!vision.visible && !vision.editable && vision.outbound == .placeholder)
        #expect(!projection.permitsOutbound(Self.vision))

        // The fixture's Chat envelope has nativeFile=false: native files are rejected by the envelope as well.
        #expect(projection.inputProjection(for: CapabilityEvidenceFacade.fileInputKey)?.disabledReason == .wireNotImplemented)
        let video = try #require(projection.inputProjection(for: Self.video))
        #expect(video.disabledReason == nil && video.editable)
        #expect(projection.permitsOutbound(Self.video))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay delta remove (a legacy user override image=false, normalized) -> user_removed, not sent outbound")
    func relayUserRemoveDisables() async throws {
        try await Self.installRelayMetadata()
        let (projection, _) = Self.relayProjection(
            transport: .openaiResponses,
            model: Self.relayModel(RelayCapabilityOverrides(image: false, source: .user))
        )
        let input = try #require(projection.inputProjection(for: Self.vision))
        #expect(input.disabledReason == .userRemoved)
        #expect(!input.visible && !input.editable && input.outbound == .placeholder)
        #expect(!projection.permitsOutbound(Self.vision))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay v2 negative cache: a tested override cannot beat it (rejected_recently), a user override beats it (shown and sent outbound)")
    func relayNegativeCacheVersusOverrides() async throws {
        try await Self.installRelayMetadata()
        let transport = RelayTransport.openaiResponses
        let (testedBefore, tested) = Self.relayProjection(
            transport: transport, model: Self.relayModel(RelayCapabilityOverrides(image: true, source: .tested))
        )
        defer { CapabilityNegativeCache.shared.clearConnection(tested.id.uuidString) }
        #expect(testedBefore.permitsOutbound(Self.vision), "Precondition: sent outbound while nothing is in the negative cache")
        try Self.recordRelayVisionRejection(provider: tested, model: tested.models[0], transport: transport)
        let testedAfter = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: tested, model: tested.models[0],
            identity: CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: tested, model: tested.models[0], partitionID: "input-forms"
            ),
            keys: Self.inputKeys
        )
        let rejected = try #require(testedAfter.inputProjection(for: Self.vision))
        #expect(rejected.disabledReason == .rejectedRecently)
        #expect(!rejected.visible && !rejected.editable)
        #expect(!testedAfter.permitsOutbound(Self.vision))

        let userModel = Self.relayModel(RelayCapabilityOverrides(image: true, source: .user))
        let (_, user) = Self.relayProjection(transport: transport, model: userModel)
        defer { CapabilityNegativeCache.shared.clearConnection(user.id.uuidString) }
        try Self.recordRelayVisionRejection(provider: user, model: userModel, transport: transport)
        let userAfter = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: user, model: userModel,
            identity: CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: user, model: userModel, partitionID: "input-forms"
            ),
            keys: Self.inputKeys
        )
        let added = try #require(userAfter.inputProjection(for: Self.vision))
        #expect(added.visible && added.editable && added.disabledReason == nil)
        #expect(userAfter.permitsOutbound(Self.vision))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Relay read side cannot get a provider -> all three keys are hard-blocked and not sent outbound")
    func relayWithoutProviderIsHardBlocked() async throws {
        try await Self.installRelayMetadata()
        let model = Self.relayModel()
        let (withProvider, provider) = Self.relayProjection(transport: .openaiResponses, model: model)
        let identity = try #require(withProvider.identity)
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            form: ProviderForm.of(provider), providerKind: provider.kind, model: model,
            identity: identity, keys: Self.inputKeys
        )
        for key in CapabilityEvidenceFacade.inputCapabilityKeys {
            let input = try #require(projection.inputProjection(for: key), "\(key)")
            #expect(!input.visible && !input.editable && input.outbound == .placeholder, "\(key)")
            #expect(input.disabledReason != nil, "\(key)")
            #expect(!projection.permitsOutbound(key), "\(key) outbound")
        }
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Entry points without a Provider, and the final writer

    /// The projections one (provider, model) gets through four production entry points: the provider entry, the
    /// form entry, and the final writer's provider overload and its redacted-model overload (the latter two are
    /// called under an identity bound in a TaskLocal).
    private static func projectionsAcrossEntries(
        provider: Provider, model: AIModel, metadataETag: String? = nil
    ) throws -> [(String, CapabilityEvidenceProjection)] {
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "input-forms",
            hasExplicitValue: false, metadataETag: metadataETag
        )
        let request = URLRequest(url: try #require(URL(string: "https://dispatch.test/v1/responses")))
        let viaProvider = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: inputKeys
        )
        let viaForm = CapabilityEvidenceProductionAdapter.capabilityProjection(
            form: ProviderForm.of(provider), providerKind: provider.kind, model: model,
            identity: identity, keys: inputKeys
        )
        let (finalProvider, finalModel) = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            (
                CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                    request: request, effectiveTransport: "openai_responses",
                    provider: provider, model: model, keys: inputKeys
                ),
                CapabilityEvidenceProductionAdapter.finalDispatchIntent(
                    request: request, effectiveTransport: "openai_responses",
                    model: model, keys: inputKeys
                )
            )
        }
        return [("provider", viaProvider), ("form", viaForm),
                ("finalDispatchIntent(provider:)", finalProvider), ("finalDispatchIntent(model:)", finalModel)]
    }

    @Test("Official: all four entries agree on the three keys' outbound; auto goes outbound, unknown still goes outbound, an unimplemented family does not")
    func officialEntriesAgree() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "auto_available", "wireFamily": "openai_chat.image_url"},
        "video_input": {"state": "auto_available", "wireFamily": "openai_chat.input_audio"}
        """)
        let (_, provider) = Self.officialProjection()
        let entries = try Self.projectionsAcrossEntries(
            provider: provider, model: provider.models[0], metadataETag: Self.metadataETag
        )
        let want: [String: Bool] = [
            Self.vision: true, CapabilityEvidenceFacade.fileInputKey: true, Self.video: false,
        ]
        for (entry, projection) in entries {
            for (key, outbound) in want {
                let input = try #require(projection.inputProjection(for: key), "\(entry) \(key)")
                #expect(projection.permitsOutbound(key) == outbound, "\(entry) \(key)")
                #expect((input.outbound == .nativePart) == outbound, "\(entry) \(key)")
            }
            let file = try #require(projection.inputProjection(for: CapabilityEvidenceFacade.fileInputKey))
            #expect(file.hint == .firstAttachOnce, "\(entry) a missing key = unknown")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official with missing controls: the entries without a Provider send all three unknown keys outbound")
    func officialUnknownOutboundWithoutProvider() async throws {
        try await Self.installOfficial(controls: "")
        let (_, provider) = Self.officialProjection()
        for (entry, projection) in try Self.projectionsAcrossEntries(
            provider: provider, model: provider.models[0], metadataETag: Self.metadataETag
        ) {
            for key in CapabilityEvidenceFacade.inputCapabilityKeys {
                let input = try #require(projection.inputProjection(for: key), "\(entry) \(key)")
                #expect(input.editable && input.hint == .firstAttachOnce, "\(entry) \(key)")
                #expect(projection.permitsOutbound(key), "\(entry) \(key) unknown also goes outbound")
            }
        }
        await MetadataClient.shared.resetForTesting()
    }
}
