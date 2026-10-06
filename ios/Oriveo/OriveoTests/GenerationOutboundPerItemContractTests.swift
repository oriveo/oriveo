import Foundation
import Testing
@testable import Oriveo

/// Per-item evaluation in the outbound writer. Source of truth is `outboundRules` /
/// `outboundCases` in `shared/model-contracts/generation_parameter_contract.v1.json`, the one
/// table every client consumes.
///
/// The profile is parsed by the production `MetadataClient` from catalog-shaped metadata JSON,
/// and the final body comes from the production `ProfileParamsResolver.applyGenerationParameters`
/// (followed by `applyAnthropicThinkingGuard` where it applies). The test only turns the
/// contract's profile into metadata and hands the overrides to the production decoder.
@Suite("generation outbound per-item contract", .serialized)
struct GenerationOutboundPerItemContractTests {

    @Test("every outbound case matches byte for byte through production metadata and the writer")
    func outboundCases() async throws {
        let contract = try Self.loadContract()
        let cases = try #require(contract["outboundCases"] as? [[String: Any]])
        #expect(cases.count >= 20)

        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let profileSpec = try #require(item["profile"] as? [String: Any], "\(caseID) has no profile")
            let template = try #require(profileSpec["template"] as? String)
            let route = try #require(Self.routes[template], "\(caseID) uses a template with no test route")

            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: try Self.metadataJSON(profile: profileSpec, route: route),
                metadataETag: "outbound-per-item-etag"
            )
            let resolved = try #require(
                MetadataClient.shared.syncResolveCatalogModel(modelID: Self.modelID, providerKind: route.providerKind),
                "\(caseID) did not resolve a model"
            )
            let profile = try #require(resolved.generationProfile, "\(caseID) did not get a generation profile")
            let transport = try #require(resolved.transport)

            let provider = TestFactories.makeProvider(id: UUID(), kind: route.providerKind)
            var model = TestFactories.makeModel(id: Self.modelID)
            model.canonicalModelId = resolved.canonicalModelId
            let identity = CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: "outbound-per-item-user",
                hasExplicitValue: true, metadataETag: "outbound-per-item-etag"
            )
            let request = URLRequest(url: try #require(URL(string: route.url)))
            let overrides = try JSONDecoder().decode(
                [String: GenerationParameterOverride].self,
                from: JSONSerialization.data(withJSONObject: try #require(item["overrides"]))
            )
            var body = try #require(item["body"] as? [String: Any])
            let builderDefaultMaxTokens = body["max_tokens"] as? Int

            var application = CapabilityEvidenceRequestContext.$current.withValue(identity) {
                ProfileParamsResolver.applyGenerationParameters(
                    to: &body,
                    options: ChatRequestOptions(generationParameters: .init(values: overrides)),
                    profile: profile, finalRequest: request, effectiveTransport: transport
                )
            }
            // In production the capability writer adds the thinking fields after the generation
            // parameters; the contract expresses that step as capabilityWrites.
            if let writes = item["capabilityWrites"] as? [String: Any] {
                ProfileParamsResolver.deepMerge(&body, writes)
            }
            if template == "anthropic_messages" {
                application = ProfileParamsResolver.applyAnthropicThinkingGuard(
                    to: &body, application: application, builderDefaultMaxTokens: builderDefaultMaxTokens
                )
            }

            let expect = try #require(item["expect"] as? [String: Any])
            let expectedBody = try #require(expect["body"] as? [String: Any])
            #expect(
                NSDictionary(dictionary: body).isEqual(to: expectedBody),
                "\(caseID) outbound body mismatch: \(Self.canonical(body)) != \(Self.canonical(expectedBody))"
            )
            let expectedDropped = try #require(expect["dropped"] as? [[String: String]]).map {
                "\($0["parameterId"] ?? "?"):\($0["reason"] ?? "?")"
            }
            let dropped = application.dropped.map { "\($0.parameterID):\($0.reason.rawValue)" }
            #expect(dropped == expectedDropped, "\(caseID) dropped list mismatch: \(dropped)")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("drop reasons, required fields and thinking-guard constants match the contract")
    func rulesMatchProductionConstants() throws {
        let contract = try Self.loadContract()
        let rules = try #require(contract["outboundRules"] as? [String: Any])
        #expect(rules["evaluation"] as? String == "per_item")
        #expect(
            rules["dropReasons"] as? [String]
                == GenerationParameterApplication.DropReason.allCases.map(\.rawValue)
        )
        let required = try #require(rules["requiredWireFields"] as? [String: [String]])
        #expect(required == ProfileParamsResolver.requiredWireFields.mapValues { $0.sorted() })

        let thinking = try #require(rules["anthropicThinking"] as? [String: Any])
        #expect(thinking["dropParameters"] as? [String] == ProfileParamsResolver.anthropicThinkingDroppedParameters)
        #expect(thinking["topPMin"] as? Double == ProfileParamsResolver.anthropicThinkingTopPMin)
        #expect(thinking["maxTokensFloorHeadroom"] as? Int == ProfileParamsResolver.anthropicThinkingMaxTokensHeadroom)
        let activeTypes = try #require((thinking["activeWhen"] as? [String: Any])?["in"] as? [String])
        #expect(Set(activeTypes) == ProfileParamsResolver.anthropicThinkingActiveTypes)

        let conflict = try #require(rules["conflict"] as? [String: Any])
        #expect(conflict["builderPresenceKeys"] as? [String] == ProfileParamsResolver.builderPresenceKeys)
    }

    /// The protected fields of the additional request body and the builder-owned root fields of
    /// wire hardening must stay one list, so the two cannot drift apart.
    @Test("additional-body protected fields are the builder-owned root fields")
    func additionalBodyProtectedFieldsShareOneSource() throws {
        let contract = try Self.loadContract()
        let rules = try #require(contract["additionalBodyRules"] as? [String: Any])
        let hardening = try #require(contract["wireHardening"] as? [String: Any])
        let protected = try #require(rules["protectedRootFields"] as? [String])
        #expect(protected == hardening["builderOwnedRootFields"] as? [String])
        for field in protected {
            #expect(
                ProfileParamsResolver.wireRejectionReason(field) == .ownedRootField,
                "\(field) is not a builder-owned root field in the client"
            )
        }
        let cases = try #require(contract["additionalBodyCases"] as? [[String: Any]])
        let covered = Set(cases.compactMap { item -> String? in
            guard let expect = item["expect"] as? [String: Any],
                  expect["reason"] as? String == "protected_field" else { return nil }
            return expect["field"] as? String
        })
        #expect(covered == Set(protected), "every protected field needs its own contract case")
    }

    // MARK: - Fixtures

    private struct Route {
        let providerKind: ProviderKind
        let providerKey: String
        let modelTransport: String
        let recipeRef: String
        let url: String
    }

    private static let modelID = "fixture-chat"
    private static let routes: [String: Route] = [
        "openai_chat_completions": .init(
            providerKind: .openAI, providerKey: "openAI", modelTransport: "openai_chat",
            recipeRef: "openai.chat.generation.v1", url: "https://api.openai.test/v1/chat/completions"
        ),
        "anthropic_messages": .init(
            providerKind: .anthropic, providerKey: "anthropic", modelTransport: "anthropic_messages",
            recipeRef: "anthropic.messages.generation.v1", url: "https://api.anthropic.test/v1/messages"
        ),
    ]

    private static func metadataJSON(profile: [String: Any], route: Route) throws -> String {
        let template = profile["template"] as? String ?? ""
        let parameters = profile["parameters"] as? [[String: Any]] ?? []
        var definitions: [String: Any] = [:]
        var declared: [[String: Any]] = []
        for parameter in parameters {
            guard let id = parameter["id"] as? String else { continue }
            var definition = parameter
            definition.removeValue(forKey: "id")
            definitions[id] = definition
            declared.append(["id": id, "support": "supported", "source": "authoritative_metadata"])
        }
        let document: [String: Any] = [
            "version": 1,
            "contractVersion": 1,
            "capabilityRuntime": try CapabilityRuntimeFixtures.runtimeEnvelope(),
            "profiles": ["generation": [
                "version": 1,
                "parameters": definitions,
                "templates": [template: ["transport": template, "wire": profile["wire"] ?? [:]]],
            ]],
            "providers": [route.providerKey: [
                "resolveMap": [modelID: modelID],
                "models": [modelID: [
                    "canonicalModelId": modelID,
                    "transport": route.modelTransport,
                    "supportsTemperature": true,
                    "capabilityControls": CapabilityRuntimeFixtures.controls(
                        .init(capability: "generation", recipeRef: route.recipeRef)
                    ),
                    "profiles": ["generation": [
                        "template": template,
                        "revision": "outbound-per-item-generation-v1",
                        "parameters": declared,
                    ]],
                ]],
            ]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func canonical(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    static func loadContract() throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("generation_parameter_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
