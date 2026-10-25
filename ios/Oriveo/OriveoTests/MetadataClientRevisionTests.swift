import Foundation
import Testing
@testable import Oriveo

/// Metadata mock routed by query (its own copy to avoid sharing static stubs),
/// which also records the full URL and schema header of every request so the request switches can be asserted.
private final class RevisionMetadataMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    struct Request: Sendable, Equatable {
        let route: String
        let url: String
        let schemaHeader: String?
        let ifNoneMatch: String?
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]
    private static var recorded: [Request] = []

    static func reset() {
        lock.lock()
        stubs = [:]
        recorded = []
        lock.unlock()
    }

    static func stub(_ route: String, _ stub: Stub) {
        lock.lock()
        stubs[route] = stub
        lock.unlock()
    }

    static func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevisionMetadataMockURLProtocol.self]
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
        let url = request.url!
        let route = Self.route(for: url)
        Self.lock.lock()
        let stub = Self.stubs[route] ?? Stub(statusCode: 404, headers: [:], data: Data())
        Self.recorded.append(Request(
            route: route,
            url: url.absoluteString,
            schemaHeader: request.value(forHTTPHeaderField: "X-Oriveo-Metadata-Schema"),
            ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")
        ))
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url,
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

nonisolated private final class RevisionDiagnosticRecorder: @unchecked Sendable {
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

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func ok(_ object: Any, etag: String) throws -> RevisionMetadataMockURLProtocol.Stub {
    .init(statusCode: 200, headers: ["Etag": etag], data: try jsonData(object))
}

private func wrapped(_ data: [String: Any]) -> [String: Any] {
    ["code": 0, "data": data, "message": "ok"]
}

private let revisionOne = "sha256:" + String(repeating: "1", count: 64)
private let revisionTwo = "sha256:" + String(repeating: "2", count: 64)

private func schemaV2Fields(_ object: [String: Any], revision: Int) -> [String: Any] {
    var object = object
    object["metadataSchema"] = 2
    object["metadataRevision"] = revision
    object["generatedAt"] = "2026-10-19T00:00:00Z"
    return object
}

/// The index from the shared corpus, keeping only anthropic; displayName tells which generation was adopted.
/// With a nil catalogRevision nothing is registered, so the catalog is requested every time (used to test the catalog-level revision).
private func schemaV2Index(payloadRevision: Int, displayName: String, catalogRevision: String?) throws -> [String: Any] {
    let corpus = try #require(
        JSONSerialization.jsonObject(with: try repoFile("shared/model-contracts/metadata_catalog_contract.v1.json"))
            as? [String: Any]
    )
    let response = try #require(corpus["indexResponse"] as? [String: Any])
    var index = try #require(response["data"] as? [String: Any])
    let providers = try #require(index["providers"] as? [String: Any])
    var anthropic = try #require(providers["anthropic"] as? [String: Any])
    anthropic["displayName"] = displayName
    anthropic["catalogRevision"] = catalogRevision
    index["providers"] = ["anthropic": anthropic]
    return schemaV2Fields(index, revision: payloadRevision)
}

private func schemaV2Catalog(payloadRevision: Int, catalogRevision: String, models: [String: Any]) -> [String: Any] {
    schemaV2Fields([
        "view": "catalog",
        "provider": "anthropic",
        "catalogRevision": catalogRevision,
        "models": models,
        "resolveMap": Dictionary(uniqueKeysWithValues: models.keys.map { ($0, $0) }),
    ], revision: payloadRevision)
}

/// Re-encode the JSONValue decoded by production code and compare it with JSON semantics (key order ignored).
private func jsonObject(_ value: MetadataClient.JSONValue?) throws -> NSObject? {
    guard let value else { return nil }
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject
}

@Suite("MetadataClient payloadRevision only increases, and the requested-schema switch", .serialized, .sharedProcessState)
struct MetadataClientRevisionTests {

