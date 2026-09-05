import Foundation
import Testing
@testable import Oriveo

@Suite("capability evidence generation availability contract", .serialized)
struct GenerationParameterAvailabilityContractTests {
    private static let modelID = "availability-model"
    private static let metadataRevision = "etag-availability"
    private static let generationRevision = "generation-availability"

    @Test("Fixture Coverage Is Locked")
    func fixtureCoverageIsLocked() throws {
        let contract = try Self.loadContract()
        #expect(contract.version == 1)
        #expect(contract.availabilityCases.count == 58)
        #expect(Set(contract.availabilityCases.map(\.caseId)).count == 58)
        #expect(contract.availabilityCases.contains { $0.caseId == "official.session.support_accepted" })
        #expect(contract.availabilityCases.contains { $0.caseId == "official.connectionDefaults.support_accepted_unverified" })
        #expect(contract.availabilityCases.contains { $0.caseId == "relay.session.support_unknown" })
        #expect(contract.availabilityCases.contains { $0.caseId == "relay.connectionDefaults.support_accepted" })
        #expect(contract.availabilityCases.contains { $0.caseId == "official.session.support_future_supported" })
        #expect(contract.availabilityCases.contains { $0.caseId == "relay.connectionDefaults.support_future_supported" })
        #expect(contract.availabilityCases.contains { $0.intent.parameter.wire == nil })
        #expect(contract.availabilityCases.contains { $0.intent.parameter.group == "engine_runtime" })
    }

