import CryptoKit
import Foundation
import Testing
@testable import Oriveo

/// Style sample cache: pure helpers against `clientCases.sampleCache` of
/// `shared/studio-contracts/studio_presets.v1.json`, plus the cache itself with an injected
/// downloader and a temporary directory.
@Suite("StudioPresetSampleCacheTests")
struct StudioPresetSampleCacheTests {
    // MARK: Fixture

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func sampleCacheCases() throws -> JSONValue {
        let url = try repoFile(["shared", "studio-contracts", "studio_presets.v1.json"])
        let fixture = try JSONValue(data: Data(contentsOf: url))
        return try #require(fixture["clientCases"]?["sampleCache"], "clientCases.sampleCache")
    }

    private static func cases(_ name: String) throws -> [JSONValue] {
        let cases = try #require(try sampleCacheCases()[name]?.arrayValue, "clientCases.sampleCache.\(name)")
        #expect(!cases.isEmpty, "clientCases.sampleCache.\(name) is empty")
        return cases
    }

    // MARK: Helpers

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

    actor Recorder {
        private(set) var urls: [URL] = []

        func record(_ url: URL) {
            urls.append(url)
        }
    }

    private static let base = "https://samples.test/"
    private static let path = "/api/studio/presets/samples/r1/photo.webp"
    private static let expectedURL = URL(string: "https://samples.test/api/studio/presets/samples/r1/photo.webp")!
    private static let bytes = Data("sample-bytes".utf8)

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sample(_ data: Data = bytes, url: String = path) -> StudioPresets.Sample {
        StudioPresets.Sample(url: url, width: 512, height: 512, sha256: hex(data))
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "StudioPresetSampleCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func makeCache(
        _ root: URL,
        _ recorder: Recorder,
        returning body: Data? = bytes,
        before: (@Sendable () async -> Void)? = nil
    ) -> StudioPresetSampleCache {
        StudioPresetSampleCache(
            root: root,
            baseURL: { base },
            download: { url in
                await recorder.record(url)
                await before?()
                return body
            }
        )
    }

    private static func write(_ data: Data, named name: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appending(path: name))
    }

    // MARK: Pure helpers

    @Test func testFixtureResolveUrl() throws {
        for testCase in try Self.cases("resolveUrl") {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let baseUrl = try #require(testCase["input"]?["baseUrl"]?.stringValue, "\(caseId) baseUrl")
            let url = try #require(testCase["input"]?["url"]?.stringValue, "\(caseId) url")
            let expected = testCase["expect"]?.stringValue
            let actual = StudioPresetSampleCache.resolveSampleURL(base: baseUrl, url: url)?.absoluteString
            #expect(actual == expected, "\(caseId)")
        }
    }

    @Test func testFixtureVerify() throws {
        for testCase in try Self.cases("verify") {
            let caseId = testCase["caseId"]?.stringValue ?? "?"
            let encoded = try #require(testCase["input"]?["bytesBase64"]?.stringValue, "\(caseId) bytesBase64")
            let data = try #require(Data(base64Encoded: encoded), "\(caseId) base64")
            let sha256 = try #require(testCase["input"]?["sha256"]?.stringValue, "\(caseId) sha256")
            let expected = try #require(testCase["expect"]?.stringValue, "\(caseId) expect")
            #expect(StudioPresetSampleCache.verify(data, sha256: sha256).rawValue == expected, "\(caseId)")
        }
    }

    @Test func testPolicyMaxBytes() throws {
        let policy = try #require(try Self.sampleCacheCases()["policy"]?["maxBytes"]?.intValue, "policy.maxBytes")
        #expect(StudioPresetSampleCache.maxBytes == policy)
    }

    // MARK: Cache

    @Test func testHitSkipsNetwork() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        try Self.write(Self.bytes, named: sample.sha256, in: root)
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder, returning: Data("other".utf8))

        #expect(await cache.data(sample) == Self.bytes)
        #expect(await recorder.urls.isEmpty)
    }

    @Test func testMissDownloadsAndStores() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder)

        #expect(await cache.data(sample) == Self.bytes)
        #expect(await recorder.urls == [Self.expectedURL])
        #expect(try Data(contentsOf: root.appending(path: sample.sha256)) == Self.bytes)
        #expect(await cache.data(sample) == Self.bytes)
        #expect(await recorder.urls.count == 1)
    }

    @Test func testShaMismatchNotStored() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder, returning: Data("tampered".utf8))

        #expect(await cache.data(sample) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: sample.sha256).path))
        #expect(await cache.data(sample) == nil)
        #expect(await recorder.urls.count == 2)
    }

    @Test func testUnresolvableUrlSkipsNetwork() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder)

        #expect(await cache.data(Self.sample(url: "http://cdn.example.com/a.webp")) == nil)
        #expect(await cache.data(Self.sample(url: "")) == nil)
        #expect(await recorder.urls.isEmpty)
    }

    @Test func testConcurrentSameKeyDownloadsOnce() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        let recorder = Recorder()
        let started = Gate()
        let release = Gate()
        let cache = Self.makeCache(root, recorder) {
            await started.open()
            await release.wait()
        }

        let first = Task { await cache.data(sample) }
        // Bounded wait: a cache that never downloads must fail here, not hang the suite.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            await started.open()
        }
        defer { timeout.cancel() }
        await started.wait()
        let second = Task { await cache.data(sample) }
        // Gives the second caller time to reach the cache while the first download is held.
        try await Task.sleep(for: .milliseconds(200))
        await release.open()

        #expect(await first.value == Self.bytes)
        #expect(await second.value == Self.bytes)
        #expect(await recorder.urls.count == 1)
    }

    @Test func testPruneKeepsOnlyGiven() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Self.hex(Data("a".utf8))
        let b = Self.hex(Data("b".utf8))
        let c = Self.hex(Data("c".utf8))
        for name in [a, b, c] {
            try Self.write(Data(name.utf8), named: name, in: root)
        }
        let cache = Self.makeCache(root, Recorder())

        await cache.prune(keep: [a, c])

        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: root.appending(path: a).path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: b).path))
        #expect(fileManager.fileExists(atPath: root.appending(path: c).path))
    }

    @Test func testUnreadableEntryRefetches() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        // A directory at the entry path cannot be read as data.
        try FileManager.default.createDirectory(
            at: root.appending(path: sample.sha256, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder)

        #expect(await cache.data(sample) == Self.bytes)
        #expect(await recorder.urls.count == 1)
        #expect(try Data(contentsOf: root.appending(path: sample.sha256)) == Self.bytes)
    }

    @Test func testZeroByteEntryRefetches() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Self.sample()
        // A zero-byte entry counts as unreadable: it is removed and fetched again.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: sample.sha256))
        let recorder = Recorder()
        let cache = Self.makeCache(root, recorder)

        #expect(await cache.data(sample) == Self.bytes)
        #expect(await recorder.urls.count == 1)
        #expect(try Data(contentsOf: root.appending(path: sample.sha256)) == Self.bytes)
    }
}
