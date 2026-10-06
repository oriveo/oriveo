import Foundation
import Testing
@testable import Oriveo

/// Per-item evaluation in the outbound writer. Source of truth is `outboundRules` in
/// `shared/model-contracts/generation_parameter_contract.v1.json`, with `outboundCases` in the
/// sibling `generation_parameter_contract.v1.cases.json`: the one table every client consumes.
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
        try await verifyOutbound(cases)
    }

    /// Model-level parameter facts (shared contract #modelLevelFacts): the three structured-output
    /// shapes and `strict`, the two max-token aliases, and the ranges and conflicts recorded per
    /// upstream.
    @Test("every model-level outbound case matches byte for byte through production metadata and the writer")
    func modelLevelOutboundCases() async throws {
        let contract = try Self.loadContract()
        let cases = try #require(contract["modelLevelOutboundCases"] as? [[String: Any]])
        #expect(cases.count >= 15)
        try await verifyOutbound(cases)
    }

    @Test("every model-level resolve case: range / conflictsWith / wire / strict override the platform definition and fall back when missing")
    func modelLevelResolveCases() async throws {
        let contract = try Self.loadContract()
        let definitions = try #require(contract["modelLevelResolveDefinitions"] as? [String: Any])
        let cases = try #require(contract["modelLevelResolveCases"] as? [[String: Any]])
        #expect(cases.count >= 11)

        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let model = try #require(item["model"] as? [String: Any])
            let template = try #require(model["template"] as? String)
            let route = try #require(Self.routes[template], "\(caseID) uses a template with no test route")
            let document: [String: Any] = [
                "version": 1,
                "contractVersion": 1,
                "profiles": ["generation": [
                    "version": 1,
                    "parameters": try #require(definitions["parameters"]),
                    "templates": try #require(definitions["templates"]),
                ]],
                "providers": [route.providerKey: [
                    "resolveMap": [Self.modelID: Self.modelID],
                    "models": [Self.modelID: [
                        "canonicalModelId": Self.modelID,
                        "transport": route.modelTransport,
                        "profiles": ["generation": [
                            "template": template,
                            "parameters": try #require(model["parameters"]),
                        ]],
                    ]],
                ]],
            ]
            GenerationWireDiagnostics.reset()
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self),
                metadataETag: "model-level-resolve-etag"
            )
            let resolved = try #require(
                MetadataClient.shared.syncResolveCatalogModel(modelID: Self.modelID, providerKind: route.providerKind),
                "\(caseID) did not resolve a model"
            )
            let profile = try #require(resolved.generationProfile, "\(caseID) has no generation profile")
            let expect = try #require(item["expect"] as? [String: Any])

            // The contract's wire lists only the parameters this model declares, while the resolved
            // profile keeps the whole template table (undeclared parameters are stopped by the
            // outbound eligibility check), so compare on the declared parameters only.
            let declaredIDs = Set(profile.parameters?.compactMap(\.id) ?? [])
            let declaredWire = (profile.wire ?? [:]).filter { declaredIDs.contains($0.key) }
            #expect(declaredWire == expect["wire"] as? [String: String], "\(caseID) wire mismatch: \(declaredWire)")
            if let ids = expect["parameterIds"] as? [String] {
                #expect(profile.parameters?.compactMap(\.id) == ids, "\(caseID) parameter list mismatch")
            }
            for (id, fields) in expect["parameters"] as? [String: [String: Any]] ?? [:] {
                let parameter = try #require(profile.parameters?.first { $0.id == id }, "\(caseID) is missing parameter \(id)")
                #expect(parameter.wire == nil, "\(caseID) a resolved path belongs in profile.wire only")
                if let range = fields["range"] as? [String: Any] {
                    let actual = try #require(
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode(parameter.range)) as? [String: Any]
                    )
                    #expect(NSDictionary(dictionary: actual).isEqual(to: range), "\(caseID) \(id) range mismatch: \(actual)")
                }
                if let conflicts = fields["conflictsWith"] as? [String] {
                    #expect((parameter.conflictsWith ?? []) == conflicts, "\(caseID) \(id) conflictsWith mismatch")
                }
                if let strict = fields["strict"] as? Bool {
                    #expect((parameter.strict == true) == strict, "\(caseID) \(id) strict mismatch")
                }
                if let enumValues = fields["enumValues"] as? [String] {
                    #expect(parameter.enumValues == enumValues.map(GenerationParameterValue.string), "\(caseID) \(id) enum values mismatch")
                }
            }
            let expectedRejections = (expect["wireRejections"] as? [[String: String]] ?? []).map {
                "\($0["parameterId"] ?? "?"):\($0["reason"] ?? "?")"
            }
            let rejections = GenerationWireDiagnostics.read().map { "\($0.parameterID):\($0.reason.rawValue)" }
            #expect(Set(rejections) == Set(expectedRejections), "\(caseID) wire rejection records mismatch: \(rejections)")
        }
        GenerationWireDiagnostics.reset()
        await MetadataClient.shared.resetForTesting()
    }

    private func verifyOutbound(_ cases: [[String: Any]]) async throws {
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
            for excluded in expect["bodyExcludes"] as? [String] ?? [] {
                #expect(body[excluded] == nil, "\(caseID) request body should not contain \(excluded)")
            }
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
        "openai_responses": .init(
            providerKind: .openAI, providerKey: "openAI", modelTransport: "openai_responses",
            recipeRef: "openai.responses.generation.v1", url: "https://api.openai.test/v1/responses"
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
            var reference: [String: Any] = ["id": id, "support": "supported", "source": "authoritative_metadata"]
            // strict exists on the model-level reference only; the platform-level definition has no such field.
            if let strict = definition.removeValue(forKey: "strict") { reference["strict"] = strict }
            definitions[id] = definition
            declared.append(reference)
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

    /// Rules and cases live in two files (cases in `generation_parameter_contract.v1.cases.json`);
    /// this merges them into one table.
    static func loadContract() throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let directory = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
            let candidate = directory.appendingPathComponent("generation_parameter_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let rules = try #require(object as? [String: Any])
                let casesObject = try JSONSerialization.jsonObject(with: Data(
                    contentsOf: directory.appendingPathComponent("generation_parameter_contract.v1.cases.json")
                ))
                let cases = try #require(casesObject as? [String: Any])
                return rules.merging(cases.filter { $0.key != "$comment" }) { current, _ in current }
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