    private func makeClient(
        recorder: RevisionDiagnosticRecorder? = nil,
        requestedSchema: Int = MetadataClient.requestedMetadataSchema
    ) -> MetadataClient {
        MetadataClient(
            session: RevisionMetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, context in recorder?.record(context: context) },
            requestedMetadataSchema: requestedSchema
        )
    }

    private func regressedReports(_ recorder: RevisionDiagnosticRecorder) -> [[String: String]] {
        recorder.snapshot().filter { $0["operation"] == "catalog_revision_regressed" }
    }

    @Test("Shared revisionCases one by one: accept with no cache, accept newer, leave equal untouched, reject older")
    func sharedRevisionCasesMatchDecision() throws {
        let cases = try #require(
            JSONSerialization.jsonObject(with: try repoFile("shared/model-contracts/metadata_payload.v2.cases.json"))
                as? [String: Any]
        )
        let revisionCases = try #require(cases["revisionCases"] as? [[String: Any]])
        // The case count is not hard-coded: the fixture gains cases over time; only lock that the "bundled 0 -> online 0 accepts" case is present
        #expect(!revisionCases.isEmpty)
        #expect(revisionCases.contains { $0["name"] as? String == "bundled_zero_then_zero_accepts" })
        for item in revisionCases {
            let name = try #require(item["name"] as? String)
            let cached = (item["cached"] as? NSNumber)?.intValue
            let incoming = try #require((item["incoming"] as? NSNumber)?.intValue)
            let expect = try #require(item["expect"] as? String)
            let decision = MetadataClient.payloadRevisionDecision(cached: cached, incoming: incoming)
            #expect(decision.rawValue == expect, "\(name)")
        }
    }

    @Test("index: 5 then 4 is rejected, keeping 5 and reporting; equal data is untouched and the ETag refreshes on the same row")
    func indexRevisionOnlyIncreases() async throws {
        let recorder = RevisionDiagnosticRecorder()
        let client = makeClient(recorder: recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        let catalog = schemaV2Catalog(
            payloadRevision: 5, catalogRevision: revisionOne, models: ["m-a": ["displayName": "A"]]
        )

        RevisionMetadataMockURLProtocol.reset()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 5, displayName: "Rev5", catalogRevision: revisionOne
        )), etag: "index-5"))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(catalog), etag: "catalog-5"))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev5")
        #expect(await client.splitPayloadRevisionsForTesting().index == 5)
        #expect(regressedReports(recorder).isEmpty)

        // Older generation: rejected, data and cache row stay at 5, reported with provider=index and no value.
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 4, displayName: "Rev4", catalogRevision: revisionOne
        )), etag: "index-4"))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev5")
        #expect(await client.splitPayloadRevisionsForTesting().index == 5)
        #expect(try await client.splitCacheRowsForTesting()["index"]?.etag == "index-5")
        #expect(regressedReports(recorder) == [[
            "operation": "catalog_revision_regressed",
            "reason": "revision_regressed",
            "provider": "index",
        ]])

        // Equal: treated like a 304, data untouched, ETag refreshed on the same cache row; the next conditional request carries the new ETag.
        try await client.ageSplitCacheForTesting(by: 1_000)
        let aged = try await client.splitCacheRowsForTesting()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 5, displayName: "Rev5-equal", catalogRevision: revisionOne
        )), etag: "index-5b"))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev5")
        let rows = try await client.splitCacheRowsForTesting()
        #expect(rows["index"]?.etag == "index-5b")
        #expect(try #require(rows["index"]?.updatedAt) > (try #require(aged["index"]?.updatedAt)))
        #expect(await client.splitBodyWriteCountSnapshotForTesting() == 2, "equal revision must not rewrite the body")

        RevisionMetadataMockURLProtocol.stub("index", .init(statusCode: 304, headers: [:], data: Data()))
        await client.forceRefresh()
        let last = RevisionMetadataMockURLProtocol.requests().last
        #expect(last?.route == "index")
        #expect(last?.ifNoneMatch == "index-5b")
        #expect(regressedReports(recorder).count == 1)
        await client.resetForTesting()
    }

    @Test("catalog: compared against that provider's cache; an older one is rejected keeping last-good and reported, an equal one only refreshes the ETag")
    func catalogRevisionComparedPerProvider() async throws {
        let recorder = RevisionDiagnosticRecorder()
        let client = makeClient(recorder: recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])

        // The index registers no catalogRevision: the catalog is requested every time, and only its own revision decides whether it is accepted.
        RevisionMetadataMockURLProtocol.reset()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 1, displayName: "Anthropic", catalogRevision: nil
        )), etag: "index-1"))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 5, catalogRevision: revisionOne, models: ["m-old": ["displayName": "Old"]]
        )), etag: "catalog-5"))
        await client.forceRefresh()
        #expect(client.resolveCatalogModel(modelID: "m-old", providerKind: .anthropic)?.displayName == "Old")
        #expect(await client.splitPayloadRevisionsForTesting().catalogs["anthropic"] == .some(5))

        RevisionMetadataMockURLProtocol.stub("index", .init(statusCode: 304, headers: [:], data: Data()))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 4, catalogRevision: revisionTwo, models: ["m-new": ["displayName": "New"]]
        )), etag: "catalog-4"))
        await client.forceRefresh()
        #expect(client.resolveCatalogModel(modelID: "m-old", providerKind: .anthropic)?.displayName == "Old")
        #expect(client.resolveCatalogModel(modelID: "m-new", providerKind: .anthropic) == nil)
        #expect(try await client.splitCacheRowsForTesting()["catalog:anthropic"]?.etag == "catalog-5")
        #expect(regressedReports(recorder) == [[
            "operation": "catalog_revision_regressed",
            "reason": "revision_regressed",
            "provider": "anthropic",
        ]])

        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 5, catalogRevision: revisionTwo, models: ["m-new": ["displayName": "New"]]
        )), etag: "catalog-5b"))
        await client.forceRefresh()
        #expect(client.resolveCatalogModel(modelID: "m-old", providerKind: .anthropic)?.displayName == "Old")
        #expect(client.resolveCatalogModel(modelID: "m-new", providerKind: .anthropic) == nil)
        let rows = try await client.splitCacheRowsForTesting()
        #expect(rows["catalog:anthropic"]?.etag == "catalog-5b")
        #expect(rows["catalog:anthropic"]?.revision == revisionOne, "equal revision must not rewrite the body")
        #expect(regressedReports(recorder).count == 1)
        await client.resetForTesting()
    }

    @Test("Production requests schema 3; injecting 1 keeps the legacy URL and headers, injecting 2 / 3 sends the same header and query")
    // A catalog request carries rev=<catalogRevision announced by the index for that provider>, placed after schema.
    func requestedSchemaSwitchControlsURLAndHeader() async throws {
        #expect(MetadataClient.requestedMetadataSchema == 3)
        let base = BackendURLResolver.resolve()
        for schema in [1, 2, 3] {
            let client = makeClient(requestedSchema: schema)
            await client.resetForTesting()
            client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
            RevisionMetadataMockURLProtocol.reset()
            RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
                payloadRevision: 1, displayName: "Anthropic", catalogRevision: revisionOne
            )), etag: "index-1"))
            RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
                payloadRevision: 1, catalogRevision: revisionOne, models: ["m-a": ["displayName": "A"]]
            )), etag: "catalog-1"))
            await client.forceRefresh()
            let requests = RevisionMetadataMockURLProtocol.requests()
            let index = try #require(requests.first { $0.route == "index" })
            let catalog = try #require(requests.first { $0.route == "catalog:anthropic" })
            if schema == 1 {
                #expect(index.url == "\(base)/api/metadata?view=index")
                #expect(catalog.url == "\(base)/api/metadata?view=catalog&provider=anthropic&rev=\(revisionOne)")
                #expect(index.schemaHeader == nil)
                #expect(catalog.schemaHeader == nil)
            } else {
                #expect(index.url == "\(base)/api/metadata?view=index&schema=\(schema)")
                #expect(catalog.url == "\(base)/api/metadata?view=catalog&provider=anthropic&schema=\(schema)&rev=\(revisionOne)")
                #expect(index.schemaHeader == String(schema))
                #expect(catalog.schemaHeader == String(schema))
            }
            await client.resetForTesting()
        }
    }

    @Test("lifecycle / parameterSupport survive a GRDB cache write and read unchanged")
    func lifecycleAndParameterSupportSurviveCacheRoundTrip() async throws {
        let lifecycle: [String: Any] = [
            "state": "deprecated", "shutdownAt": "2026-12-01T00:00:00Z", "signal": "upstream_shutdown_date",
        ]
        let parameterSupport: [String: Any] = [
            "temperature": ["state": "unknown", "reasonCode": "catalog_silent"],
            "structured_output": ["state": "auto_available"],
        ]
        let client = makeClient()
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        RevisionMetadataMockURLProtocol.reset()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 3, displayName: "Anthropic", catalogRevision: revisionOne
        )), etag: "index-3"))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 3, catalogRevision: revisionOne, models: [
                "m-life": ["displayName": "Life", "lifecycle": lifecycle, "parameterSupport": parameterSupport],
                "m-plain": ["displayName": "Plain"],
            ]
        )), etag: "catalog-3"))
        await client.forceRefresh()
        let live = try #require(await client.splitModelRawFieldsForTesting(kind: "anthropic", modelID: "m-life"))
        #expect(try jsonObject(live.lifecycle) == lifecycle as NSDictionary)

        // Another instance cold-starts: it reads back from the GRDB split cache only.
        RevisionMetadataMockURLProtocol.stub("index", .init(statusCode: 304, headers: [:], data: Data()))
        let coldClient = makeClient()
        coldClient.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        await coldClient.initialize()
        await coldClient.waitForBackgroundWorkForTesting()
        let cached = try #require(await coldClient.splitModelRawFieldsForTesting(kind: "anthropic", modelID: "m-life"))
        #expect(try jsonObject(cached.lifecycle) == lifecycle as NSDictionary)
        #expect(try jsonObject(cached.parameterSupport) == parameterSupport as NSDictionary)
        let plain = try #require(await coldClient.splitModelRawFieldsForTesting(kind: "anthropic", modelID: "m-plain"))
        #expect(plain.lifecycle == nil)
        #expect(plain.parameterSupport == nil)
        #expect(await coldClient.splitPayloadRevisionsForTesting().index == 3)
        #expect(await coldClient.splitPayloadRevisionsForTesting().catalogs["anthropic"] == .some(3))
        await coldClient.resetForTesting()
        await client.resetForTesting()
    }

    @Test("Cached revision 0 (the bundled snapshot generation) counts as no value: an incoming 0 is accepted too")
    func cachedZeroRevisionAcceptsIncomingZero() async throws {
        #expect(MetadataClient.payloadRevisionDecision(cached: 0, incoming: 0) == .accept)
        let recorder = RevisionDiagnosticRecorder()
        let client = makeClient(recorder: recorder)
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        RevisionMetadataMockURLProtocol.reset()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 0, displayName: "Rev0", catalogRevision: revisionOne
        )), etag: "index-0"))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 0, catalogRevision: revisionOne, models: ["m-a": ["displayName": "A"]]
        )), etag: "catalog-0"))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev0")

        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 0, displayName: "Rev0b", catalogRevision: revisionOne
        )), etag: "index-0b"))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev0b")
        #expect(try await client.splitCacheRowsForTesting()["index"]?.etag == "index-0b")
        #expect(regressedReports(recorder).isEmpty)
        await client.resetForTesting()
    }

    @Test("An equal-revision 200 without an ETag keeps the cached ETag on the cache row")
    func unchangedWithoutETagKeepsCachedETag() async throws {
        let client = makeClient()
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])
        RevisionMetadataMockURLProtocol.reset()
        RevisionMetadataMockURLProtocol.stub("index", try ok(wrapped(try schemaV2Index(
            payloadRevision: 5, displayName: "Rev5", catalogRevision: nil
        )), etag: "index-5"))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", try ok(wrapped(schemaV2Catalog(
            payloadRevision: 5, catalogRevision: revisionOne, models: ["m-a": ["displayName": "A"]]
        )), etag: "catalog-5"))
        await client.forceRefresh()
        #expect(try await client.splitCacheRowsForTesting()["index"]?.etag == "index-5")
        #expect(try await client.splitCacheRowsForTesting()["catalog:anthropic"]?.etag == "catalog-5")

        RevisionMetadataMockURLProtocol.stub("index", .init(
            statusCode: 200,
            headers: [:],
            data: try jsonData(wrapped(try schemaV2Index(
                payloadRevision: 5, displayName: "Rev5-equal", catalogRevision: nil
            )))
        ))
        RevisionMetadataMockURLProtocol.stub("catalog:anthropic", .init(
            statusCode: 200,
            headers: [:],
            data: try jsonData(wrapped(schemaV2Catalog(
                payloadRevision: 5, catalogRevision: revisionTwo, models: ["m-b": ["displayName": "B"]]
            )))
        ))
        await client.forceRefresh()
        #expect(client.syncProviderDisplayName(providerKind: .anthropic) == "Rev5")
        #expect(client.resolveCatalogModel(modelID: "m-a", providerKind: .anthropic)?.displayName == "A")
        let rows = try await client.splitCacheRowsForTesting()
        #expect(rows["index"]?.etag == "index-5")
        #expect(rows["catalog:anthropic"]?.etag == "catalog-5")
        await client.resetForTesting()
    }
}
