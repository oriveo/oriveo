import Foundation
import Testing
@testable import Oriveo

final class VoiceCatalogClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// VoiceCatalogClient fetching, caching and state.
@Suite("Voice catalog client", .serialized)
struct VoiceCatalogClientTests {

    // MARK: Fixtures

    private static let baseURL = "https://voice-catalog.test"

    private static func catalogData(model: String, view: String = "voice") -> [String: Any] {
        [
            "view": view,
            "schemaVersion": 2,
            "revision": "rev-\(model)",
            "providers": [
                "openAI": [
                    "stt": [[
                        "model": model,
                        "transport": "openai_transcriptions",
                        "path": "/v1/audio/transcriptions",
                        "maxBytes": 25_000_000,
                        "maxDurationSec": 600,
                        "isDefault": true,
                    ]],
                ],
            ],
        ]
    }

    private static func envelope(_ data: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": 0, "data": data, "message": "ok"])
    }

    private static func response(_ status: Int, etag: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let etag { headers["Etag"] = etag }
        return HTTPURLResponse(
            url: URL(string: "\(baseURL)/api/metadata?view=voice")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCatalogClientURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCatalogClientTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeClient(directory: URL) -> VoiceCatalogClient {
        VoiceCatalogClient(session: makeSession(), cacheDirectory: directory, baseURL: { baseURL })
    }

    private static func reset(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        VoiceCatalogClientURLProtocol.requestHandler = handler
        VoiceCatalogClientURLProtocol.capturedRequests = []
    }

    private static func sttModels(_ state: VoiceCatalogState) -> [String]? {
        state.catalog?.sttEntries(.openAI).map(\.model)
    }

    /// Primes the cache with one 200 response first (ETag = "v1", model m1).
    private static func primedClient(directory: URL) async throws -> VoiceCatalogClient {
        let body = try envelope(catalogData(model: "m1"))
        reset { _ in (response(200, etag: "\"v1\""), body) }
        let client = makeClient(directory: directory)
        let state = await client.refresh()
        #expect(sttModels(state) == ["m1"])
        return client
    }

    // MARK: Cases

    @Test("200 decodes and writes the cache")
    func okDecodesAndCaches() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = try Self.envelope(Self.catalogData(model: "m1"))
        Self.reset { _ in (Self.response(200, etag: "\"v1\""), body) }

        let client = Self.makeClient(directory: directory)
        #expect(await client.state == nil)
        let state = await client.refresh()

        #expect(Self.sttModels(state) == ["m1"])
        #expect(state.catalog?.revision == "rev-m1")
        #expect(await client.state == state)
        let request = try #require(VoiceCatalogClientURLProtocol.capturedRequests.first)
        #expect(request.url?.absoluteString == "\(Self.baseURL)/api/metadata?view=voice")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)

        let cacheURL = directory.appendingPathComponent("catalog.json")
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("304 uses the cache and sends If-None-Match")
    func notModifiedUsesCache() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await Self.primedClient(directory: directory)

        Self.reset { _ in (Self.response(304), Data()) }
        let state = await client.refresh()

        #expect(Self.sttModels(state) == ["m1"])
        let request = try #require(VoiceCatalogClientURLProtocol.capturedRequests.first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test("404 → unavailable")
    func notFoundIsUnavailable() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await Self.primedClient(directory: directory)

        Self.reset { _ in (Self.response(404), Data()) }
        #expect(await client.refresh() == .unavailable)
        #expect(await client.state == .unavailable)
        // "Unavailable" is the server's verdict: a cold start no longer reads the old catalog.
        #expect(await Self.makeClient(directory: directory).state == nil)
    }

    @Test("5xx / network errors keep the previous catalog")
    func failureKeepsPrevious() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await Self.primedClient(directory: directory)

        Self.reset { _ in (Self.response(503), Data("{}".utf8)) }
        #expect(Self.sttModels(await client.refresh()) == ["m1"])

        Self.reset { _ in throw URLError(.notConnectedToInternet) }
        #expect(Self.sttModels(await client.refresh()) == ["m1"])

        // A failure leaves the cache untouched: a following 304 still uses the previous catalog.
        Self.reset { _ in (Self.response(304), Data()) }
        #expect(Self.sttModels(await client.refresh()) == ["m1"])
    }

    @Test("Failure without a cache gives loadFailed")
    func failureWithoutCacheIsLoadFailed() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        Self.reset { _ in (Self.response(500), Data()) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)

        Self.reset { _ in throw URLError(.timedOut) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)

        // Without a cache, a 304 cannot be trusted either.
        Self.reset { _ in (Self.response(304), Data()) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)

        // 200 but the envelope is wrong.
        let notJSON = Data("not json".utf8)
        Self.reset { _ in (Self.response(200), notJSON) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)
    }

    @Test("data.view != voice counts as a failure")
    func wrongViewIsFailure() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let wrongView = try Self.envelope(Self.catalogData(model: "m2", view: "index"))
        Self.reset { _ in (Self.response(200, etag: "\"x\""), wrongView) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog.json").path))

        let missingView = try Self.envelope(["schemaVersion": 2, "providers": [:]] as [String: Any])
        Self.reset { _ in (Self.response(200), missingView) }
        #expect(await Self.makeClient(directory: directory).refresh() == .loadFailed)

        // With a cache, a wrong view still keeps the previous catalog.
        let client = try await Self.primedClient(directory: directory)
        Self.reset { _ in (Self.response(200, etag: "\"x\""), wrongView) }
        #expect(Self.sttModels(await client.refresh()) == ["m1"])
    }

    @Test("Cold start reads the cache")
    func coldStartReadsCache() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await Self.primedClient(directory: directory)

        Self.reset(nil)
        let coldClient = Self.makeClient(directory: directory)
        let coldState = try #require(await coldClient.state)
        #expect(Self.sttModels(coldState) == ["m1"])
        #expect(coldState.catalog?.revision == "rev-m1")
        #expect(VoiceCatalogClientURLProtocol.capturedRequests.isEmpty)

        // A refresh after a cold start sends the cached ETag.
        Self.reset { _ in (Self.response(304), Data()) }
        #expect(Self.sttModels(await coldClient.refresh()) == ["m1"])
        let request = try #require(VoiceCatalogClientURLProtocol.capturedRequests.first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test("refresh pushes a new state to subscribers once; an unchanged state is not pushed")
    func refreshNotifiesSubscribersOnChange() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try await Self.primedClient(directory: directory)
        let recorder = VoiceCatalogStateRecorder()
        let initial = await client.subscribe { state in await recorder.append(state) }
        #expect(initial.map(Self.sttModels) == ["m1"])

        let body = try Self.envelope(Self.catalogData(model: "m2"))
        Self.reset { _ in (Self.response(200, etag: "\"v2\""), body) }
        await client.refresh()
        #expect(await recorder.states.map(Self.sttModels) == [["m2"]])

        // Both a 304 and a network failure keep the same catalog: nothing is pushed.
        Self.reset { _ in (Self.response(304), Data()) }
        await client.refresh()
        Self.reset(nil)
        await client.refresh()
        #expect(await recorder.states.count == 1)

        Self.reset { _ in (Self.response(404), Data()) }
        await client.refresh()
        #expect(await recorder.states.last == .unavailable)
        #expect(await recorder.states.count == 2)
    }
}

private actor VoiceCatalogStateRecorder {
    private(set) var states: [VoiceCatalogState] = []

    func append(_ state: VoiceCatalogState) {
        states.append(state)
    }
}
