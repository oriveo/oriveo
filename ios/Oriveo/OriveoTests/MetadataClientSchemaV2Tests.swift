import Foundation
import Testing
@testable import Oriveo

/// Metadata mock routed by query (its own copy to avoid sharing static stubs).
private final class SchemaV2MetadataMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]

    static func reset() {
        lock.lock()
        stubs = [:]
        lock.unlock()
    }

    static func stub(_ route: String, _ stub: Stub) {
        lock.lock()
        stubs[route] = stub
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemaV2MetadataMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func route(for url: URL) -> String {
        if url.path.hasSuffix("/model-facts") { return "facts" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch items.first(where: { $0.name == "view" })?.value {
        case "index": return "index"
        case "lean": return "lean"
        case "catalog": return "catalog:" + (items.first { $0.name == "provider" }?.value ?? "")
        default: return "other"
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = Self.route(for: request.url!)
        Self.lock.lock()
        let stub = Self.stubs[route] ?? Stub(statusCode: 404, headers: [:], data: Data())
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.data.isEmpty {
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private final class SchemaV2DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: String]] = []

    func record(context: [String: String]) {
        lock.lock()
        events.append(context)
        lock.unlock()
    }

    func snapshot() -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private func repoFile(_ relative: String) throws -> Data {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try Data(contentsOf: candidate)
        }
        folder.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

/// The same bundled schema production reads (the mirror inside the app bundle).
private func bundledSchemaData() throws -> Data {
    let url = try #require(
        Bundle.main.url(forResource: "metadata_payload.v2.schema", withExtension: "json")
            ?? Bundle.main.url(
                forResource: "metadata_payload.v2.schema", withExtension: "json", subdirectory: "BundledMetadata"
            )
    )
    return try Data(contentsOf: url)
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func ok(_ object: Any, etag: String) throws -> SchemaV2MetadataMockURLProtocol.Stub {
    .init(statusCode: 200, headers: ["Etag": etag], data: try jsonData(object))
}

private func wrapped(_ data: [String: Any]) -> [String: Any] {
    ["code": 0, "data": data, "message": "ok"]
}

private let revisionOne = "sha256:" + String(repeating: "1", count: 64)
private let revisionTwo = "sha256:" + String(repeating: "2", count: 64)

private func schemaV2Fields(_ object: [String: Any]) -> [String: Any] {
    var object = object
    object["metadataSchema"] = 2
    object["metadataRevision"] = 7
    object["generatedAt"] = "2026-10-19T00:00:00Z"
    return object
}

/// The index from the shared corpus, keeping only anthropic (with the given revision), plus one bad provider that lacks displayName.
private func schemaV2Index(revision: String) throws -> [String: Any] {
    let corpus = try #require(
        JSONSerialization.jsonObject(with: try repoFile("shared/model-contracts/metadata_catalog_contract.v1.json"))
            as? [String: Any]
    )
    let response = try #require(corpus["indexResponse"] as? [String: Any])
    var index = try #require(response["data"] as? [String: Any])
    let providers = try #require(index["providers"] as? [String: Any])
    var anthropic = try #require(providers["anthropic"] as? [String: Any])
    anthropic["catalogRevision"] = revision
    index["providers"] = ["anthropic": anthropic, "openAI": ["modelCount": 1]]
    return schemaV2Fields(index)
}

private func schemaV2Catalog(revision: String, models: [String: Any], resolveMap: [String: String]) -> [String: Any] {
    schemaV2Fields([
        "view": "catalog",
        "provider": "anthropic",
        "catalogRevision": revision,
        "models": models,
        "resolveMap": resolveMap,
    ])
}

@Suite("MetadataClient metadataSchema 2 validation", .serialized, .sharedProcessState)
struct MetadataClientSchemaV2Tests {

    @Test("Shared catalogCases one by one through the production decode chain: reject the envelope / drop only the bad model")
    func sharedCatalogCasesMatchExpectations() throws {
        let cases = try #require(
            JSONSerialization.jsonObject(with: try repoFile("shared/model-contracts/metadata_payload.v2.cases.json"))
                as? [String: Any]
        )
        let catalogCases = try #require(cases["catalogCases"] as? [[String: Any]])
        #expect(catalogCases.count == 9)
        let schema = try bundledSchemaData()
        for item in catalogCases {
            let name = try #require(item["name"] as? String)
            let expect = try #require(item["expect"] as? [String: Any])
            let body = try jsonData(try #require(item["data"]))
            let outcome = MetadataClient.schemaV2CatalogOutcomeForTesting(body, schemaData: schema)
            switch try #require(expect["envelope"] as? String) {
            case "reject":
                #expect(outcome == nil, "\(name)")
            default:
                let kept = try #require(expect["keptModels"] as? [String]).sorted()
                let dropped = try #require(expect["droppedModels"] as? [String]).sorted()
                #expect(outcome?.kept == kept, "\(name)")
                #expect(outcome?.dropped == dropped, "\(name)")
            }
        }
    }

    /// Pruning runs serially on the MetadataClient actor, not on the MainActor; this only guards against regressions (the conclusion that it does not block the UI is at the call site).
    @Test("Large catalog: pruning 810 models stays within a time bound")
    func largeCatalogPruneIsBounded() throws {
        var models: [String: Any] = [:]
        var resolveMap: [String: String] = [:]
        for i in 0..<810 {
            let id = "m-\(i)"
            models[id] = i % 81 == 0
                ? ["displayName": "Bad \(i)", "capabilityControls": ["vision_input": ["state": "maybe"]]]
                : ["displayName": "Model \(i)", "contextLength": 128_000 + i, "capabilities": ["text", "vision"]]
            resolveMap[id] = id
        }
        let body = try jsonData(schemaV2Catalog(revision: revisionOne, models: models, resolveMap: resolveMap))
        let schema = try bundledSchemaData()
        var samples: [Duration] = []
        var outcome: (kept: [String], dropped: [String])?
        for _ in 0..<5 {
            let started = ContinuousClock.now
            outcome = MetadataClient.schemaV2CatalogOutcomeForTesting(body, schemaData: schema)
            samples.append(ContinuousClock.now - started)
        }
        let median = samples.sorted()[samples.count / 2]
        print("[PERF] schemaV2 catalog prune 810 models median=\(median) samples=\(samples)")
        // The production path really ran to the end: a bad model only drops its own entry.
        #expect(outcome?.dropped.count == 10)
        #expect(outcome?.kept.count == 800)
        #expect(median < .seconds(1), "Pruning 810 models took a median of \(median), over 1 s")
    }

    @Test("Production path: a bad model drops only itself and is reported; a bad envelope rejects the whole payload and keeps last-good")
    func badModelDroppedAndBadEnvelopeKeepsLastGood() async throws {
        let recorder = SchemaV2DiagnosticRecorder()
        let client = MetadataClient(
            session: SchemaV2MetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, context in recorder.record(context: context) }
        )
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])

        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(revision: revisionOne)), etag: "index-1"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            revision: revisionOne,
            models: [
                "m-good": ["displayName": "Good", "contextLength": 1000],
                "m-bad": ["displayName": "Bad", "capabilityControls": ["vision_input": ["state": "maybe"]]],
            ],
            resolveMap: ["m-good": "m-good", "m-bad": "m-bad", "alias-bad": "m-bad"]
        )), etag: "catalog-1"))

        await client.forceRefresh()

        let good = try #require(client.resolveCatalogModel(modelID: "m-good", providerKind: .anthropic))
        #expect(good.displayName == "Good")
        #expect(client.resolveCatalogModel(modelID: "m-bad", providerKind: .anthropic) == nil)
        #expect(client.resolveCatalogModel(modelID: "alias-bad", providerKind: .anthropic) == nil)
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Anthropic")
        let reports = recorder.snapshot().filter { $0["operation"] == "catalog_model_entry_invalid" }
        #expect(reports.contains([
            "operation": "catalog_model_entry_invalid",
            "reason": "model_entry_invalid",
            "provider": "anthropic",
            "model_id": "m-bad",
            "instance_path": "/capabilityControls/vision_input/state",
            "keyword": "enum",
        ]), "\(reports)")
        let providerReport = try #require(reports.first { $0["provider"] == "openAI" })
        #expect(providerReport["model_id"] == nil)
        #expect(providerReport["keyword"] == "required")

        // Second generation: the envelope lacks metadataRevision -> the whole payload is rejected and the previous catalog stays as it was.
        var badEnvelope = schemaV2Catalog(
            revision: revisionTwo,
            models: ["m-new": ["displayName": "New"]],
            resolveMap: ["m-new": "m-new"]
        )
        badEnvelope["metadataRevision"] = nil
        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(revision: revisionTwo)), etag: "index-2"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(badEnvelope), etag: "catalog-2"))

        await client.forceRefresh()

        #expect(client.resolveCatalogModel(modelID: "m-good", providerKind: .anthropic)?.displayName == "Good")
        #expect(client.resolveCatalogModel(modelID: "m-new", providerKind: .anthropic) == nil)
        await client.resetForTesting()
    }

    private func makeClient(_ recorder: SchemaV2DiagnosticRecorder) -> MetadataClient {
        MetadataClient(
            session: SchemaV2MetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, context in recorder.record(context: context) }
        )
    }

    @Test("Bad entries at the Codable layer drop only themselves: models / providers report decode, an unresolved parametersRef carries the full path, aliases are pruned by the kept set")
    func codableBadEntriesDroppedIndividually() async throws {
        let recorder = SchemaV2DiagnosticRecorder()
        let client = makeClient(recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])

        var index = try schemaV2Index(revision: revisionOne)
        var providers = try #require(index["providers"] as? [String: Any])
        // The schema does not constrain the inner type of validation while Codable wants a String: only this provider is dropped.
        providers["deepseek"] = ["displayName": "DeepSeek", "validation": ["probe": 5]]
        index["providers"] = providers
        var catalog = schemaV2Catalog(
            revision: revisionOne,
            models: [
                "m-good": ["displayName": "Good"],
                "m-bad": ["displayName": "x", "supportsTemperature": "yes"],
                "m-param": ["displayName": "Param", "profilesRef": "p-miss"],
            ],
            resolveMap: ["m-good": "m-good", "alias-good": "m-good", "m-bad": "m-bad", "alias-bad": "m-bad",
                         "alias-param": "m-param", "alias-ghost": "m-ghost"]
        )
        catalog["tables"] = ["profiles": ["p-miss": ["generation": ["parametersRef": "nope"]]]]
        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(index), etag: "index-1"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(catalog), etag: "catalog-1"))

        await client.forceRefresh()

        #expect(client.resolveCatalogModel(modelID: "m-good", providerKind: .anthropic)?.displayName == "Good")
        #expect(client.resolveCatalogModel(modelID: "alias-good", providerKind: .anthropic)?.displayName == "Good")
        #expect(client.resolveCatalogModel(modelID: "m-bad", providerKind: .anthropic) == nil)
        #expect(client.resolveCatalogModel(modelID: "alias-bad", providerKind: .anthropic) == nil)
        #expect(client.resolveCatalogModel(modelID: "alias-param", providerKind: .anthropic) == nil)
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Anthropic")
        #expect(client.syncProviderDisplayName(providerKind: .deepseek) == nil)

        let reports = recorder.snapshot()
        #expect(!reports.contains { $0["operation"] == "decode" }, "\(reports)")
        let invalid = reports.filter { $0["operation"] == "catalog_model_entry_invalid" }
        #expect(invalid.contains([
            "operation": "catalog_model_entry_invalid",
            "reason": "model_entry_invalid",
            "provider": "anthropic",
            "model_id": "m-bad",
            "instance_path": "",
            "keyword": "decode",
        ]), "\(invalid)")
        #expect(invalid.contains([
            "operation": "catalog_model_entry_invalid",
            "reason": "model_entry_invalid",
            "provider": "deepseek",
            "instance_path": "",
            "keyword": "decode",
        ]), "\(invalid)")
        #expect(invalid.contains([
            "operation": "catalog_model_entry_invalid",
            "reason": "model_entry_invalid",
            "provider": "anthropic",
            "model_id": "m-param",
            "instance_path": "/profiles/generation/parametersRef",
            "keyword": "unresolved_ref",
        ]), "\(invalid)")
        await client.resetForTesting()
    }

    @Test("A null / empty ref in schema 2 counts as unresolved and drops only that model: the rest are kept, unresolved_ref is reported, and aliases pointing at them are removed together")
    func nullOrEmptyRefDropsOnlyThatModel() async throws {
        let recorder = SchemaV2DiagnosticRecorder()
        let client = makeClient(recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])

        var catalog = schemaV2Catalog(
            revision: revisionOne,
            models: [
                "m-good": ["displayName": "Good"],
                "m-null-controls": ["displayName": "NullControls", "capabilityControlsRef": NSNull()],
                "m-empty-param": ["displayName": "EmptyParam", "profilesRef": "p-empty"],
            ],
            resolveMap: ["m-good": "m-good", "alias-good": "m-good",
                         "alias-null": "m-null-controls", "alias-empty": "m-empty-param"]
        )
        catalog["tables"] = ["profiles": ["p-empty": ["generation": ["parametersRef": ""]]]]
        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(revision: revisionOne)), etag: "index-1"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(catalog), etag: "catalog-1"))

        await client.forceRefresh()

        #expect(client.providerModelIDs(providerKind: .anthropic) == ["m-good"])
        #expect(client.resolveCatalogModel(modelID: "alias-good", providerKind: .anthropic)?.displayName == "Good")
        for dropped in ["m-null-controls", "m-empty-param", "alias-null", "alias-empty"] {
            #expect(client.resolveCatalogModel(modelID: dropped, providerKind: .anthropic) == nil, "\(dropped)")
        }
        // The index fixture also carries one bad provider (a provider-level drop without model_id); only model-level drops matter here.
        let invalid = recorder.snapshot().filter { $0["operation"] == "catalog_model_entry_invalid" && $0["model_id"] != nil }
        #expect(invalid.count == 2, "\(invalid)")
        for (modelID, path) in [("m-null-controls", "/capabilityControlsRef"),
                                ("m-empty-param", "/profiles/generation/parametersRef")] {
            #expect(invalid.contains([
                "operation": "catalog_model_entry_invalid",
                "reason": "model_entry_invalid",
                "provider": "anthropic",
                "model_id": modelID,
                "instance_path": path,
                "keyword": "unresolved_ref",
            ]), "\(invalid)")
        }
        #expect(!recorder.snapshot().contains { $0["operation"] == "catalog_unresolved_ref" }, "schema 2 does not reject the whole payload")
        await client.resetForTesting()
    }

    @Test("Revision regression with a bad envelope: the revision is compared first and revision_regressed is reported instead of decode")
    func regressedRevisionReportedBeforeEnvelopeValidation() async throws {
        let recorder = SchemaV2DiagnosticRecorder()
        let client = makeClient(recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(revision: revisionOne)), etag: "index-1"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            revision: revisionOne, models: ["m-good": ["displayName": "Good"]], resolveMap: ["m-good": "m-good"]
        )), etag: "catalog-1"))
        await client.forceRefresh()
        #expect(client.resolveCatalogModel(modelID: "m-good", providerKind: .anthropic)?.displayName == "Good")

        var regressed = try schemaV2Index(revision: revisionTwo)
        regressed["metadataRevision"] = 3
        regressed["providers"] = 5
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(regressed), etag: "index-3"))
        await client.forceRefresh()

        let reports = recorder.snapshot()
        #expect(reports.contains(["operation": "catalog_revision_regressed", "reason": "revision_regressed", "provider": "index"]), "\(reports)")
        #expect(!reports.contains { $0["operation"] == "decode" }, "\(reports)")
        #expect(client.resolveCatalogModel(modelID: "m-good", providerKind: .anthropic)?.displayName == "Good")
        await client.resetForTesting()
    }

    @Test("A bad pricingV2 drops only that key: after decoding the whole schema 2 payload the model stays, pricingV2 is nil, and calcCost takes the legacy path")
    func malformedPricingV2KeepsModelAndFallsBackToLegacyCost() async throws {
        let recorder = SchemaV2DiagnosticRecorder()
        let client = makeClient(recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        let legacyPricing: [String: Any] = ["promptPerMToken": 2.0, "completionPerMToken": 8.0]
        SchemaV2MetadataMockURLProtocol.reset()
        SchemaV2MetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(revision: revisionOne)), etag: "index-1"))
        SchemaV2MetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            revision: revisionOne,
            models: [
                "m-v2-bad": [
                    "displayName": "V2 Bad",
                    "pricingUnit": "per_token",
                    "pricingStatus": "priced",
                    "pricing": legacyPricing,
        // One extra key is a violation under additionalProperties:false
                    "pricingV2": ["unit": "per_token", "base": ["inputPerMToken": 4.0, "outputPerMToken": 16.0], "bogus": 1],
                ],
                "m-v2-good": [
                    "displayName": "V2 Good",
                    "pricingUnit": "per_token",
                    "pricingStatus": "priced",
                    "pricing": legacyPricing,
                    "pricingV2": ["unit": "per_token", "base": ["inputPerMToken": 4.0, "outputPerMToken": 16.0]],
                ],
            ],
            resolveMap: ["m-v2-bad": "m-v2-bad", "m-v2-good": "m-v2-good"]
        )), etag: "catalog-1"))

        await client.forceRefresh()

        let bad = try #require(client.resolveCatalogModel(modelID: "m-v2-bad", providerKind: .anthropic))
        #expect(bad.displayName == "V2 Bad")
        #expect(bad.pricingV2 == nil)
        let good = try #require(client.resolveCatalogModel(modelID: "m-v2-good", providerKind: .anthropic))
        #expect(good.pricingV2?.base?.inputPerMToken == 4.0)

        let breakdown = UsageBreakdown(promptTokens: 1000, completionTokens: 1000)
        // Legacy path: 1000x2 + 1000x8 -> 0.01; v2: 1000x4 + 1000x16 -> 0.02
        let (badCost, badSource) = await client.calcCost(breakdown: breakdown, modelID: "m-v2-bad", providerKind: .anthropic, at: Date())
        #expect(badSource == .localEstimate)
        #expect(abs(badCost - 0.01) < 1e-9, "got \(badCost)")
        let (goodCost, _) = await client.calcCost(breakdown: breakdown, modelID: "m-v2-good", providerKind: .anthropic, at: Date())
        #expect(abs(goodCost - 0.02) < 1e-9, "got \(goodCost)")

        let reports = recorder.snapshot().filter { $0["operation"] == "catalog_model_entry_invalid" }
        let drop = try #require(reports.first { $0["model_id"] == "m-v2-bad" }, "\(reports)")
        #expect(drop["instance_path"]?.hasPrefix("/pricingV2") == true, "\(drop)")
        #expect(!reports.contains { $0["model_id"] == "m-v2-good" }, "\(reports)")
        await client.resetForTesting()
    }
}
