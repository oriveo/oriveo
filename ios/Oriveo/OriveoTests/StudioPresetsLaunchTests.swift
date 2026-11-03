import Foundation
import Testing
@testable import Oriveo

/// StudioPresetsLaunch: a hidden entry never touches the store; a visible one refreshes with the
/// resolved locale and, only when the body was replaced, prunes the sample cache to the samples of
/// the current styles. Real store and sample cache over temporary directories and a fake
/// transport.
@Suite("StudioPresetsLaunchTests")
struct StudioPresetsLaunchTests {
    private static let t0: Int64 = 1_800_000_000_000
    private static let keptSha = String(repeating: "a", count: 64)
    private static let staleSha = String(repeating: "b", count: 64)

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

    /// Counts sample downloads; the launch path must never prefetch images.
    actor DownloadCounter {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    private static func envelope(revision: String, locale: String, sampleSha: String) -> Data {
        let text = """
        {"code":0,"message":"ok","data":{"contractId":"studio_presets.v1","revision":"\(revision)",\
        "locale":"\(locale)","styleGroups":[{"id":"g","order":0,"displayName":"Group"}],\
        "effectGroups":[{"id":"fx","order":0,"displayName":"Effects"}],\
        "styles":[{"id":"remote-style","group":"g","order":0,"displayName":"Remote","promptFragment":"remote look",\
        "sample":{"url":"/samples/remote.png","width":512,"height":512,"sha256":"\(sampleSha)"}}],\
        "effects":[]}}
        """
        return Data(text.utf8)
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioPresetsLaunchTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStore(_ directory: URL, _ server: FakeServer) -> StudioPresetsStore {
        StudioPresetsStore(
            transport: { request in try await server.handle(request) },
            cacheDirectory: directory.appendingPathComponent("presets", isDirectory: true),
            baseURL: { "https://presets.test" },
            clock: { t0 }
        )
    }

    private static func sampleRoot(_ directory: URL) -> URL {
        directory.appendingPathComponent("samples", isDirectory: true)
    }

    private static func makeSampleCache(_ directory: URL, _ counter: DownloadCounter) -> StudioPresetSampleCache {
        StudioPresetSampleCache(
            root: sampleRoot(directory),
            baseURL: { "https://presets.test" },
            download: { _ in
                await counter.hit()
                return nil
            }
        )
    }

    /// Writes one stored sample entry per key, as the cache would.
    private static func seedSamples(_ directory: URL, _ keys: [String]) throws {
        let root = sampleRoot(directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for key in keys {
            try Data("bytes-\(key.prefix(1))".utf8).write(to: root.appending(path: key))
        }
    }

    private static func storedSamples(_ directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sampleRoot(directory).path)) ?? []
        return Set(names)
    }

    private static func requestedLocales(_ server: FakeServer) async -> [String?] {
        await server.requests.map { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "locale" }?.value
        }
    }

    /// A hidden entry returns nil without calling the store or touching the sample cache.
    @Test func testHiddenEntrySkipsRefresh() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.seedSamples(directory, [Self.keptSha, Self.staleSha])
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: Self.envelope(revision: "r1", locale: "en", sampleSha: Self.keptSha))])
        let counter = DownloadCounter()

        let outcome = await StudioPresetsLaunch.run(
            entryVisible: false,
            appLanguageTag: "en",
            store: Self.makeStore(directory, server),
            sampleCache: Self.makeSampleCache(directory, counter)
        )

        #expect(outcome == nil)
        #expect(await server.requests.isEmpty)
        #expect(Self.storedSamples(directory) == [Self.keptSha, Self.staleSha])
        #expect(await counter.count == 0)
    }

    /// A visible entry refreshes once with the locale resolved from the app language tag.
    @Test func testVisibleEntryRefreshesWithLocale() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "r1", locale: "zh-Hant", sampleSha: Self.keptSha)
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let store = Self.makeStore(directory, server)

        let outcome = await StudioPresetsLaunch.run(
            entryVisible: true,
            appLanguageTag: "zh_TW",
            store: store,
            sampleCache: Self.makeSampleCache(directory, DownloadCounter())
        )

        #expect(outcome == .replaced)
        #expect(await Self.requestedLocales(server) == ["zh-Hant"])
        let current = try #require(await store.current(locale: "zh-Hant"))
        #expect(current.revision == "r1")
    }

    /// A replaced body prunes the sample cache to the current styles' samples, with no prefetch.
    @Test func testReplacedPrunesToCurrentSamples() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.seedSamples(directory, [Self.keptSha, Self.staleSha])
        let body = Self.envelope(revision: "r1", locale: "en", sampleSha: Self.keptSha)
        let server = FakeServer([.http(status: 200, etag: "\"e1\"", body: body)])
        let counter = DownloadCounter()

        let outcome = await StudioPresetsLaunch.run(
            entryVisible: true,
            appLanguageTag: "en-GB",
            store: Self.makeStore(directory, server),
            sampleCache: Self.makeSampleCache(directory, counter)
        )

        #expect(outcome == .replaced)
        #expect(await Self.requestedLocales(server) == ["en"])
        #expect(Self.storedSamples(directory) == [Self.keptSha])
        #expect(await counter.count == 0)
    }

    /// Any other outcome (failed, unchanged, throttled) leaves the sample cache alone.
    @Test func testNonReplacedKeepsSamples() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Self.envelope(revision: "r1", locale: "en", sampleSha: Self.keptSha)
        let server = FakeServer([
            .http(status: 500, etag: nil, body: Data("oops".utf8)),
            .http(status: 200, etag: "\"e1\"", body: body),
            .http(status: 200, etag: "\"e2\"", body: body),
        ])
        let store = Self.makeStore(directory, server)
        let cache = Self.makeSampleCache(directory, DownloadCounter())

        try Self.seedSamples(directory, [Self.keptSha, Self.staleSha])
        let failed = await StudioPresetsLaunch.run(entryVisible: true, appLanguageTag: "en", store: store, sampleCache: cache)
        #expect(failed == .failed)
        #expect(Self.storedSamples(directory) == [Self.keptSha, Self.staleSha])

        let replaced = await StudioPresetsLaunch.run(entryVisible: true, appLanguageTag: "en", store: store, sampleCache: cache)
        #expect(replaced == .replaced)
        #expect(Self.storedSamples(directory) == [Self.keptSha])

        try Self.seedSamples(directory, [Self.staleSha])
        let throttled = await StudioPresetsLaunch.run(entryVisible: true, appLanguageTag: "en", store: store, sampleCache: cache)
        #expect(throttled == .throttled)
        #expect(Self.storedSamples(directory) == [Self.keptSha, Self.staleSha])
        #expect(await server.requests.count == 2)
    }
}
