import Foundation
import Testing
@testable import Oriveo

/// StudioPresetsStore: offline snapshot fallback, persistence of the last accepted body,
/// the 6-hour throttle with If-None-Match, and failure handling. Uses a temporary cache
/// directory and a fake transport.
@Suite("StudioPresetsStoreTests")
struct StudioPresetsStoreTests {
    private static let sixHours = StudioPresets.refreshIntervalMs
    private static let t0: Int64 = 1_800_000_000_000

    /// Scripted server: records every request and answers with the next queued reply
    /// (the last reply repeats).
    actor FakeServer {
        enum Reply {
            case http(status: Int, etag: String?, body: Data)
            case transportError
        }

        private var replies: [Reply]
        private var lastReply: Reply?
        private(set) var requests: [URLRequest] = []

        init(_ replies: [Reply]) {
            self.replies = replies
        }

        func enqueue(_ reply: Reply) {
            replies.append(reply)
        }

        func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            if !replies.isEmpty { lastReply = replies.removeFirst() }
            let reply = lastReply ?? .transportError
            switch reply {
            case .transportError:
                throw URLError(.notConnectedToInternet)
            case .http(let status, let etag, let body):
                let headers = etag.map { ["ETag": $0] } ?? [:]
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://presets.test")!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                return (body, response)
            }
        }
    }

    private static func envelope(revision: String, locale: String, styleId: String) -> Data {
        let text = """
        {"code":0,"message":"ok","data":{"contractId":"studio_presets.v1","revision":"\(revision)",\
        "locale":"\(locale)","styleGroups":[{"id":"g","order":0,"displayName":"Group"}],\
        "effectGroups":[{"id":"fx","order":0,"displayName":"Effects"}],\
        "styles":[{"id":"\(styleId)","group":"g","order":0,"displayName":"Remote","promptFragment":"remote look"}],\
        "effects":[]}}
        """
        return Data(text.utf8)
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioPresetsStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Holds every request until `open()` is called, so concurrent callers overlap.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private static func makeStore(
        _ directory: URL,
        _ server: FakeServer,
        baseURL: String = "https://presets.test",
        gate: Gate? = nil,
        clock: @escaping @Sendable () -> Int64 = { 1_800_000_000_000 }
    ) -> StudioPresetsStore {
        StudioPresetsStore(
            transport: { request in
                await gate?.wait()
                return try await server.handle(request)
            },
            cacheDirectory: directory,
            baseURL: { baseURL },
            clock: clock
        )
    }

    /// Pads a JSON body with trailing spaces up to exactly `size` bytes.
    private static func padded(_ data: Data, to size: Int) -> Data {
        var out = data
        out.append(Data(repeating: 0x20, count: size - data.count))
        return out
    }

    private static func offline(_ tag: String) throws -> StudioPresets.Catalog {
        let snapshot = try #require(StudioPresets.bundledSnapshot(), "bundled snapshot loads")
        return try StudioPresets.decode(StudioPresets.localize(snapshot, tag)).get()
    }

    private static func cacheFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("presets.json", isDirectory: false)
    }

    /// Without a usable cache the store serves the bundled offline snapshot.
    @Test
    func offlineFallsBackToSnapshot() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeServer([])
        let store = Self.makeStore(directory, server)

        let expected = try Self.offline("zh-Hans")
        let current = try #require(await store.current(locale: "zh-Hans"), "offline catalog")
        #expect(current == expected)
        #expect(current.locale == "zh-Hans")
        #expect(!current.styles.isEmpty)
        #expect(await server.requests.isEmpty)

        // A persisted body that no longer decodes falls back to the snapshot too.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let broken = Data(#"{"cache":{"locale":"en","revision":"r","etag":null,"checkedAtMs":1},"body":"bm90IGpzb24="}"#.utf8)
        try broken.write(to: Self.cacheFile(directory))
        let reopened = Self.makeStore(directory, server)
        let fallback = try #require(await reopened.current(locale: "en"), "offline catalog for en")
        let offlineEnglish = try Self.offline("en")
        #expect(fallback == offlineEnglish)
    }

    /// A replaced body is persisted and served by a new store instance.
    @Test
    func replacedPersistsAcrossInstances() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let store = Self.makeStore(directory, server)

        let outcome = await store.refreshIfNeeded(locale: "en", nowMs: Self.t0)
        #expect(outcome == .replaced)
        let requests = await server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://presets.test/api/studio/presets?locale=en")
        #expect(requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)

        let expected = try StudioPresets.decode(body).get()
        let current = try #require(await store.current(locale: "en"))
        #expect(current == expected)
        #expect(current.revision == "rev-remote-1")
        #expect(current.styles.map(\.id) == ["remote-style"])

        let reopened = Self.makeStore(directory, server)
        let persisted = try #require(await reopened.current(locale: "en"))
        #expect(persisted == expected)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// Within six hours of the last check no request is made; after that If-None-Match is sent.
    @Test
    func throttledWithinSixHours() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let store = Self.makeStore(directory, server)

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0) == .replaced)
        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0 + Self.sixHours - 1) == .throttled)
        #expect(await server.requests.count == 1)

        await server.enqueue(.http(status: 304, etag: "\"e1\"", body: Data()))
        _ = await store.refreshIfNeeded(locale: "en", nowMs: Self.t0 + Self.sixHours)
        let requests = await server.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")

        // The injected clock is used when no time is passed (still inside the new window).
        let reopened = Self.makeStore(directory, server, clock: { 1_800_000_000_000 + StudioPresets.refreshIntervalMs + 1 })
        #expect(await reopened.refreshIfNeeded(locale: "en") == .throttled)
        #expect(await server.requests.count == 2)
    }

    /// 304 keeps the cached body and only moves checkedAtMs forward.
    @Test
    func notModifiedKeepsBody() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([
            .http(status: 200, etag: "\"e1\"", body: body),
            .http(status: 304, etag: "\"e1\"", body: Data()),
        ])
        let store = Self.makeStore(directory, server)
        let expected = try StudioPresets.decode(body).get()

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0) == .replaced)
        let later = Self.t0 + Self.sixHours
        #expect(await store.refreshIfNeeded(locale: "en", nowMs: later) == .notModified)
        #expect(await store.current(locale: "en") == expected)

        // checkedAtMs was persisted: a new instance right after the 304 stays throttled.
        let reopened = Self.makeStore(directory, server)
        #expect(await reopened.current(locale: "en") == expected)
        #expect(await reopened.refreshIfNeeded(locale: "en", nowMs: later + 1) == .throttled)
        #expect(await server.requests.count == 2)
    }

    /// Transport errors, HTTP errors and invalid bodies leave the cache file untouched.
    @Test
    func failureKeepsCache() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([
            .http(status: 200, etag: "\"e1\"", body: body),
            .transportError,
            .http(status: 500, etag: nil, body: Data("oops".utf8)),
            .http(status: 200, etag: "\"e2\"", body: Data("not json".utf8)),
        ])
        let store = Self.makeStore(directory, server)
        let expected = try StudioPresets.decode(body).get()

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0) == .replaced)
        let saved = try Data(contentsOf: Self.cacheFile(directory))
        let later = Self.t0 + Self.sixHours

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: later) == .failed)
        #expect(await store.refreshIfNeeded(locale: "en", nowMs: later) == .failed)
        #expect(await store.refreshIfNeeded(locale: "en", nowMs: later) == .invalid)
        // checkedAtMs did not move, so every call above went to the network.
        #expect(await server.requests.count == 4)
        let after = try Data(contentsOf: Self.cacheFile(directory))
        #expect(after == saved)
        #expect(await store.current(locale: "en") == expected)
        #expect(await Self.makeStore(directory, server).current(locale: "en") == expected)
    }

    /// A different locale refetches without If-None-Match and switches the served catalog.
    @Test
    func localeChangeRefetches() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let english = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let chinese = Self.envelope(revision: "rev-remote-1", locale: "zh-Hans", styleId: "remote-style-zh")
        let server = FakeServer([
            .http(status: 200, etag: "\"e1\"", body: english),
            .http(status: 200, etag: "\"e1-zh\"", body: chinese),
        ])
        let store = Self.makeStore(directory, server)

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0) == .replaced)
        #expect(await store.refreshIfNeeded(locale: "zh-Hans", nowMs: Self.t0 + 1) == .replaced)
        let requests = await server.requests
        #expect(requests.count == 2)
        #expect(requests.last?.url?.absoluteString == "https://presets.test/api/studio/presets?locale=zh-Hans")
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)

        let current = try #require(await store.current(locale: "zh-Hans"))
        let expectedChinese = try StudioPresets.decode(chinese).get()
        let offlineEnglish = try Self.offline("en")
        #expect(current == expectedChinese)
        #expect(current.styles.map(\.id) == ["remote-style-zh"])
        #expect(await store.current(locale: "en") == offlineEnglish)

        // Reserved characters in the tag are percent-encoded in the query.
        await server.enqueue(.transportError)
        #expect(await store.refreshIfNeeded(locale: "a&b=c d", nowMs: Self.t0 + 2) == .failed)
        let last = await server.requests.last
        #expect(last?.url?.absoluteString == "https://presets.test/api/studio/presets?locale=a%26b%3Dc%20d")
    }

    /// A persisted record whose body is missing or no longer decodes is planned as no cache:
    /// fetched at once, without If-None-Match, with the fixed request details.
    @Test
    func corruptBodyRefetchesWithoutEtag() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Fresh record (checked 1 ms before) with an ETag, but the body is not JSON.
        let broken = Data(#"{"cache":{"locale":"en","revision":"r0","etag":"\"e0\"","checkedAtMs":1800000000000},"body":"bm90IGpzb24="}"#.utf8)
        try broken.write(to: Self.cacheFile(directory))
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let store = Self.makeStore(directory, server, baseURL: "https://presets.test/")
        let expected = try StudioPresets.decode(body).get()

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0 + 1) == .replaced)
        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://presets.test/api/studio/presets?locale=en")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 15)
        #expect(await store.current(locale: "en") == expected)

        // A record without a body at all is treated the same way.
        let missing = Data(#"{"cache":{"locale":"en","revision":"r0","etag":"\"e0\"","checkedAtMs":1800000000000}}"#.utf8)
        try missing.write(to: Self.cacheFile(directory))
        let reopened = Self.makeStore(directory, server)
        #expect(await reopened.refreshIfNeeded(locale: "en", nowMs: Self.t0 + 1) == .replaced)
        let again = await server.requests
        #expect(again.count == 2)
        #expect(again.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    /// Calls that overlap an in-flight refresh share its single request and its outcome.
    @Test
    func concurrentRefreshSharesOneRequest() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style")
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let gate = Gate()
        let store = Self.makeStore(directory, server, gate: gate)

        async let first = store.refreshIfNeeded(locale: "en", nowMs: Self.t0)
        async let second = store.refreshIfNeeded(locale: "en", nowMs: Self.t0)
        async let third = store.refreshIfNeeded(locale: "en", nowMs: Self.t0)
        // Let all three calls reach the store before the one response is released.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()
        let outcomes = await [first, second, third]

        #expect(outcomes == [.replaced, .replaced, .replaced])
        #expect(await server.requests.count == 1)
        #expect(await store.current(locale: "en") == (try StudioPresets.decode(body).get()))
    }

    /// A 200 body of exactly 1 MiB is accepted; one byte more is invalid and leaves the cache.
    @Test
    func oversizedBodyIsInvalid() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = 1 << 20
        let atLimit = Self.padded(Self.envelope(revision: "rev-remote-1", locale: "en", styleId: "remote-style"), to: limit)
        let over = Self.padded(Self.envelope(revision: "rev-remote-2", locale: "en", styleId: "remote-style-2"), to: limit + 1)
        let server = FakeServer([
            .http(status: 200, etag: "\"e1\"", body: atLimit),
            .http(status: 200, etag: "\"e2\"", body: over),
        ])
        let store = Self.makeStore(directory, server)
        let expected = try StudioPresets.decode(atLimit).get()

        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0) == .replaced)
        let saved = try Data(contentsOf: Self.cacheFile(directory))
        #expect(await store.refreshIfNeeded(locale: "en", nowMs: Self.t0 + Self.sixHours) == .invalid)
        #expect(await server.requests.count == 2)
        #expect(try Data(contentsOf: Self.cacheFile(directory)) == saved)
        #expect(await store.current(locale: "en") == expected)
    }
}
