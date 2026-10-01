import Foundation
import Testing
@testable import Oriveo

@Suite("Provider recipe request compiler")
struct CapabilityRecipeRequestCompilerTests {
    @Test("shared cases compile registry recipes into redacted semantic deltas")
    func sharedCases() throws {
        let fixture = try Self.loadFixture()
        let registry = try Self.loadRegistry(relativePath: fixture.registryPath)

        for item in fixture.cases {
            let result = CapabilityRecipeRequestCompiler.compile(
                recipeRef: item.recipeRef, recipes: registry.recipes,
                providerKind: item.providerKind, transport: item.transport,
                capability: item.capability, selectedIntent: item.selectedIntent,
                availableIntents: item.selectedIntent.map { [$0] },
                base: item.baseOwnedArrays.mapValues { $0.foundationValue }
            )
            #expect(result.applied)
            #expect(
                Self.canonicalJSON(result.redactedPreview) == Self.canonicalJSON(item.expectedDelta.mapValues { $0.foundationValue })
            )
        }
    }

    @Test("cross-boundary and dangling registry recipes are rejected before body mutation")
    func sharedNegativeCases() throws {
        let fixture = try Self.loadFixture()
        let registry = try Self.loadRegistry(relativePath: fixture.registryPath)

        for item in fixture.negativeCases {
            let result = CapabilityRecipeRequestCompiler.compile(
                recipeRef: item.recipeRef, recipes: registry.recipes,
                providerKind: item.providerKind, transport: item.transport,
                capability: item.capability, selectedIntent: item.selectedIntent,
                availableIntents: item.selectedIntent.map { [$0] }, base: [:]
            )
            #expect(!result.applied)
            #expect(result.reason == item.expectReason)
            #expect(result.redactedPreview.isEmpty)
        }
    }

    @Test("legacy generation template authorizes only an equal profile")
    func legacyGenerationGate() async throws {
        let url = Self.findFile(components: ["shared", "model-contracts", "provider_recipe_request_compiler.v1.json"])
        // Report each failure on its own: an unreadable file must not pass for a renamed field being caught.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LegacyGateFixtureError.unreadable(path: url.path, reason: String(describing: error))
        }
        let fixture: LegacyGateFixture
        do {
            fixture = try JSONDecoder().decode(LegacyGateFixture.self, from: data)
        } catch DecodingError.keyNotFound(let key, let context) where key.stringValue == "expectInject" {
            throw LegacyGateFixtureError.missingExpectInject(
                context.codingPath.map(\.stringValue).joined(separator: ".")
            )
        } catch {
            throw LegacyGateFixtureError.undecodable(String(describing: error))
        }
        #expect(fixture.legacyGenerationGateCases.count == 8)
        for item in fixture.legacyGenerationGateCases {
            let allowed = CapabilityRecipeRequestCompiler.legacyGenerationTemplatesMatch(
                runtimeTemplate: item.template,
                profileTemplate: item.profileTemplate
            )
            #expect(allowed == item.expectInject, "\(item.caseId) expectInject")
        }

        // The loop above only proves the comparison itself. What decides whether the outgoing body
        // carries user generation parameters is ProfileParamsResolver.applyGenerationParameters, so the
        // same cases run again through the production path: catalog -> decoder -> resolver -> body.
        let executionData = try Data(contentsOf: Self.findFile(
            components: ["shared", "model-contracts", "provider_recipe_execution.v1.json"]
        ))
        let execution = try #require(JSONSerialization.jsonObject(with: executionData) as? [String: Any])
        let coverage = try #require(execution["providerCoverage"] as? [[String: Any]])
        let envelope = try CapabilityRuntimeFixtures.runtimeEnvelope()
        let recipes = try #require(envelope["recipes"] as? [String: Any])
        func recipeTemplate(_ coverageItem: [String: Any]) -> String? {
            guard let ref = coverageItem["recipeRef"] as? String,
                  let recipe = recipes[ref] as? [String: Any],
                  let ops = recipe["requestOps"] as? [[String: Any]] else { return nil }
            return ops.first { ($0["op"] as? String) == "legacy_generation_template" }?["template"] as? String
        }
        let options = ChatRequestOptions(generationParameters: .init(values: [
            "temperature": .init(state: .value, value: .number(0.31))
        ]))
        let request = URLRequest(url: try #require(URL(string: "https://legacy-gate.invalid/v1/generate")))

        for item in fixture.legacyGenerationGateCases {
            // The runtime template comes from a real generation recipe in the registry, not a hand-made one.
            let coverageItem = try #require(
                coverage.first { recipeTemplate($0) == item.template },
                "\(item.caseId): registry has no generation recipe for template \(item.template)"
            )
            let rawKind = try #require(coverageItem["providerKind"] as? String)
            let providerKind = try #require(ProviderKind(rawValue: rawKind))
            let recipeRef = try #require(coverageItem["recipeRef"] as? String)
            let runtimeTransport = try #require(coverageItem["transport"] as? String)
            let selector = (coverageItem["selectorTransport"] as? String) ?? runtimeTransport
            let modelID = item.caseId
            let etag = "legacy-gate-\(item.caseId)"

            let templateDefinition: [String: Any] = ["transport": selector, "wire": ["temperature": "temperature"]]
            let generationDefinitions: [String: Any] = [
                "version": 1,
                "parameters": ["temperature": ["valueSchema": "number"]],
                "templates": [item.profileTemplate: templateDefinition],
            ]
            let modelProfile: [String: Any] = [
                "template": item.profileTemplate,
                "revision": "legacy-gate-generation-v1",
                "parameters": [["id": "temperature", "support": "supported", "source": "authoritative_metadata"]],
            ]
            let modelEntry: [String: Any] = [
                "canonicalModelId": modelID,
                "transport": selector,
                "capabilityControls": CapabilityRuntimeFixtures.controls([
                    CapabilityRuntimeFixtures.ControlSpec(capability: "generation", recipeRef: recipeRef)
                ]),
                "profiles": ["generation": modelProfile],
            ]
            let providerEntry: [String: Any] = [
                "resolveMap": [modelID: modelID],
                "models": [modelID: modelEntry],
            ]
            let document: [String: Any] = [
                "version": 1,
                "capabilityRuntime": envelope,
                "profiles": ["generation": generationDefinitions],
                "providers": [rawKind: providerEntry],
            ]
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self),
                metadataETag: etag
            )

            let resolved = try #require(
                MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: providerKind),
                "\(item.caseId): model did not resolve"
            )
            let profile = try #require(resolved.generationProfile, "\(item.caseId): no generation profile")
            // Pin the preconditions so the template comparison is the only variable left: the runtime is
            // delivered with the fixture's template, and the profile resolves a writable wire. Otherwise a
            // zero delta in an unequal case could come from something else.
            let authorization = CapabilityRecipeRequestCompiler.generationTemplate(
                providerKind: providerKind, modelID: modelID, transport: runtimeTransport
            )
            #expect(authorization.runtimeDelivered, "\(item.caseId) runtime delivered")
            #expect(authorization.template == item.template, "\(item.caseId) runtime template")
            #expect(profile.template == item.profileTemplate, "\(item.caseId) profile template")
            #expect(profile.wire?["temperature"] == "temperature", "\(item.caseId) profile wire")

            var model = TestFactories.makeModel(id: modelID)
            model.canonicalModelId = resolved.canonicalModelId
            let identity = CapabilityEvidenceRequestIdentity.make(
                provider: TestFactories.makeProvider(id: UUID(), kind: providerKind),
                model: model,
                partitionID: "legacy-gate-user",
                hasExplicitValue: true,
                metadataETag: etag
            )
            var body: [String: Any] = [:]
            let applied = CapabilityEvidenceRequestContext.$current.withValue(identity) {
                ProfileParamsResolver.applyGenerationParameters(
                    to: &body, options: options, profile: profile,
                    finalRequest: request, effectiveTransport: runtimeTransport
                )
            }
            #expect(applied, "\(item.caseId) resolver reported a conflict")
            if item.expectInject {
                #expect(
                    body["temperature"] as? Double == 0.31,
                    "\(item.caseId) resolver body \(Self.canonicalJSON(body))"
                )
            } else {
                #expect(body.isEmpty, "\(item.caseId) resolver body must stay untouched: \(Self.canonicalJSON(body))")
            }
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("selected intent must also be present in the model control allowlist")
    func selectedIntentRequiresAvailableIntent() throws {
        let fixture = try Self.loadFixture()
        let registry = try Self.loadRegistry(relativePath: fixture.registryPath)
        let item = try #require(fixture.cases.first { $0.selectedIntent != nil })

        let result = CapabilityRecipeRequestCompiler.compile(
            recipeRef: item.recipeRef, recipes: registry.recipes,
            providerKind: item.providerKind, transport: item.transport,
            capability: item.capability, selectedIntent: item.selectedIntent,
            availableIntents: ["different-intent"], base: [:]
        )

        #expect(!result.applied)
        #expect(result.reason == "intent_not_available")
        #expect(result.redactedPreview.isEmpty)
    }

    @Test("shared fixture reaches official provider request builders")
    func sharedFixtureReachesOfficialBuilders() async throws {
        let fixture = try Self.loadFixture()
        let registryData = try Data(contentsOf: Self.findFile(
            components: fixture.registryPath.split(separator: "/").map(String.init)
        ))
        let registryObject = try #require(JSONSerialization.jsonObject(with: registryData) as? [String: Any])
        defer { RequestShapeContractURLProtocol.requestHandler = nil }

        for item in fixture.cases {
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: try Self.metadataJSON(for: item, registry: registryObject), metadataETag: "recipe-runtime"
            )
            if item.providerKind == "gemini" {
                let resolved = MetadataClient.shared.syncResolveCatalogModel(modelID: item.modelID, providerKind: .gemini)
                #expect(resolved?.transport == "gemini_generate")
                #expect(CapabilityRecipeRequestCompiler.canonicalTransport(resolved?.transport ?? "") == "gemini_generate_content")
            }
            let captured = try await Self.captureOfficialRequest(for: item)
            guard let data = Self.requestBodyData(captured),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Issue.record("\(item.caseId): captured request had no JSON body")
                continue
            }
            if item.expectedDelta.isEmpty {
                #expect(body["model"] as? String == item.modelID)
                #expect(body["tools"] == nil)
            } else {
                for (key, expected) in item.expectedDelta {
                    #expect(Self.containsFixtureDelta(expected.foundationValue, in: body[key]))
                }
            }
        }
    }

    @Test("D8 requestOps merge is last-specific-wins with stableJson append dedupe")
    func sharedMergeCases() throws {
        let fixture = try Self.loadFixture()
        #expect(fixture.requestOpMerge.rule == "last-specific-wins")
        #expect(fixture.mergeCases.count == 4)

        for item in fixture.mergeCases {
            let recipe = MetadataClient.CapabilityRecipe(
                id: item.recipeRef,
                providerKind: item.providerKind,
                transport: .init(protocolName: item.transport),
                capability: item.capability,
                executionKind: "server_tool",
                requestOps: item.recipeSnapshot.requestOps,
                route: nil, responseParserKind: nil, continuationKind: nil,
                continuationVariant: nil, maxToolLoops: nil, formula: nil,
                fallbackPolicy: nil, sourceRefs: nil,
                responseEvidenceRef: nil, errorRecoveryRef: nil
            )
            var body = item.baseOwnedArrays.mapValues { $0.foundationValue }
            let result = CapabilityRecipeRequestCompiler.compile(
                recipe: recipe, to: &body, providerKind: item.providerKind,
                transport: item.transport, capability: item.capability,
                selectedIntent: item.selectedIntent,
                availableIntents: item.selectedIntent.map { [$0] }
            )
            #expect(result.applied, "\(item.caseId): applied")
            #expect(
                Self.canonicalJSON(body)
                    == Self.canonicalJSON(item.expectedBody.mapValues { $0.foundationValue }),
                "\(item.caseId): body \(Self.canonicalJSON(body))"
            )
        }
    }

    @Test("append targets come from the shared contract's owned array roots")
    func appendRootsFollowSharedContract() throws {
        let roots = try Self.contractOwnedArrayRoots()
        #expect(roots.contains("tools"))
        #expect(roots.count >= 2)

        for root in roots {
            let accepted = try Self.compileAppend(pointer: "/\(root)/-")
            #expect(accepted.result.applied)
            #expect(
                Self.canonicalJSON(accepted.body) == "{\"\(root)\":[{\"type\":\"probe\"}]}",
                "\(root): body \(Self.canonicalJSON(accepted.body))"
            )

            let bare = try Self.compileAppend(pointer: "/\(root)")
            #expect(!bare.result.applied)
            #expect(bare.result.reason == "invalid_recipe_operation")
            #expect(bare.body.isEmpty)
        }

        let foreign = try Self.compileAppend(pointer: "/messages/-")
        #expect(!foreign.result.applied)
        #expect(foreign.result.reason == "invalid_recipe_operation")
    }

    private static func contractOwnedArrayRoots() throws -> [String] {
        struct Contract: Decodable {
            struct SafeOverlay: Decodable { let typedContributionOnlyRoots: [String] }
            let safeOverlay: SafeOverlay
        }
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: findFile(
            components: ["shared", "model-contracts", "request_preference_contract.v2.json"]
        )))
        return contract.safeOverlay.typedContributionOnlyRoots
    }

    private static func compileAppend(
        pointer: String
    ) throws -> (result: CapabilityRecipeRequestCompiler.Compilation, body: [String: Any]) {
        let opsJSON = "[{\"op\":\"append\",\"pointer\":\"\(pointer)\",\"value\":{\"type\":\"probe\"}}]"
        let ops = try JSONDecoder().decode(
            [MetadataClient.CapabilityRecipeOperation].self,
            from: Data(opsJSON.utf8)
        )
        let recipe = MetadataClient.CapabilityRecipe(
            id: "synthetic.append_root", providerKind: "openAI",
            transport: .init(protocolName: "openai_chat"), capability: "web",
            executionKind: "server_tool", requestOps: ops,
            route: nil, responseParserKind: nil, continuationKind: nil,
            continuationVariant: nil, maxToolLoops: nil, formula: nil,
            fallbackPolicy: nil, sourceRefs: nil,
            responseEvidenceRef: nil, errorRecoveryRef: nil
        )
        var body: [String: Any] = [:]
        let result = CapabilityRecipeRequestCompiler.compile(
            recipe: recipe, to: &body, providerKind: "openAI",
            transport: "openai_chat", capability: "web",
            selectedIntent: nil, availableIntents: nil
        )
        return (result, body)
    }

    private static func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: findFile(
            components: ["shared", "model-contracts", "provider_recipe_request_compiler.v1.json"]
        )))
    }

    private static func loadRegistry(relativePath: String) throws -> Registry {
        let components = relativePath.split(separator: "/").map(String.init)
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: findFile(components: components)))
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

    private static func canonicalJSON(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "<invalid>"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func metadataJSON(for item: Case, registry: [String: Any]) throws -> String {
        let transport = item.transport == "gemini_generate_content" ? "gemini_generate" : item.transport
        var control: [String: Any] = ["state": "auto_available", "recipeRef": item.recipeRef]
        if let selectedIntent = item.selectedIntent {
            control["availableIntents"] = [selectedIntent]
        }
        let runtime: [String: Any] = [
            "schemaVersion": 2,
            "revision": "recipe-runtime",
            "generatedAt": "2026-08-11T00:00:00Z",
            "recipes": registry["recipes"] ?? [:],
            "controlDefinitions": registry["controlDefinitions"] ?? [:],
            "sourceIndex": registry["sourceIndex"] ?? [:]
        ]
        let document: [String: Any] = [
            "version": 1,
            "providers": [item.providerKind: [
                "resolveMap": [item.modelID: item.modelID],
                "models": [item.modelID: [
                    "canonicalModelId": item.modelID,
                    "transport": transport,
                    "capabilityControls": [item.capability: control]
                ]]
            ]],
            "capabilityRuntime": runtime
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
    }

    private static func captureOfficialRequest(for item: Case) async throws -> URLRequest {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestShapeContractURLProtocol.self]
        let session = URLSession(configuration: config)
        nonisolated(unsafe) var captured: URLRequest?
        RequestShapeContractURLProtocol.requestHandler = { request in
            captured = request
            let url = request.url ?? URL(string: "https://recipe-compiler.invalid")!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data())
        }
        let message = ChatMessage(
            id: UUID(), role: .user, text: "fixture", providerKind: Self.providerKind(item.providerKind),
            providerName: Self.providerKind(item.providerKind).displayName, modelName: item.modelID, state: .delivered
        )
        let mode: ReasoningMode = switch item.selectedIntent {
        case "low": .fast
        case "balanced": .balanced
        case "deep": .deep
        case "max": .max
        default: .automatic
        }
        do {
            switch item.providerKind {
            case "openAI":
                for try await _ in OpenAIService(session: session).sendMessageStream(apiKey: "fixture-key", modelID: item.modelID, messages: [message], reasoningMode: mode, webSearchEnabled: item.capability == "web", supportsImageGeneration: false, requestOptions: .init()) {}
            case "anthropic":
                for try await _ in AnthropicService(session: session).sendMessageStream(apiKey: "fixture-key", modelID: item.modelID, messages: [message], reasoningMode: mode, webSearchEnabled: item.capability == "web", requestOptions: .init()) {}
            case "gemini":
                for try await _ in GeminiService(session: session).sendMessageStream(apiKey: "fixture-key", modelID: item.modelID, messages: [message], reasoningMode: mode, webSearchEnabled: item.capability == "web", supportsImageGen: false, requestOptions: .init()) {}
            case "deepseek":
                for try await _ in DeepSeekService(session: session).sendMessageStream(apiKey: "fixture-key", modelID: item.modelID, messages: [message], reasoningMode: mode, requestOptions: .init()) {}
            default: Issue.record("unexpected provider \(item.providerKind)")
            }
        } catch {
            // The mock deliberately has no provider stream payload; request capture is the assertion target.
        }
        return try #require(captured)
    }

    private static func containsFixtureDelta(_ expected: Any, in actual: Any?) -> Bool {
        guard let actual else { return false }
        if let expectedObject = expected as? [String: Any], let actualObject = actual as? [String: Any] {
            return expectedObject.allSatisfy { key, value in containsFixtureDelta(value, in: actualObject[key]) }
        }
        if let expectedArray = expected as? [Any], let actualArray = actual as? [Any] {
            // Fixture arrays include a synthetic builder-owned first entry; only its recipe-owned tail
            // must appear in a real Service body, whose builder may legitimately have no user function.
            return expectedArray.dropFirst().allSatisfy { wanted in actualArray.contains { containsFixtureDelta(wanted, in: $0) } }
        }
        return (expected as? NSObject)?.isEqual(actual) ?? false
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private static func providerKind(_ raw: String) -> ProviderKind {
        ProviderKind(rawValue: raw) ?? .openAI
    }

    private struct Registry: Decodable {
        let recipes: [String: MetadataClient.CapabilityRecipe]
    }

    private struct Fixture: Decodable {
        let registryPath: String
        let requestOpMerge: RequestOpMerge
        let mergeCases: [MergeCase]
        let cases: [Case]
        let negativeCases: [NegativeCase]
    }

    private struct RequestOpMerge: Decodable {
        let rule: String
        let appendDedupe: String
    }

    private struct MergeCase: Decodable {
        let caseId: String
        let providerKind: String
        let transport: String
        let recipeRef: String
        let capability: String
        let selectedIntent: String?
        let recipeSnapshot: RecipeSnapshot
        let baseOwnedArrays: [String: MetadataClient.JSONValue]
        let expectedBody: [String: MetadataClient.JSONValue]
        let expectedBodyIsExact: Bool
    }

    private struct RecipeSnapshot: Decodable {
        let requestOps: [MetadataClient.CapabilityRecipeOperation]
    }

    private struct Case: Decodable {
        let caseId: String
        let providerKind: String
        let transport: String
        let recipeRef: String
        let capability: String
        let selectedIntent: String?
        let baseOwnedArrays: [String: MetadataClient.JSONValue]
        let expectedDelta: [String: MetadataClient.JSONValue]

        var modelID: String { "recipe-\(caseId)" }
    }

    private struct NegativeCase: Decodable {
        let caseId: String
        let providerKind: String
        let transport: String
        let recipeRef: String
        let capability: String
        let selectedIntent: String?
        let expectReason: String
    }

    private struct LegacyGateFixture: Decodable {
        let legacyGenerationGateCases: [LegacyGateCase]
    }

    private struct LegacyGateCase: Decodable {
        let caseId: String
        let template: String
        let profileTemplate: String
        let expectInject: Bool
    }

    private enum LegacyGateFixtureError: Error, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case missingExpectInject(String)
        case undecodable(String)
        var description: String {
            switch self {
            case .unreadable(let path, let reason): "legacy generation gate fixture unreadable at \(path): \(reason)"
            case .missingExpectInject(let codingPath): "missing expectInject: \(codingPath)"
            case .undecodable(let reason): "legacy generation gate fixture undecodable: \(reason)"
            }
        }
    }
}