    @Test("Cases Match Production Consumers")
    func casesMatchProductionConsumers() async throws {
        let contract = try Self.loadContract()

        for item in contract.availabilityCases {
            // Runtime-parameter management is always available here, so the contract cases that
            // withhold it describe a state this client cannot enter.
            guard item.intent.entitlement.canManageRuntime else { continue }
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: Self.metadataJSON(for: item),
                metadataETag: Self.metadataRevision
            )

            let provider = Self.makeProvider(for: item)
            let model = await Self.makeModel(for: item)
            let parameterID = item.intent.parameter.id
            let identity = Self.makeIdentity(for: item, provider: provider, model: model)
            let projection = CapabilityEvidenceProductionAdapter.generationProjection(
                provider: provider,
                model: model,
                identity: identity
            )
            let scope: GenerationParameterEntryScope = item.intent.scope == "session"
                ? .session
                : .connectionDefaults
            let parameter = projection.profile?.parameters?.first {
                UnsupportedParamClassifier.normalize($0.id ?? "") == parameterID
            } ?? GenerationParameterAvailability.profile(provider: provider, model: model)?
                .parameters?.first {
                    UnsupportedParamClassifier.normalize($0.id ?? "") == parameterID
                }
            let inScope = (scope == .session
                ? GenerationParameterAvailability.sessionActionable(
                    provider: provider, model: model, identity: identity
                )
                : GenerationParameterAvailability.connectionConfigurable(
                    provider: provider, model: model, identity: identity
                ))
                .contains { $0.id == parameterID }
            let editable = inScope && (parameter.map {
                GenerationParameterAvailability.editable(
                    provider: provider,
                    model: model,
                    parameter: $0,
                    scope: scope,
                    identity: identity
                )
            } ?? false)
            #expect(inScope == item.expect.inScope, "\(item.caseId): inScope")
            #expect(editable == item.expect.editable, "\(item.caseId): editable")

            // The contract's entryVisible uses the production scope collection:
            // session excludes reasoning even when the underlying projection row
            // remains present for connection defaults.
            let rowVisible = inScope
            #expect(rowVisible == item.expect.entryVisible, "\(item.caseId): entryVisible")
            if item.expect.editable,
               ["accepted", "accepted_unverified", "unknown"].contains(item.intent.parameter.support) {
                let explicitProjection = CapabilityEvidenceProductionAdapter.generationProjection(
                    provider: provider, model: model, identity: identity, explicitParameterIDs: [parameterID]
                )
                #expect(!projection.permitsOutbound(parameterID), "\(item.caseId): unexplicit value must omit")
                #expect(explicitProjection.permitsOutbound(parameterID), "\(item.caseId): explicit value may write")
            }
        }

        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official And Relay Share The Same IA")
    func officialAndRelayShareTheSameIA() {
        #expect(
            ProviderSettingsRow.rows(hasEndpointOptions: false) == [.connection, .modelBehavior, .delete],
            "settings-section IA drifted from three rows"
        )
        #expect(
            ProviderSettingsRow.rows(hasEndpointOptions: true) == [.endpoint, .connection, .modelBehavior, .delete],
            "settings-section IA drifted when the connection offers endpoint options"
        )
    }

    // MARK: - Production-shaped inputs

    private static func makeProvider(for item: AvailabilityContract.Case) -> Provider {
        let kind: ProviderKind = item.intent.providerKind == "relay" ? .relay : .openAI
        var provider = makeProvider(kind: kind, model: nil)
        if kind == .relay {
            provider.relayRequested = RelayRequestedConfig(
                transport: .openaiChatCompletions,
                authMode: .bearer,
                securityMode: .remoteHTTPS,
                resolvedAPIBaseURL: "https://relay.test/v1",
                engineProfile: "contract_test_engine"
            )
        }
        return provider
    }

    private static func makeProvider(kind: ProviderKind, model: AIModel?) -> Provider {
        Provider(
            id: UUID(),
            kind: kind,
            status: .connected,
            models: model.map { [$0] } ?? [],
            catalogModels: [],
            apiKey: "fixture-only",
            apiKeyPreview: "",
            baseURLText: kind == .relay ? "https://relay.test/v1" : nil
        )
    }

    private static func makeModel(for item: AvailabilityContract.Case) async -> AIModel {
        var model = TestFactories.makeModel(id: Self.modelID, capabilities: [.text], isDefault: true)
        if item.intent.providerKind == "relay" {
            let engineProfile = item.intent.parameter.group == "engine_runtime" ? "vllm" : nil
            var declaration = LocalEngineGenerationProfiles.profile(
                for: engineProfile,
                transport: .openaiChatCompletions
            )
            let parameters = declaration?.parameters?.map { parameter in
                guard parameter.id == item.intent.parameter.id else { return parameter }
                var value = parameter
                value.support = item.intent.parameter.support
                value.source = "user_declared"
                value.group = item.intent.parameter.group ?? value.group
                return value
            }
            declaration?.parameters = parameters
            // A Relay declaration owns this connection's wire map.  An absent
            // golden mapping must be an explicit empty map, never a local
            // template fallback that could turn the row into an outbound path.
            declaration?.wire = item.intent.parameter.wire.map { [item.intent.parameter.id: $0] } ?? [:]
            model.generationProfile = declaration
            return model
        }
        let resolved = await MetadataClient.shared.resolveCatalogModel(
            modelID: Self.modelID,
            providerKind: .openAI
        )
        model.canonicalModelId = resolved?.canonicalModelId
        model.generationProfile = resolved?.generationProfile
        return model
    }

    private static func makeIdentity(
        for item: AvailabilityContract.Case,
        provider: Provider,
        model: AIModel
    ) -> CapabilityEvidenceRequestIdentity? {
        guard item.intent.providerKind == "relay" else { return nil }
        return CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "availability-user",
            connectionInstanceID: provider.id.uuidString,
            connectionGeneration: "connection-generation",
            credentialEpoch: "credential-epoch",
            providerKind: ProviderKind.relay.rawValue,
            modelID: model.id,
            canonicalModelID: model.canonicalModelId,
            effectiveTransport: RelayTransport.openaiChatCompletions.rawValue,
            endpointFingerprint: "ep_availability",
            metadataRevision: Self.metadataRevision,
            generationRevision: nil,
            now: 1_000,
            hasExplicitValue: false
        ))
    }

    private static func metadataJSON(for item: AvailabilityContract.Case) -> String {
        let parameterID = item.intent.parameter.id
        // The metadata parser requires a non-empty template map to materialize
        // the profile.  For a target wire-missing case, keep an unrelated map
        // entry so the production profile remains present while this parameter
        // correctly has no writable target.
        let wireEntry = item.intent.parameter.wire.map { #""\#(parameterID)": "\#($0)""# }
            ?? #""_unmapped": "_unmapped""#
        let groupEntry = item.intent.parameter.group.map { #""\#(parameterID)": {"group": "\#($0)"}"# } ?? ""
        return """
        {
          "version": 1,
          "contractVersion": 1,
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {\(groupEntry)},
              "templates": {
                "capability_availability": {
                  "transport": "openai_chat_completions",
                  "wire": {\(wireEntry)}
                }
              }
            }
          },
          "providers": {
            "openAI": {
              "resolveMap": {"\(Self.modelID)": "\(Self.modelID)"},
              "models": {
                "\(Self.modelID)": {
                  "canonicalModelId": "\(Self.modelID)", "transport": "openai_chat_completions",
                  "profiles": {
                    "generation": {
                      "template": "capability_availability",
                      "revision": "\(Self.generationRevision)",
                      "parameters": [
                        {
                          "id": "\(parameterID)",
                          "support": "\(item.intent.parameter.support)",
                          "source": "authoritative_metadata"
                        }
                      ]
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    // MARK: - Shared contract decoding

    private static func loadContract() throws -> AvailabilityContract {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("generation_parameter_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(AvailabilityContract.self, from: Data(contentsOf: candidate))
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    struct AvailabilityContract: Decodable {
        let version: Int
        let availabilityCases: [Case]

        struct Case: Decodable {
            let caseId: String
            let intent: Intent
            let expect: Expectation

            struct Intent: Decodable {
                let providerKind: String
                let scope: String
                let parameter: Parameter
                let entitlement: Entitlement
            }

            struct Parameter: Decodable {
                let id: String
                let group: String?
                let support: String
                let wire: String?
            }

            struct Entitlement: Decodable {
                let canManageRuntime: Bool
            }
        }

        struct Expectation: Decodable {
            let inScope: Bool
            let entryVisible: Bool
            let editable: Bool
        }
    }
}
