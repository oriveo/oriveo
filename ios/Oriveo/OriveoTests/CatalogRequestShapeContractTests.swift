import Foundation
import Testing
@testable import Oriveo

/// Metadata mock that answers per route from a queue and records every URL actually sent: assertions read the query from requests production really issued.
/// Its own copy, so static stubs are not shared with other suites.
private final class CatalogRequestShapeMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var queues: [String: [Stub]] = [:]
    private static var recorded: [(route: String, url: URL)] = []

    static func reset() {
        lock.lock()
        queues = [:]
        recorded = []
        lock.unlock()
    }

    static func stub(_ route: String, _ stubs: [Stub]) {
        lock.lock()
        queues[route] = stubs
        lock.unlock()
    }

    static func clearRecorded() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static func requests(_ route: String) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.route == route }.map(\.url)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRequestShapeMockURLProtocol.self]
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
        var queue = Self.queues[route] ?? []
        let stub = queue.first ?? Stub(statusCode: 404, headers: [:], data: Data())
        if queue.count > 1 {
            queue.removeFirst()
            Self.queues[route] = queue
        }
        Self.recorded.append((route, url))
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

nonisolated private final class CatalogRequestShapeRecorder: @unchecked Sendable {
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

private func shapeFixture() throws -> [String: Any] {
    let url = try sharedFixtureURL("provider-catalog/catalog-request-shape.v1.json")
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func shapeCase(_ id: String) throws -> [String: Any] {
    let cases = try #require(try shapeFixture()["cases"] as? [[String: Any]])
    return try #require(cases.first { $0["id"] as? String == id }, "fixture is missing \(id)")
}

private func shapeCorpusFile(_ relative: String) throws -> Data {
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

private func shapeOkStub(_ data: [String: Any], etag: String) throws -> CatalogRequestShapeMockURLProtocol.Stub {
    let body: [String: Any] = ["code": 0, "data": data, "message": "ok"]
    return .init(
        statusCode: 200,
        headers: ["Etag": etag],
        data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    )
}

/// The schema 2 index from the contract corpus, keeping only the provider the fixture names, with catalogRevision as the fixture announces (nil = no announcement).
private func shapeIndex(provider: String, catalogRevision: String?, payloadRevision: Int) throws -> [String: Any] {
    let corpus = try #require(
        JSONSerialization.jsonObject(with: try shapeCorpusFile("shared/model-contracts/metadata_catalog_contract.v1.json"))
            as? [String: Any]
    )
    let response = try #require(corpus["indexResponse"] as? [String: Any])
    var index = try #require(response["data"] as? [String: Any])
    let providers = try #require(index["providers"] as? [String: Any])
    var entry = try #require(providers[provider] as? [String: Any])
    entry["catalogRevision"] = catalogRevision
    index["providers"] = [provider: entry]
    index["metadataSchema"] = 2
    index["metadataRevision"] = payloadRevision
    index["generatedAt"] = "2026-10-21T00:00:00Z"
    return index
}

private func shapeCatalog(provider: String, catalogRevision: String, payloadRevision: Int) -> [String: Any] {
    [
        "view": "catalog",
        "provider": provider,
        "catalogRevision": catalogRevision,
        "models": ["m-new": ["displayName": "New"]],
        "resolveMap": ["m-new": "m-new"],
        "metadataSchema": 2,
        "metadataRevision": payloadRevision,
        "generatedAt": "2026-10-21T00:00:00Z",
    ]
}

private func queryValue(_ url: URL?, _ name: String) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite("Shared catalog-request-shape cases one by one: split-view requests are addressed by revision", .serialized, .sharedProcessState)
struct CatalogRequestShapeContractTests {

    private static let expectedIDs: Set<String> = [
        "catalog_request_carries_index_revision",
        "catalog_request_without_announced_revision_omits_rev",
        "regular_index_fetch_has_no_cache_bust",
        "mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision",
    ]

    @Test("The fixture id set maps one-to-one onto this suite's cases; parameter names follow the fixture")
    func fixtureIDsAreLocked() throws {
        let root = try shapeFixture()
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(Set(cases.compactMap { $0["id"] as? String }) == Self.expectedIDs)
        let params = try #require(root["params"] as? [String: String])
        #expect(params == ["catalogRevision": "rev", "cacheBust": "fresh"])
    }

    @Test("CATALOG_REQUEST_SHAPE_catalog_request_carries_index_revision")
    func catalogRequestCarriesIndexRevision() async throws {
        try await runCatalogCase("catalog_request_carries_index_revision")
    }

    @Test("CATALOG_REQUEST_SHAPE_catalog_request_without_announced_revision_omits_rev")
    func catalogRequestWithoutAnnouncedRevisionOmitsRev() async throws {
        try await runCatalogCase("catalog_request_without_announced_revision_omits_rev")
    }

    @Test("CATALOG_REQUEST_SHAPE_regular_index_fetch_has_no_cache_bust")
    func regularIndexFetchHasNoCacheBust() async throws {
        let item = try shapeCase("regular_index_fetch_has_no_cache_bust")
        let expect = try #require(item["expect"] as? [String: Any])
        let indexRequest = try #require(expect["indexRequest"] as? [String: Any])
        let (client, _) = try await makeClient()
        let revision = "sha256:" + String(repeating: "1", count: 64)
        CatalogRequestShapeMockURLProtocol.stub("index", [try shapeOkStub(
            try shapeIndex(provider: "openAI", catalogRevision: revision, payloadRevision: 1),
            etag: "index-1"
        )])
        // The catalog matches the announcement: this sync should make exactly one regular index fetch.
        CatalogRequestShapeMockURLProtocol.stub("catalog:openAI", [try shapeOkStub(
            shapeCatalog(provider: "openAI", catalogRevision: revision, payloadRevision: 1),
            etag: "catalog-1"
        )])
        await client.forceRefresh()

        let indexRequests = CatalogRequestShapeMockURLProtocol.requests("index")
        #expect(indexRequests.count == 1)
        #expect(queryValue(indexRequests.first, "fresh") == indexRequest["fresh"] as? String)
        #expect(queryValue(indexRequests.first, "view") == "index")
        await client.resetForTesting()
    }

    @Test("CATALOG_REQUEST_SHAPE_mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision")
    func mismatchRefetchBypassesEdgeThenCatalogUsesNewRevision() async throws {
        let item = try shapeCase("mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision")
        let announced = try #require(item["indexAnnounces"] as? [String: Any])
        let after = try #require(item["indexAfterRefetch"] as? [String: Any])
        let firstResponse = try #require(item["firstCatalogResponseRevision"] as? String)
        let expect = try #require(item["expect"] as? [String: Any])
        let first = try #require(expect["firstCatalogRequest"] as? [String: Any])
        let refetch = try #require(expect["indexRefetch"] as? [String: Any])
        let second = try #require(expect["secondCatalogRequest"] as? [String: Any])
        let provider = try #require(first["provider"] as? String)

        let (client, recorder) = try await makeClient()
        CatalogRequestShapeMockURLProtocol.stub("index", [
            try shapeOkStub(
                try shapeIndex(provider: provider, catalogRevision: announced[provider] as? String, payloadRevision: 1),
                etag: "index-stale"
            ),
            try shapeOkStub(
                try shapeIndex(provider: provider, catalogRevision: after[provider] as? String, payloadRevision: 2),
                etag: "index-fresh"
            ),
        ])
        // The stale catalog from the edge mismatches the index announcement; the refetched index announces exactly it, so the second request is accepted.
        CatalogRequestShapeMockURLProtocol.stub("catalog:\(provider)", [try shapeOkStub(
            shapeCatalog(provider: provider, catalogRevision: firstResponse, payloadRevision: 2),
            etag: "catalog-1"
        )])
        await client.forceRefresh()

        let indexRequests = CatalogRequestShapeMockURLProtocol.requests("index")
        let catalogRequests = CatalogRequestShapeMockURLProtocol.requests("catalog:\(provider)")
        #expect(indexRequests.count == 2)
        #expect(catalogRequests.count == 2)
        #expect(queryValue(indexRequests.first, "fresh") == nil, "the regular index fetch carries no fresh")
        #expect(refetch["fresh"] as? String == "non-empty")
        let fresh = queryValue(indexRequests.dropFirst().first, "fresh")
        #expect(fresh?.isEmpty == false, "the refetch after a mismatch carries a one-time fresh")
        #expect(queryValue(catalogRequests.first, "rev") == first["rev"] as? String)
        #expect(queryValue(catalogRequests.first, "fresh") == first["fresh"] as? String)
        #expect(queryValue(catalogRequests.dropFirst().first, "rev") == second["rev"] as? String)
        #expect(queryValue(catalogRequests.dropFirst().first, "provider") == second["provider"] as? String)

        // outcome accept, and no revision_mismatch is reported.
        #expect(expect["outcome"] as? String == "accept")
        #expect(client.resolveCatalogModel(modelID: "m-new", providerKind: .openAI)?.displayName == "New")
        #expect(recorder.snapshot().filter { ($0["operation"] ?? "").hasPrefix("catalog_revision") }.isEmpty)
        await client.resetForTesting()
    }

    /// Fixture catalogRequest: the index announces (or omits) the provider's revision truthfully; assert rev / fresh on the catalog request actually sent.
    private func runCatalogCase(_ id: String) async throws {
        let item = try shapeCase(id)
        let announced = try #require(item["indexAnnounces"] as? [String: Any])
        let expect = try #require(item["expect"] as? [String: Any])
        let catalogRequest = try #require(expect["catalogRequest"] as? [String: Any])
        let provider = try #require(catalogRequest["provider"] as? String)
        let announcedRevision = announced[provider] as? String

        let (client, _) = try await makeClient()
        CatalogRequestShapeMockURLProtocol.stub("index", [try shapeOkStub(
            try shapeIndex(provider: provider, catalogRevision: announcedRevision, payloadRevision: 1),
            etag: "index-1"
        )])
        CatalogRequestShapeMockURLProtocol.stub("catalog:\(provider)", [try shapeOkStub(
            shapeCatalog(
                provider: provider,
                catalogRevision: announcedRevision ?? "sha256:" + String(repeating: "3", count: 64),
                payloadRevision: 1
            ),
            etag: "catalog-1"
        )])
        await client.forceRefresh()

        let catalogRequests = CatalogRequestShapeMockURLProtocol.requests("catalog:\(provider)")
        let sent = try #require(catalogRequests.first, "\(id) sent no catalog request")
        #expect(queryValue(sent, "provider") == provider, "\(id)")
        #expect(queryValue(sent, "rev") == catalogRequest["rev"] as? String, "\(id)")
        #expect(queryValue(sent, "fresh") == catalogRequest["fresh"] as? String, "\(id)")
        #expect(queryValue(CatalogRequestShapeMockURLProtocol.requests("index").first, "fresh") == nil, "\(id)")
        await client.resetForTesting()
    }

    private func makeClient() async throws -> (MetadataClient, CatalogRequestShapeRecorder) {
        let recorder = CatalogRequestShapeRecorder()
        let client = MetadataClient(
            session: CatalogRequestShapeMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, context in recorder.record(context: context) },
            requestedMetadataSchema: MetadataClient.requestedMetadataSchema
        )
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .openAI, models: [])])
        CatalogRequestShapeMockURLProtocol.reset()
        return (client, recorder)
    }
}
