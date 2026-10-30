import Foundation
import Testing
@testable import Oriveo

/// URLProtocol stub for external search: queues replies by host and records every request received. No network.
private final class SearchStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(status: Int, body: Data, headers: [String: String] = [:])
        case notModified
        case redirect(to: String, status: Int = 302)
        /// A large response without Content-Length, forcing the executor to count as it reads.
        case oversized(bytes: Int)
    }

    struct Captured {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var captured: [Captured] = []

    static func reset() {
        lock.withLock {
            replies = [:]
            captured = []
        }
    }

    static func enqueue(host: String, _ reply: Reply) {
        lock.withLock { replies[host, default: []].append(reply) }
    }

    static func requests(host: String? = nil) -> [Captured] {
        lock.withLock { captured.filter { host == nil || $0.request.url?.host == host } }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let body = Self.readBody(request)
        let reply: Reply? = Self.lock.withLock {
            Self.captured.append(Captured(request: request, body: body))
            guard var queue = Self.replies[host], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            Self.replies[host] = queue
            return first
        }
        switch reply {
        case .json(let status, let data, let headers)?:
            respond(url: url, status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, chunks: [data])
        case .notModified?:
            respond(url: url, status: 304, headers: [:], chunks: [])
        case .redirect(let location, let status)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = request
            next.url = URL(string: location)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case .oversized(let count)?:
            let chunk = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024)
            respond(url: url, status: 200, headers: [:], chunks: Array(repeating: chunk, count: count / chunk.count + 1))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    private func respond(url: URL, status: Int, headers: [String: String], chunks: [Data]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Network paths of the executor and catalog loading: golden replay, host verification, redirects, oversized responses, LAN IP pinning, catalog cache / built-in / network adoption.
/// Fixtures: shared/search-contracts/transport-golden.v1.json, shared/search-contracts/search_catalog_contract.v1.json,
/// shared/search-contracts/search_catalog_view.v1.json.
@Suite("External search executor and catalog loading (URLProtocol stub)", .serialized)
struct SearchNetworkTests {
    private static let goldenPath = "shared/search-contracts/transport-golden.v1.json"
    private static let contractPath = "shared/search-contracts/search_catalog_contract.v1.json"
    private static let viewPath = "shared/search-contracts/search_catalog_view.v1.json"

    private static func catalog() throws -> SearchJSON {
        try #require(try SearchContractSupport.load(contractPath)["catalog"])
    }

    private static func goldenCase(_ id: String) throws -> SearchJSON {
        let cases = try #require(try SearchContractSupport.load(goldenPath)["cases"]?.arrayValue)
        return try #require(cases.first { $0["caseId"]?.stringValue == id })
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("search-tests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Executor

    @Test("Golden replay: the request sent matches deepseek.cn.request, and the response mapping matches deepseek.normal")
    func goldenReplayThroughExecutor() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("deepseek", in: try Self.catalog()))
        let requestCase = try Self.goldenCase("deepseek.cn.request")
        let responseCase = try Self.goldenCase("deepseek.normal")
        let input = try #require(requestCase["input"])
        SearchStubProtocol.enqueue(host: "api.deepseek.com", .json(status: 200, body: try #require(responseCase["body"]).encodedData()))

        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false,
            query: input["query"]?.stringValue ?? "", count: input["count"]?.safeIntegerValue, key: input["key"]?.stringValue
        )

        guard case .results(let items) = outcome else {
            Issue.record("expected results, got \(outcome)")
            return
        }
        #expect(try SearchContractSupport.json(items) == responseCase["expect"]?["results"])
        let captured = try #require(SearchStubProtocol.requests(host: "api.deepseek.com").first)
        let expect = try #require(requestCase["expect"])
        let expectedHeaderNames = Set(expect["headers"]?.objectValue?.keys ?? [])
        let headers = (captured.request.allHTTPHeaderFields ?? [:]).filter {
            expectedHeaderNames.contains($0.key) || RelayRequestSecurity.isSensitiveName($0.key)
        }
        let sent = SearchHTTPRequest(
            method: captured.request.httpMethod ?? "",
            url: captured.request.url?.absoluteString ?? "",
            headers: headers,
            body: try captured.body.map { try SearchJSON.parse($0) }
        )
        let problems = SearchContractSupport.requestMismatches(sent, expect: expect)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("Host does not match the catalog: no request and no key sent, yields host_changed")
    func hostChangedSendsNothing() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("deepseek", in: try Self.catalog()))
        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "cn", boundHost: "search.deepseek.com", withdrawn: false,
            query: "q", count: 5, key: "sk-test-0000"
        )
        guard case .failure(let classification) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(classification.errorClass == "host_changed")
        #expect(SearchStubProtocol.requests().isEmpty)
    }

    @Test("Empty query: no request sent, treated as no results")
    func blankQuerySendsNothing() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("deepseek", in: try Self.catalog()))
        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, query: "  \n ", count: 5, key: "sk-test-0000"
        )
        #expect(outcome == .empty)
        #expect(SearchStubProtocol.requests().isEmpty)
    }

    @Test("Same-origin https redirect: followed, the key is sent to the new path and results are obtained")
    func sameOriginRedirectIsFollowed() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("tavily", in: try Self.catalog()))
        let host = try #require(SearchCatalog.region(of: entry, id: "global")?["host"]?.stringValue)
        SearchStubProtocol.enqueue(host: host, .redirect(to: "https://\(host)/v2/search"))
        SearchStubProtocol.enqueue(host: host, .json(status: 200, body: Data(#"{"results":[{"url":"https://moved.example/","title":"moved","content":"c"}]}"#.utf8)))

        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "global", boundHost: host, withdrawn: false, query: "q", count: 5, key: "tvly-test-0000"
        )

        #expect(outcome == .results([SearchResultItem(title: "moved", url: "https://moved.example/", snippet: "c", site: nil, date: nil)]))
        let requests = SearchStubProtocol.requests(host: host)
        #expect(requests.map { $0.request.url?.path } == ["/search", "/v2/search"])
        #expect(requests.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-test-0000")
    }

    @Test("Same-origin redirect rewrites the method: under 302 POST → GET with no body and no Content-Type; under 307 POST and body are preserved as is")
    func redirectRewritesMethodPerContract() async throws {
        let entry = try #require(SearchContractSupport.service("deepseek", in: try Self.catalog()))
        let results = Data(#"{"results":[{"url":"https://r.example/","title":"r","summary":"s"}]}"#.utf8)
        for (status, expectsPost) in [(302, false), (307, true)] {
            SearchStubProtocol.reset()
            SearchStubProtocol.enqueue(host: "api.deepseek.com", .redirect(to: "https://api.deepseek.com/v2/search", status: status))
            SearchStubProtocol.enqueue(host: "api.deepseek.com", .json(status: 200, body: results))

            let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
                entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, query: "oriveo", count: 5, key: "sk-test-0000"
            )

            #expect(outcome == .results([SearchResultItem(title: "r", url: "https://r.example/", snippet: "s", site: nil, date: nil)]), "\(status)")
            let requests = SearchStubProtocol.requests(host: "api.deepseek.com")
            #expect(requests.count == 2, "\(status)")
            guard let first = requests.first, let second = requests.last else { continue }
            #expect(first.request.httpMethod == "POST")
            #expect(second.request.url?.path == "/v2/search", "\(status)")
            if expectsPost {
                #expect(second.request.httpMethod == "POST", "\(status)")
                #expect(second.body == first.body, "\(status)")
                #expect(second.request.value(forHTTPHeaderField: "Content-Type") == "application/json", "\(status)")
            } else {
                #expect(second.request.httpMethod == "GET", "\(status)")
                #expect((second.body ?? Data()).isEmpty, "\(status)")
                #expect(second.request.value(forHTTPHeaderField: "Content-Type") == nil, "\(status)")
            }
        }
    }

    @Test("Cross-origin redirect: aborted, nothing is sent to the new host, recorded as blocked and classified as request_rejected")
    func crossOriginRedirectIsAborted() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("tavily", in: try Self.catalog()))
        let host = try #require(SearchCatalog.region(of: entry, id: "global")?["host"]?.stringValue)
        SearchStubProtocol.enqueue(host: host, .redirect(to: "https://collector.example/search"))
        SearchStubProtocol.enqueue(host: "collector.example", .json(status: 200, body: Data(#"{"results":[{"url":"https://leak.example/","title":"leak"}]}"#.utf8)))

        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "global", boundHost: host, withdrawn: false, query: "q", count: 5, key: "tvly-test-0000"
        )

        guard case .failure(let classification) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(classification.errorClass == "request_rejected")
        #expect(SearchStubProtocol.requests(host: "collector.example").isEmpty)
        #expect(SearchStubProtocol.requests(host: host).count == 1)
    }

    @Test("Same-origin redirect over 5 hops: aborted at the 6th hop, classified as request_rejected")
    func redirectChainLongerThanFiveIsAborted() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("tavily", in: try Self.catalog()))
        let host = try #require(SearchCatalog.region(of: entry, id: "global")?["host"]?.stringValue)
        for hop in 1...6 { SearchStubProtocol.enqueue(host: host, .redirect(to: "https://\(host)/hop\(hop)")) }

        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "global", boundHost: host, withdrawn: false, query: "q", count: 5, key: "tvly-test-0000"
        )

        guard case .failure(let classification) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(classification.errorClass == "request_rejected")
        #expect(SearchStubProtocol.requests(host: host).count == 1 + SearchTaskDelegate.maxRedirects)
    }

    @Test("Response over 2 MB: aborted with response_too_large")
    func oversizedResponseIsAborted() async throws {
        SearchStubProtocol.reset()
        let entry = try #require(SearchContractSupport.service("deepseek", in: try Self.catalog()))
        SearchStubProtocol.enqueue(host: "api.deepseek.com", .oversized(bytes: SearchHardLimits.maxResponseBytes + 1))
        let outcome = await SearchExecutor(session: SearchStubProtocol.session()).runPreset(
            entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, query: "q", count: 5, key: "sk-test-0000"
        )
        guard case .failure(let classification) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(classification.errorClass == "response_too_large")
    }

    @Test("LAN http SearXNG: sent only if it resolves to a private network, and pinned to the resolved IP; not sent if it resolves to a public address")
    func cleartextLANIsPinnedAndPublicIsBlocked() async throws {
        SearchStubProtocol.reset()
        let address = try #require(SearchTransport.parseServiceAddress("http://nas.local:8080/searxng/"))
        let body = Data(#"{"results":[{"url":"https://searxng.org/","title":"SearXNG","content":"ok"}]}"#.utf8)
        SearchStubProtocol.enqueue(host: "192.168.1.20", .json(status: 200, body: body))

        let lan = SearchExecutor(session: SearchStubProtocol.session(), resolver: { _ in ["192.168.1.20"] })
        let outcome = await lan.runCustom(
            spec: SearchTransport.searxngSpec, address: address, requestPath: SearchTransport.searxngPath(address.path),
            query: "oriveo", count: 5, key: nil
        )
        #expect(outcome == .results([SearchResultItem(title: "SearXNG", url: "https://searxng.org/", snippet: "ok", site: nil, date: nil)]))
        let pinned = try #require(SearchStubProtocol.requests(host: "192.168.1.20").first)
        #expect(pinned.request.value(forHTTPHeaderField: "Host") == "nas.local:8080")
        #expect(pinned.request.url?.path == "/searxng/search")

        let publicResolver = SearchExecutor(session: SearchStubProtocol.session(), resolver: { _ in ["93.184.216.34"] })
        let blocked = await publicResolver.runCustom(
            spec: SearchTransport.searxngSpec, address: address, requestPath: "/searxng/search", query: "oriveo", count: 5, key: nil
        )
        guard case .failure = blocked else {
            Issue.record("expected failure, got \(blocked)")
            return
        }
        #expect(SearchStubProtocol.requests(host: "93.184.216.34").isEmpty)
    }

    // MARK: Catalog loading

    @Test("Production load path: the bundled search_catalog_view.v1.json is byte-identical to the shared fixture and is adopted with the production public key as 7 active")
    func bundledSnapshotIsAcceptedWithProductionKeys() async throws {
        let bundled = try #require(SearchCatalogStore.bundledSnapshotData())
        #expect(bundled == (try Data(contentsOf: SearchContractSupport.repoRoot.appendingPathComponent(Self.viewPath))))

        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchCatalogStore(session: SearchStubProtocol.session(), cacheDirectory: directory)
        await store.ensureLoaded()
        let state = await store.state
        #expect(state.current?.services.count == 7)
        #expect(state.current?.services.allSatisfy { $0.status == .active } == true)
        #expect(await store.activeEntry("deepseek")?["regions"]?.arrayValue?.isEmpty == false)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Catalog 404: the whole preset block is unavailable (including cache and built-in), still unavailable after restart; recovers once a 200 is received and adopted")
    func notFoundWithdrawsPresetsAcrossRestart() async throws {
        SearchStubProtocol.reset()
        let contract = try SearchContractSupport.load(Self.contractPath)
        let keyID = try #require(contract["testKeys"]?["keyId"]?.stringValue)
        let publicKey = try #require(contract["testKeys"]?["publicKeyB64"]?.stringValue)
        let envelope: SearchJSON = ["code": 0, "data": try #require(contract["catalog"]), "message": "ok"]
        let envelopeData = envelope.encodedData()
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeStore() -> SearchCatalogStore {
            SearchCatalogStore(
                session: SearchStubProtocol.session(), cacheDirectory: directory, trustedKeys: [keyID: publicKey],
                baseURL: { "https://catalog.test" }, bundledData: { envelopeData }
            )
        }

        let store = makeStore()
        await store.ensureLoaded()
        #expect(await store.isAvailable)
        SearchStubProtocol.enqueue(host: "catalog.test", .json(status: 404, body: Data(#"{"code":404}"#.utf8)))
        _ = await store.refresh()
        #expect(await store.isAvailable == false)
        #expect(await store.activeEntry("deepseek") == nil)

        let restarted = makeStore()
        await restarted.ensureLoaded()
        #expect(await restarted.isAvailable == false)
        #expect(await restarted.presetsWithdrawn)

        // Other statuses (including an older server's 400) keep the current state and do not lift the revocation
        SearchStubProtocol.enqueue(host: "catalog.test", .json(status: 400, body: Data()))
        _ = await restarted.refresh()
        #expect(await restarted.isAvailable == false)

        // A 200 with the same revision this device has seen after revocation: recovers as soon as signature verification passes
        let seenRevision = await restarted.state.maxSeenRevision
        #expect(seenRevision == contract["catalog"]?["revision"]?.safeIntegerValue)
        SearchStubProtocol.enqueue(host: "catalog.test", .json(status: 200, body: envelopeData))
        let recovered = await restarted.refresh()
        #expect(recovered?.accepted == true)
        #expect(await restarted.isAvailable)
        #expect(await restarted.state.current?.revision == seenRevision)

        let again = makeStore()
        await again.ensureLoaded()
        #expect(await again.isAvailable)
        #expect(await again.presetsWithdrawn == false)
    }

    @Test("Network catalog: after adoption, cache and ETag are stored, 304 leaves it unchanged, a tampered catalog is not adopted and the previous one is kept, restart recovers from cache")
    func networkCatalogAdoptionAndCache() async throws {
        SearchStubProtocol.reset()
        let contract = try SearchContractSupport.load(Self.contractPath)
        let keyID = try #require(contract["testKeys"]?["keyId"]?.stringValue)
        let publicKey = try #require(contract["testKeys"]?["publicKeyB64"]?.stringValue)
        let catalog = try #require(contract["catalog"])
        let envelope: SearchJSON = ["code": 0, "data": catalog, "message": "ok"]

        // Tamper: change the first entry's host but keep the original signature
        var tampered = try #require(catalog.objectValue)
        var services = try #require(tampered["services"]?.arrayValue)
        services[0] = SearchContractSupport.modifyingRegion(services[0], id: "cn") { $0["host"] = "evil.example.com" }
        tampered["services"] = .array(services)
        tampered["revision"] = 9

        SearchStubProtocol.enqueue(host: "catalog.test", .json(status: 200, body: envelope.encodedData(), headers: ["Etag": "\"r1\""]))
        SearchStubProtocol.enqueue(host: "catalog.test", .notModified)
        SearchStubProtocol.enqueue(host: "catalog.test", .json(status: 200, body: SearchJSON.object(tampered).encodedData()))

        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeStore() -> SearchCatalogStore {
            SearchCatalogStore(
                session: SearchStubProtocol.session(), cacheDirectory: directory, trustedKeys: [keyID: publicKey],
                baseURL: { "https://catalog.test" }, bundledData: { nil }
            )
        }
        let store = makeStore()
        let first = await store.refresh()
        #expect(first?.accepted == true)
        let revision = try #require(catalog["revision"]?.safeIntegerValue)
        #expect(await store.state.current?.revision == revision)

        _ = await store.refresh()
        let conditional = SearchStubProtocol.requests(host: "catalog.test")
        #expect(conditional.count == 2)
        #expect(conditional.last?.request.value(forHTTPHeaderField: "If-None-Match") == "\"r1\"")
        #expect(conditional.first?.request.url?.query == "view=search")

        let rejected = await store.refresh()
        #expect(rejected?.accepted == false)
        #expect(rejected?.reason == "signature_invalid")
        #expect(await store.state.current?.revision == revision)

        let restarted = makeStore()
        await restarted.ensureLoaded()
        #expect(await restarted.state.current?.revision == revision)
        #expect(await restarted.state.maxSeenRevision == revision)
    }
}
