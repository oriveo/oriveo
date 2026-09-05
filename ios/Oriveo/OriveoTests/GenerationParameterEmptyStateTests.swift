import Foundation
import Testing
@testable import Oriveo

/// In-app assertions for the generation-parameter container's four empty states
/// (`Relay onboarding experience spec` §5.4 · design source of truth PD-09 / CR-13)
/// and the relay "unverified" badge (CR-11).
///
/// **TG9**: every assertion's input comes from a production code path — the profile is
/// parsed by production `MetadataClient` from server-shaped metadata JSON, or synthesized
/// by production `LocalEngineGenerationProfiles`; the visible set and empty-state decision
/// all run production `GenerationParameterPanelPresentation`. Tests do not hand-write a
/// `GenerationProfileRef`.
@Suite("generation parameter empty state & unverified badge (D4 / D12 / CR-11 / CR-13)", .serialized)
struct GenerationParameterEmptyStateTests {

    // MARK: - Four empty states

    @Test("state A: a non-empty profile has never been seen → not verified")
    func stateAWhenProfileNeverSeen() async {
        await MetadataClient.shared.resetForTesting()
        let history = Self.freshHistory()
        let provider = Self.officialProvider(model: Self.model(profile: nil))
        let model = provider.models[0]

        #expect(history.hasSeenNonEmptyProfile(providerID: provider.id, modelID: model.id) == false)
        #expect(
            GenerationParameterPanelPresentation.emptyState(
                provider: provider,
                model: model,
                scope: .connectionDefaults,
                hasSeenNonEmptyProfile: history.hasSeenNonEmptyProfile(providerID: provider.id, modelID: model.id)
            ) == .notVerified
        )
    }

    @Test("state B: this device has seen a non-empty profile, now empty → catalog takeover/withdrawal; the A/B boundary is decided only by on-device history")
    func stateBAfterProfileWasWithdrawn() async throws {
        let history = Self.freshHistory()
        // The "has seen non-empty" step actually produces a non-empty profile through the
        // production parse chain, rather than writing the flag directly.
        let seenProfile = try await Self.profileFromProductionMetadata(
            parameters: [(id: "temperature", support: "supported", group: nil)]
        )
        let provider = Self.officialProvider(model: Self.model(profile: seenProfile))
        let model = provider.models[0]
        let declared = GenerationParameterAvailability
            .profile(provider: provider, model: model)?.parameters?.count ?? 0
        #expect(declared > 0)
        history.recordSeenProfile(providerID: provider.id, modelID: model.id, parameterCount: declared)

        // Catalog withdrawal: same connection, same model, profile becomes nil again.
        try await Self.loadProductionMetadata(parameters: [])
        let withdrawn = Self.officialProvider(id: provider.id, model: Self.model(profile: nil))
        #expect(
            GenerationParameterPanelPresentation.emptyState(
                provider: withdrawn,
                model: withdrawn.models[0],
                scope: .connectionDefaults,
                hasSeenNonEmptyProfile: history.hasSeenNonEmptyProfile(
                    providerID: withdrawn.id,
                    modelID: withdrawn.models[0].id
                )
            ) == .catalogManaged
        )

        // CR-13 registered known downgrade: after on-device history is cleared (reinstall / new device / cache wipe), B degrades to A.
        history.reset()
        #expect(
            GenerationParameterPanelPresentation.emptyState(
                provider: withdrawn,
                model: withdrawn.models[0],
                scope: .connectionDefaults,
                hasSeenNonEmptyProfile: history.hasSeenNonEmptyProfile(
                    providerID: withdrawn.id,
                    modelID: withdrawn.models[0].id
                )
            ) == .notVerified
        )
    }

    @Test("state D: session scope, every parameter unsupported → no operable parameters right now")
    func stateDWhenEveryParameterIsUnsupported() async throws {
        let profile = try await Self.profileFromProductionMetadata(
            parameters: [(id: "temperature", support: "unsupported", group: nil)]
        )
        let provider = Self.officialProvider(model: Self.model(profile: profile))
        let model = provider.models[0]

        #expect((profile.parameters?.count ?? 0) > 0)
        #expect(
            GenerationParameterPanelPresentation.emptyState(
                provider: provider,
                model: model,
                scope: .session,
                hasSeenNonEmptyProfile: false
            ) == .allUnsupported
        )
    }

    @Test("the container never collapses: when the visible set is empty an empty state must exist (D4/D12 structural intercept)")
    func containerNeverCollapses() async throws {
        var subjects: [(String, Provider, AIModel, CapabilityEvidenceRequestIdentity?)] = []

        // Official provider: no profile / all unsupported / entitlement-only leftover / normal.
        let bare = Self.officialProvider(model: Self.model(profile: nil))
        subjects.append(("official-no-profile", bare, bare.models[0], nil))
        let officialCases: [(String, String, String, String?)] = [
            ("official-unsupported", "temperature", "unsupported", nil),
            ("official-entitlement-only", "n_probs", "supported", "engine_runtime"),
            ("official-supported", "temperature", "supported", nil),
        ]
        for (label, id, support, group) in officialCases {
            let profile = try await Self.profileFromProductionMetadata(
                parameters: [(id: id, support: support, group: group)]
            )
            let provider = Self.officialProvider(model: Self.model(profile: profile))
            subjects.append((label, provider, provider.models[0], nil))
        }
        // Custom LLM: walk the locally synthesized profile for all four transports.
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent] {
            let provider = Self.relayProvider(transport: transport)
            subjects.append((
                "relay-\(transport.rawValue)", provider, provider.models[0],
                Self.relayUIIdentity(provider: provider, model: provider.models[0])
            ))
        }

        for (label, provider, model, identity) in subjects {
            for scope in [GenerationParameterEntryScope.connectionDefaults, .session] {
                let visible = GenerationParameterPanelPresentation.visibleParameters(
                    provider: provider,
                    model: model,
                    scope: scope,
                    identity: identity
                )
                let state = GenerationParameterPanelPresentation.emptyState(
                    provider: provider,
                    model: model,
                    scope: scope,
                    hasSeenNonEmptyProfile: false,
                    identity: identity
                )
                #expect(
                    visible.isEmpty == (state != nil),
                    "\(label)/\(scope.rawValue): visible set and empty state must be exact complements, otherwise the container silently collapses"
                )
            }
        }
    }

    @Test("empty-state copy carries zero percents, zero progress numbers, zero schedule promises (PD-09 copy hard rule)")
    func emptyStateCopyCarriesNoNumbers() {
        for state in GenerationParameterEmptyState.allCases {
            for copy in [state.title, state.detail].compactMap({ $0 }) {
                let hasDigit = copy.rangeOfCharacter(from: .decimalDigits) != nil
                #expect(!copy.contains("%"), "\(state.rawValue) copy contains a percent sign")
                #expect(!hasDigit, "\(state.rawValue) copy contains a digit (coverage / progress / schedule are all forbidden)")
                #expect(!copy.isEmpty, "\(state.rawValue) copy is empty — the empty state collapsed itself")
            }
        }
    }

    // MARK: - Relay unverified badge (CR-11)

    @Test("CR-11(b)(d): every unknown parameter in a relay locally synthesized profile must carry the badge, and the group note must appear")
    func everyUnknownRelayParameterCarriesTheBadge() {
        var sawUnknown = false
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent] {
            for engineProfile in [nil, "llamacpp", "vllm", "openwebui"] as [String?] {
                let provider = Self.relayProvider(transport: transport, engineProfile: engineProfile)
                let model = provider.models[0]
                let identity = Self.relayUIIdentity(provider: provider, model: model)
                let projection = CapabilityEvidenceProductionAdapter.generationProjection(
                    provider: provider, model: model, identity: identity
                )
                let visible = GenerationParameterPanelPresentation.visibleParameters(
                    provider: provider,
                    model: model,
                    scope: .connectionDefaults,
                    identity: identity
                )
                let unknown = visible.filter { $0.support == "unknown" }
                let label = "\(engineProfile ?? "generic")/\(transport.rawValue)"
                for parameter in unknown {
                    sawUnknown = true
                    #expect(
                        GenerationParameterPanelPresentation.showsUnverifiedBadge(
                            parameter: parameter,
                            projection: projection
                        ),
                        "\(label) \(parameter.id ?? "?") is protocol-inferred unknown; a missing badge is a fake-tier violation"
                    )
                }
                // The Relay facade also projects a local declaration's raw supported as "unverified".
                // The group note must stay in sync with the actual per-row badges, not with the
                // legacy profile's raw support.
                let badged = visible.filter {
                    GenerationParameterPanelPresentation.showsUnverifiedBadge(
                        parameter: $0,
                        projection: projection
                    )
                }
                #expect(
                    GenerationParameterPanelPresentation.showsUnverifiedGroupNote(
                        parameters: visible,
                        projection: projection
                    ) == !badged.isEmpty,
                    "\(label) group note must stay strictly in sync with the actual unverified-badge set"
                )
            }
        }
        #expect(sawUnknown, "not a single unknown was enumerated; this case tested nothing")
    }

    @Test("CR-11(c): §4.4 relay locally mapped reasoning budget tiers are also subject to the badge")
    func relayReasoningBudgetTiersAreBadgedToo() throws {
        let provider = Self.relayProvider(transport: .openaiChatCompletions)
        let model = provider.models[0]
        let identity = Self.relayUIIdentity(provider: provider, model: model)
        let projection = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, identity: identity
        )
        let visible = GenerationParameterPanelPresentation.visibleParameters(
            provider: provider,
            model: model,
            scope: .connectionDefaults,
            identity: identity
        )
        let reasoning = visible.filter(GenerationParameterAvailability.isReasoningParameter)
        #expect(
            Set(reasoning.compactMap(\.id)) == ["reasoning_effort", "reasoning_budget", "reasoning_mode"],
            "§4.4 reasoning tiers did not appear on the connection-scope panel; this case lost its subject"
        )
        for parameter in reasoning {
            #expect(parameter.support == "unknown", "locally mapped reasoning tiers are not a measured conclusion")
            #expect(
                GenerationParameterPanelPresentation.showsUnverifiedBadge(
                    parameter: parameter, projection: projection
                ),
                "\(parameter.id ?? "?"): protocol-inferred reasoning tier is missing the badge"
            )
        }
    }

    @Test("CR-11(e): official unknown is editable, but must not impersonate the Relay local-declaration badge")
    func officialUnknownParametersAreNotBadged() async throws {
        let profile = try await Self.profileFromProductionMetadata(
            parameters: [(id: "temperature", support: "unknown", group: nil)]
        )
        let provider = Self.officialProvider(model: Self.model(profile: profile))
        let parameter = try #require(provider.models[0].generationProfile?.parameters?.first)
        #expect(parameter.support == "unknown")
        let projection = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: provider.models[0]
        )
        #expect(GenerationParameterPanelPresentation.showsUnverifiedBadge(
            parameter: parameter, projection: projection
        ) == false)
        #expect(GenerationParameterAvailability.editable(
            provider: provider,
            model: provider.models[0],
            parameter: parameter
        ))
    }

    // MARK: - Fixtures

    private static let modelID = "empty-state-model"

    private static func freshHistory() -> GenerationParameterProfileHistory {
        let defaults = UserDefaults(suiteName: "empty-state-tests-\(UUID().uuidString)")!
        return GenerationParameterProfileHistory(defaults: defaults)
    }

    private static func model(profile: GenerationProfileRef?) -> AIModel {
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.generationProfile = profile
        return model
    }

    private static func officialProvider(id: UUID = UUID(), model: AIModel) -> Provider {
        Provider(
            id: id,
            kind: .openRouter,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "key",
            apiKeyPreview: "...key"
        )
    }

    private static func relayProvider(transport: RelayTransport, engineProfile: String? = nil) -> Provider {
        Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [model(profile: nil)],
            catalogModels: [],
            apiKey: "key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport, engineProfile: engineProfile)
        )
    }

    /// The profile must be parsed by **production** `MetadataClient` from server-shaped
    /// metadata JSON, otherwise these assertions only prove the test can construct objects (TG9).
    private static func profileFromProductionMetadata(
        parameters: [(id: String, support: String, group: String?)]
    ) async throws -> GenerationProfileRef {
        try await loadProductionMetadata(parameters: parameters)
        let resolved = await MetadataClient.shared.resolveCatalogModel(
            modelID: modelID,
            providerKind: .openRouter
        )
        let profile = try #require(resolved?.generationProfile, "production parse chain did not produce a profile")
        return profile
    }

    private static func loadProductionMetadata(
        parameters: [(id: String, support: String, group: String?)]
    ) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: metadataJSON(parameters: parameters),
            metadataETag: "empty-state-fixture-v1"
        )
    }

    private static func relayUIIdentity(
        provider: Provider,
        model: AIModel
    ) -> CapabilityEvidenceRequestIdentity? {
        CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider,
            model: model,
            partitionID: "empty-state-tests"
        )
    }

    private static func metadataJSON(parameters: [(id: String, support: String, group: String?)]) -> String {
        let wire = parameters.map { #""\#($0.id)": "\#($0.id)""# }.joined(separator: ", ")
        let groups = parameters.compactMap { item in
            item.group.map { #""\#(item.id)": {"group": "\#($0)"}"# }
        }.joined(separator: ", ")
        let declared = parameters.map {
            #"{"id": "\#($0.id)", "support": "\#($0.support)", "source": "authoritative_metadata"}"#
        }.joined(separator: ", ")
        return """
        {
          "version": 1,
          "contractVersion": 1,
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {\(groups)},
              "templates": {
                "empty_state_fixture": {
                  "transport": "openai_chat_completions",
                  "wire": {\(wire)}
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
                  "profiles": {
                    "generation": {
                      "template": "empty_state_fixture",
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
}
