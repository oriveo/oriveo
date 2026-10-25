import Foundation
import Testing
@testable import Oriveo

/// Feeds every inputCapabilityCases entry of the shared fixture `capability_evidence_contract.v1.json` to the
/// facade projection function; this end's wire-family implementation table equals `wire_families.v1.json`
/// implementations.ios item by item.
@Suite("InputCapabilityCases", .serialized, .sharedProcessState)
struct InputCapabilityCasesTests {
    private static func contract(_ name: String) throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = url.appendingPathComponent("shared/model-contracts/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any]
                )
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { break }
            url = parent
        }
        Issue.record("Shared contract \(name) not found")
        throw CocoaError(.fileNoSuchFile)
    }

    private static func verdict(_ raw: Any?) throws -> CapabilityEvidenceFacade.InputVerdict? {
        guard let object = raw as? [String: Any] else { return nil }
        let stateRaw = try #require(object["state"] as? String)
        let state = try #require(CapabilityControlResolution.State(rawValue: stateRaw), "Unknown state \(stateRaw)")
        return .init(
            state: state,
            reasonCode: object["reasonCode"] as? String,
            wireFamily: object["wireFamily"] as? String
        )
    }

    @Test("Each inputCapabilityCases entry's five fields equal the fixture expect")
    func casesMatchFixture() throws {
        let root = try Self.contract("capability_evidence_contract.v1.json")
        let block = try #require(root["inputCapabilityCases"] as? [String: Any])
        let cases = try #require(block["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let key = try #require(item["key"] as? String)
            #expect(CapabilityEvidenceFacade.inputCapabilityKeys.contains(key), "\(id) key")
            let overrideOp = (item["override"] as? [String: Any])?["op"] as? String
            let override = try overrideOp.map {
                try #require(CapabilityEvidenceFacade.InputOverride(rawValue: $0), "\(id) override")
            }
            let connectionRaw = try #require(item["connection"] as? String, "\(id) connection")
            let connection = try #require(
                CapabilityEvidenceFacade.InputConnection(rawValue: connectionRaw), "\(id) connection"
            )
            let verdict = try Self.verdict(item["verdict"])
            let endImplements = try #require(item["endImplements"] as? Bool, "\(id) endImplements")
            let negativeCacheHit = try #require(item["negativeCacheHit"] as? Bool, "\(id) negativeCacheHit")
            let projection = CapabilityEvidenceFacade.inputCapabilityProjection(
                verdict: verdict, endImplements: endImplements, override: override,
                negativeCacheHit: negativeCacheHit, connection: connection
            )
            let expect = try #require(item["expect"] as? [String: Any])
            #expect(projection.visible == (expect["visible"] as? Bool), "\(id) visible")
            #expect(projection.editable == (expect["editable"] as? Bool), "\(id) editable")
            #expect(projection.outbound.rawValue == (expect["outbound"] as? String), "\(id) outbound")
            #expect(projection.hint?.rawValue == (expect["hint"] as? String), "\(id) hint")
            #expect(projection.disabledReason?.rawValue == (expect["disabledReason"] as? String), "\(id) disabledReason")
        }
    }

    @Test("Wire-family implementation table == the wire_families families whose implementedBy includes ios")
    func implementedFamiliesMatchContract() throws {
        let root = try Self.contract("wire_families.v1.json")
        let families = try #require(root["families"] as? [[String: Any]])
        var ios: [String] = []
        for family in families {
            let implementedBy = try #require(family["implementedBy"] as? [String], "\(family["id"] ?? "")")
            if implementedBy.contains("ios") { ios.append(try #require(family["id"] as? String)) }
        }
        #expect(ios.count == Set(ios).count)
        #expect(CapabilityEvidenceFacade.implementedWireFamilies == Set(ios))
        for family in ios {
            #expect(CapabilityEvidenceFacade.implementsWireFamily(family), "\(family)")
        }
    }

    @Test("Protocol defaults table == requiresMaxTokens / defaultMaxOutputTokens of the wire_families protocols")
    func protocolOutputDefaultsMatchContract() throws {
        let root = try Self.contract("wire_families.v1.json")
        let protocols = try #require(root["protocols"] as? [String: [String: Any]])
        #expect(Set(CapabilityEvidenceFacade.protocolOutputDefaults.keys) == Set(protocols.keys))
        for (name, rule) in protocols {
            let local = try #require(CapabilityEvidenceFacade.protocolOutputDefaults[name], "\(name)")
            #expect(local.requiresMaxTokens == (rule["requiresMaxTokens"] as? Bool), "\(name) requiresMaxTokens")
            #expect(local.defaultMaxOutputTokens == (rule["defaultMaxOutputTokens"] as? NSNumber)?.intValue, "\(name) default")
            #expect(!local.requiresMaxTokens || local.defaultMaxOutputTokens != nil, "\(name) a protocol that requires max_tokens must have a default")
        }
        #expect(CapabilityEvidenceFacade.protocolOutputDefault(for: .anthropicMessages)?.defaultMaxOutputTokens
            == (protocols["anthropic"]?["defaultMaxOutputTokens"] as? NSNumber)?.intValue)
        #expect(CapabilityEvidenceFacade.protocolOutputDefault(for: .openaiChat)?.requiresMaxTokens == false)
        #expect(CapabilityEvidenceFacade.protocolOutputDefault(for: .geminiGenerate)?.requiresMaxTokens == false)
    }

    @Test("An unknown family string = not implemented on this end")
    func unknownFamilyIsNotImplemented() {
        for family in ["openai_chat.audio_url", "bedrock.image", "", "OPENAI_CHAT.IMAGE_URL"] {
            #expect(!CapabilityEvidenceFacade.implementsWireFamily(family), "\(family)")
        }
    }

    @Test("A Relay override add cannot beat transport_not_supported")
    func relayAddCannotBeatTransportNotSupported() {
        let projection = CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: .init(state: .unavailable, reasonCode: "transport_not_supported", wireFamily: nil),
            endImplements: true, override: .add, negativeCacheHit: false, connection: .relay
        )
        #expect(!projection.editable)
        #expect(projection.disabledReason == .wireNotImplemented)
        #expect(projection.outbound == .placeholder)
    }

    @Test("Official transport_not_implemented comes before the negative cache")
    func transportNotImplementedBeatsNegativeCache() {
        let projection = CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: .init(state: .unavailable, reasonCode: "transport_not_implemented", wireFamily: nil),
            endImplements: true, override: nil, negativeCacheHit: true, connection: .official
        )
        #expect(projection.disabledReason == .wireNotImplemented)
        #expect(!projection.editable)
    }

    @Test("provider_kill_switch with a state other than unavailable is not treated as a kill switch")
    func killSwitchOnlyWhenUnavailable() {
        let projection = CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: .init(state: .autoAvailable, reasonCode: "provider_kill_switch", wireFamily: nil),
            endImplements: true, override: nil, negativeCacheHit: false, connection: .official
        )
        #expect(projection.disabledReason != .killSwitch)
        #expect(projection.editable)
    }
    // MARK: - Official projection boundaries: through production capabilityProjection(provider:) and officialInputProjection

    private static let officialETag = "official-input-boundary"

    private static func installOfficial(transport: String, visionControl: String) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:official-input-boundary", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"boundary-model": "boundary-model"},
            "models": {"boundary-model": {
              "canonicalModelId": "boundary-model", "transport": "\(transport)",
              "capabilities": ["text", "image"], "profiles": {},
              "capabilityControls": {"vision_input": \(visionControl)}
            }}
          }}
        }
        """, metadataETag: officialETag)
    }

    private static func officialVision() -> (CapabilityEvidenceProjection, CapabilityEvidenceFacade.InputCapabilityProjection?) {
        let persisted = TestFactories.makeModel(id: "boundary-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: false, metadataETag: officialETag
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: [CapabilityEvidenceFacade.visionInputKey]
        )
        return (projection, projection.inputProjections[CapabilityEvidenceFacade.visionInputKey])
    }

    @Test("Official auto_available without wireFamily: derives image_url from the openai_chat transport, can go outbound, badge shown")
    func officialAutoWithoutWireFamilyDerivesFromTransport() async throws {
        try await Self.installOfficial(
            transport: "openai_chat",
            visionControl: #"{"state": "auto_available", "reasonCode": "official_declared"}"#
        )
        let (projection, vision) = Self.officialVision()
        let input = try #require(vision)
        #expect(input.visible)
        #expect(input.editable)
        #expect(input.outbound == .nativePart)
        #expect(input.disabledReason == nil)
        #expect(projection.permitsOutbound(CapabilityEvidenceFacade.visionInputKey))
        #expect(CapabilityEvidenceFacade.inputWireFamily(key: CapabilityEvidenceFacade.visionInputKey, transport: "openai_chat")
            == "openai_chat.image_url")
    }

    @Test("Vision on an official text-only transport: disabled, wire_not_implemented, placeholder", arguments: [
        "gemini_interactions", "llamacpp_native", "dashscope_native",
    ])
    func officialTextOnlyTransportBlocksVision(transport: String) async throws {
        try await Self.installOfficial(
            transport: transport,
            visionControl: #"{"state": "auto_available", "reasonCode": "official_declared"}"#
        )
        let (projection, vision) = Self.officialVision()
        let input = try #require(vision)
        #expect(!input.visible, "\(transport)")
        #expect(!input.editable, "\(transport)")
        #expect(input.outbound == .placeholder, "\(transport)")
        #expect(input.disabledReason == .wireNotImplemented, "\(transport)")
        #expect(!projection.permitsOutbound(CapabilityEvidenceFacade.visionInputKey), "\(transport)")
    }

    @Test("State managed_only / custom_only -> unavailable, model_absent", arguments: ["managed_only", "custom_only"])
    func managedOrCustomOnlyIsModelAbsent(state: String) async throws {
        let raw = try #require(CapabilityControlResolution.State(rawValue: state))
        let direct = CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: .init(state: raw, reasonCode: nil, wireFamily: "openai_chat.image_url"),
            endImplements: true, override: nil, negativeCacheHit: false, connection: .official
        )
        #expect(!direct.editable)
        #expect(!direct.visible)
        #expect(direct.outbound == .placeholder)
        #expect(direct.disabledReason == .modelAbsent)

        try await Self.installOfficial(
            transport: "openai_chat", visionControl: #"{"state": "\#(state)"}"#
        )
        let (projection, vision) = Self.officialVision()
        let input = try #require(vision)
        #expect(input.disabledReason == .modelAbsent, "\(state)")
        #expect(input.outbound == .placeholder, "\(state)")
        #expect(!projection.permitsOutbound(CapabilityEvidenceFacade.visionInputKey), "\(state)")
    }
}
