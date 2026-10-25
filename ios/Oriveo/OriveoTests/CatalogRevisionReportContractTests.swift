import Foundation
import Testing
@testable import Oriveo

/// Metadata mock that answers per route from a queue: one route can return several responses in turn (e.g. the index is refetched once with a different announcement),
/// and the last response in the queue is reused once it is the only one left. Its own copy, so static stubs are not shared with other suites.
private final class CatalogRevisionReportMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var queues: [String: [Stub]] = [:]
    private static var recorded: [String] = []

    static func reset() {
        lock.lock()
        queues = [:]
        recorded = []
        lock.unlock()
    }

    static func stub(_ route: String, _ stubs: [Stub]) {
        lock.lock()
        queues[route] = stubs
        recorded = []
        lock.unlock()
    }

    static func requestedRoutes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRevisionReportMockURLProtocol.self]
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
        Self.recorded.append(route)
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

nonisolated private final class CatalogRevisionReportRecorder: @unchecked Sendable {
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

/// One case of the shared fixture catalog-revision-report.v1.json.
private struct CatalogRevisionReportCase {
    let id: String
    let cachedCatalogRevision: Int
    let indexAnnounces: Int
    /// nil = this case must not send a catalog request (the index announces the same revision as the cache).
    let responseRevision: Int?
    let indexAfterRefetch: Int?
    let outcome: String
    let report: String?
    let reports: Int
    let etagRefreshed: Bool
    let requestSent: Bool
}

private func reportFixtureCases() throws -> [CatalogRevisionReportCase] {
    let url = try sharedFixtureURL("provider-catalog/catalog-revision-report.v1.json")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try #require(root["cases"] as? [[String: Any]])
    return try cases.map { item in
        let expect = try #require(item["expect"] as? [String: Any])
        let report = expect["report"] as? String
        return CatalogRevisionReportCase(
            id: try #require(item["id"] as? String),
            cachedCatalogRevision: try #require((item["cachedCatalogRevision"] as? NSNumber)?.intValue),
            indexAnnounces: try #require((item["indexAnnounces"] as? NSNumber)?.intValue),
            responseRevision: (item["responseRevision"] as? NSNumber)?.intValue,
            indexAfterRefetch: (item["indexAfterRefetch"] as? NSNumber)?.intValue,
            outcome: try #require(expect["outcome"] as? String),
            report: report,
            reports: (expect["reports"] as? NSNumber)?.intValue ?? (report == nil ? 0 : 1),
            etagRefreshed: expect["etag"] as? String == "refreshed",
            requestSent: expect["requestSent"] as? Bool ?? true
        )
    }
}

private func corpusFile(_ relative: String) throws -> Data {
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

private func okStub(_ data: [String: Any], etag: String) throws -> CatalogRevisionReportMockURLProtocol.Stub {
    let body: [String: Any] = ["code": 0, "data": data, "message": "ok"]
    return .init(
        statusCode: 200,
        headers: ["Etag": etag],
        data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    )
}

/// Maps the integer revision in the fixture to the catalogRevision string of the iOS catalog: the same number always yields the same string.
private func catalogRevisionString(_ revision: Int) -> String {
    "sha256:" + String(repeating: String(revision, radix: 16), count: 64)
}

/// Cache 0 is the bundled snapshot / schema 1 generation: its catalog string differs from every online generation.
private let bundledGenerationRevision = "sha256:" + String(repeating: "a", count: 64)

private func schemaV2Index(payloadRevision: Int, catalogRevision: String?) throws -> [String: Any] {
    let corpus = try #require(
        JSONSerialization.jsonObject(with: try corpusFile("shared/model-contracts/metadata_catalog_contract.v1.json"))
            as? [String: Any]
    )
    let response = try #require(corpus["indexResponse"] as? [String: Any])
    var index = try #require(response["data"] as? [String: Any])
    let providers = try #require(index["providers"] as? [String: Any])
    var anthropic = try #require(providers["anthropic"] as? [String: Any])
    anthropic["catalogRevision"] = catalogRevision
    index["providers"] = ["anthropic": anthropic]
    index["metadataSchema"] = 2
    index["metadataRevision"] = payloadRevision
    index["generatedAt"] = "2026-10-19T00:00:00Z"
    return index
}

private func schemaV2Catalog(payloadRevision: Int, catalogRevision: String, models: [String: Any]) -> [String: Any] {
    [
        "view": "catalog",
        "provider": "anthropic",
        "catalogRevision": catalogRevision,
        "models": models,
        "resolveMap": Dictionary(uniqueKeysWithValues: models.keys.map { ($0, $0) }),
        "metadataSchema": 2,
        "metadataRevision": payloadRevision,
        "generatedAt": "2026-10-19T00:00:00Z",
    ]
}

@Suite("Shared catalog-revision-report cases one by one: catalog revision decisions and reporting", .serialized, .sharedProcessState)
struct CatalogRevisionReportContractTests {

    private static let expectedIDs: Set<String> = [
        "catalog_zero_then_zero_accepts",
        "catalog_regressed_refused",
        "catalog_equal_matches_index_unchanged",
        "catalog_equal_index_newer_then_settles",
        "catalog_equal_index_still_newer_reports_once",
        "catalog_newer_accepts",
    ]

    @Test("The fixture id set maps one-to-one onto this suite's cases")
    func fixtureIDsAreLocked() throws {
        #expect(Set(try reportFixtureCases().map(\.id)) == Self.expectedIDs)
    }

    @Test("CATALOG_REVISION_REPORT_catalog_zero_then_zero_accepts")
    func catalogZeroThenZeroAccepts() async throws {
        try await runCase("catalog_zero_then_zero_accepts")
    }

    @Test("CATALOG_REVISION_REPORT_catalog_regressed_refused")
    func catalogRegressedRefused() async throws {
        try await runCase("catalog_regressed_refused")
    }

    @Test("CATALOG_REVISION_REPORT_catalog_equal_matches_index_unchanged")
    func catalogEqualMatchesIndexUnchanged() async throws {
        try await runCase("catalog_equal_matches_index_unchanged")
    }

    @Test("CATALOG_REVISION_REPORT_catalog_equal_index_newer_then_settles")
    func catalogEqualIndexNewerThenSettles() async throws {
        try await runCase("catalog_equal_index_newer_then_settles")
    }

    @Test("CATALOG_REVISION_REPORT_catalog_equal_index_still_newer_reports_once")
    func catalogEqualIndexStillNewerReportsOnce() async throws {
        try await runCase("catalog_equal_index_still_newer_reports_once")
    }

    @Test("CATALOG_REVISION_REPORT_catalog_newer_accepts")
    func catalogNewerAccepts() async throws {
        try await runCase("catalog_newer_accepts")
    }

    /// First land the provider's catalog cache at cachedCatalogRevision, then run one production forceRefresh with the index announcement and catalog response from the fixture.
    private func runCase(_ id: String) async throws {
        let item = try #require(try reportFixtureCases().first { $0.id == id })
        let recorder = CatalogRevisionReportRecorder()
        let client = MetadataClient(
            session: CatalogRevisionReportMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, context in recorder.record(context: context) },
            requestedMetadataSchema: MetadataClient.requestedMetadataSchema
        )
        await client.resetForTesting()
        client.registerConfiguredProviders([TestFactories.makeProvider(kind: .anthropic, models: [])])

        // Seed the cache: the catalog string of the cache-0 generation differs from every online generation.
        let cachedRevisionString = item.cachedCatalogRevision == 0
            ? bundledGenerationRevision
            : catalogRevisionString(item.cachedCatalogRevision)
        CatalogRevisionReportMockURLProtocol.reset()
        CatalogRevisionReportMockURLProtocol.stub("index", [try okStub(
            try schemaV2Index(payloadRevision: 1, catalogRevision: cachedRevisionString), etag: "index-seed"
        )])
        CatalogRevisionReportMockURLProtocol.stub("catalog:anthropic", [try okStub(schemaV2Catalog(
            payloadRevision: item.cachedCatalogRevision,
            catalogRevision: cachedRevisionString,
            models: ["m-seed": ["displayName": "Seed"]]
        ), etag: "catalog-seed")])
        await client.forceRefresh()
        #expect(client.resolveCatalogModel(modelID: "m-seed", providerKind: .anthropic)?.displayName == "Seed", "\(id)")
        #expect(
            await client.splitPayloadRevisionsForTesting().catalogs["anthropic"] == .some(item.cachedCatalogRevision),
            "\(id)"
        )
        let seededEventCount = recorder.snapshot().count

        // This case: the index announces indexAnnounces truthfully; when the announcement equals the cached string production sends no catalog request (fixture requestSent=false).
        var indexStubs = [try okStub(
            try schemaV2Index(payloadRevision: 2, catalogRevision: catalogRevisionString(item.indexAnnounces)),
            etag: "index-case"
        )]
        if let after = item.indexAfterRefetch {
            indexStubs.append(try okStub(
                try schemaV2Index(payloadRevision: 3, catalogRevision: catalogRevisionString(after)),
                etag: "index-refetched"
            ))
        }
        CatalogRevisionReportMockURLProtocol.stub("index", indexStubs)
        // The case that must not send a request also gets a new catalog: if production sends one by mistake, the assertions below catch it.
        let responseRevision = item.responseRevision ?? item.cachedCatalogRevision + 1
        CatalogRevisionReportMockURLProtocol.stub("catalog:anthropic", [try okStub(schemaV2Catalog(
            payloadRevision: responseRevision,
            catalogRevision: catalogRevisionString(responseRevision),
            models: ["m-new": ["displayName": "New"]]
        ), etag: "catalog-case")])
        await client.forceRefresh()

        #expect(
            CatalogRevisionReportMockURLProtocol.requestedRoutes().contains("catalog:anthropic") == item.requestSent,
            "\(id)"
        )
        let seed = client.resolveCatalogModel(modelID: "m-seed", providerKind: .anthropic)?.displayName
        let fresh = client.resolveCatalogModel(modelID: "m-new", providerKind: .anthropic)?.displayName
        let payloadRevision = await client.splitPayloadRevisionsForTesting().catalogs["anthropic"]
        let row = try await client.splitCacheRowsForTesting()["catalog:anthropic"]
        switch item.outcome {
        case "accept":
            #expect(fresh == "New", "\(id)")
            #expect(seed == nil, "\(id)")
            #expect(payloadRevision == .some(responseRevision), "\(id)")
            #expect(row?.etag == "catalog-case", "\(id)")
        case "unchanged", "reject":
            #expect(seed == "Seed", "\(id)")
            #expect(fresh == nil, "\(id)")
            #expect(payloadRevision == .some(item.cachedCatalogRevision), "\(id)")
            #expect(row?.revision == cachedRevisionString, "\(id) must not rewrite the body")
            #expect(row?.etag == (item.etagRefreshed ? "catalog-case" : "catalog-seed"), "\(id)")
        default:
            Issue.record("unknown outcome \(item.outcome) in \(id)")
        }

        // Only count the revision reports of this sync; a catalog_revision tag without a reason must never appear.
        let revisionReports = recorder.snapshot().dropFirst(seededEventCount).filter {
            ($0["operation"] ?? "").hasPrefix("catalog_revision")
        }
        let expectedReports = item.report.map { report in
            Array(repeating: ["operation": "catalog_\(report)", "reason": report, "provider": "anthropic"], count: item.reports)
        } ?? []
        #expect(Array(revisionReports) == expectedReports, "\(id)")
        await client.resetForTesting()
    }
}
