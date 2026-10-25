import CryptoKit
import Foundation
import Testing
@testable import Oriveo

/// Local read-aloud audio cache: a content key from 6 fields, eviction by modification date once the total limit is exceeded, refresh on hit, excluded from backup, and no write for a single clip over the limit.
/// The cache is an actor: concurrent writes to one key do not corrupt it, and after concurrent writes of many keys plus eviction the total stays within the limit.
@Suite("Speech audio cache")
struct SpeechAudioCacheTests {

    private nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ now: Date) { current = now }
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval = 1) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SpeechAudioCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "VoiceTTS", directoryHint: .isDirectory)
    }

    private static func cacheConstants() throws -> [String: Any] {
        let relativePath = "shared/voice-contracts/cloud-read-aloud.v1.json"
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try #require(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let constants = try #require(root["constants"] as? [String: Any])
                return try #require(constants["cache"] as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func key(_ text: String = "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}", providerKind: String = "openai",
                            model: String = "gpt-4o-mini-tts", voice: String = "alloy", speed: Double = 1.0,
                            language: String = "zh", outputFormat: String = "mp3") -> SpeechAudioCacheKey {
        SpeechAudioCacheKey(text: text, providerKind: providerKind, model: model, voice: voice, speed: speed,
                            language: language, outputFormat: outputFormat)
    }

    private static func hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func modificationDate(_ url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private static func fileNames(in root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    private static func totalBytes(in root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: root.path).reduce(0) { total, name in
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: name).path)
            return total + ((attributes[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: Key

    @Test func keyUsesTheSixContractFieldsJoinedByNewline() throws {
        let constants = try Self.cacheConstants()
        #expect(constants["keyFields"] as? [String] == SpeechAudioCacheKey.fieldNames)
        #expect((constants["maxBytes"] as? NSNumber)?.intValue == SpeechAudioCache.defaultMaxBytes)
        #expect(SpeechAudioCache.defaultMaxBytes == 52_428_800)

        let key = Self.key()
        let textHash = Self.hex("\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}")
        #expect(key.textSha256 == textHash)
        #expect(key.fieldValues == [textHash, "openai", "gpt-4o-mini-tts", "alloy", "1.00", "zh"])
        let joined = [textHash, "openai", "gpt-4o-mini-tts", "alloy", "1.00", "zh"].joined(separator: "\n")
        #expect(key.fileName == "\(Self.hex(joined)).mp3")
    }

    @Test func everyKeyFieldChangesTheFileNameAndSpeedKeepsTwoDecimals() {
        let base = Self.key()
        let variants = [
            Self.key("another passage"),
            Self.key(providerKind: "xai"),
            Self.key(model: "tts-1"),
            Self.key(voice: "nova"),
            Self.key(speed: 1.25),
            Self.key(language: "en"),
        ]
        #expect(Set(variants.map(\.fileName)).count == variants.count)
        #expect(!variants.map(\.fileName).contains(base.fileName))
        // Only two decimal places take part in the key
        #expect(Self.key(speed: 1.001).fileName == base.fileName)
        // outputFormat only determines the extension
        let wav = Self.key(outputFormat: "wav").fileName
        #expect(wav.hasSuffix(".wav"))
        #expect((wav as NSString).deletingPathExtension == (base.fileName as NSString).deletingPathExtension)
    }

    // MARK: Store and read

    @Test func storedAudioIsReturnedAndMissIsNil() async throws {
        let cache = SpeechAudioCache(root: Self.tempRoot())
        let data = Data("audio".utf8)
        #expect(await cache.data(for: Self.key()) == nil)
        await cache.store(data, for: Self.key())
        #expect(await cache.data(for: Self.key()) == data)
        #expect(await cache.data(for: Self.key(voice: "nova")) == nil)
    }

    @Test func productionRootIsLibraryCachesOriveoVoiceTTS() {
        let components = SpeechAudioCache.productionRoot.pathComponents.suffix(4)
        #expect(Array(components) == ["Library", "Caches", "Oriveo", "VoiceTTS"])
    }

    // MARK: Eviction

    @Test func overLimitEvictsByModificationDateOldestFirst() async throws {
        let clock = Clock(Self.start)
        let root = Self.tempRoot()
        let cache = SpeechAudioCache(root: root, maxBytes: 100, now: { clock.now })
        let keys = [Self.key("one"), Self.key("two"), Self.key("three")]
        for key in keys {
            await cache.store(Data(repeating: 1, count: 40), for: key)
            clock.advance()
        }
        // 120 B > 100 B: removing only the oldest one is enough to get back within the limit
        #expect(try Self.fileNames(in: root) == [keys[1].fileName, keys[2].fileName])

        await cache.store(Data(repeating: 2, count: 90), for: Self.key("four"))
        #expect(try Self.fileNames(in: root) == [Self.key("four").fileName])
    }

    @Test func hitRefreshesModificationDateSoItSurvivesEviction() async throws {
        let clock = Clock(Self.start)
        let root = Self.tempRoot()
        let cache = SpeechAudioCache(root: root, maxBytes: 100, now: { clock.now })
        let first = Self.key("one")
        let second = Self.key("two")
        await cache.store(Data(repeating: 1, count: 40), for: first)
        clock.advance()
        await cache.store(Data(repeating: 1, count: 40), for: second)
        clock.advance()

        #expect(await cache.data(for: first) != nil)
        #expect(try Self.modificationDate(cache.fileURL(for: first)) == clock.now)
        clock.advance()

        let third = Self.key("three")
        await cache.store(Data(repeating: 1, count: 40), for: third)
        #expect(try Self.fileNames(in: root) == [first.fileName, third.fileName])
    }

    @Test func singleClipOverLimitIsNotWritten() async throws {
        let root = Self.tempRoot()
        let clock = Clock(Self.start)
        let cache = SpeechAudioCache(root: root, maxBytes: 100, now: { clock.now })
        let kept = Self.key("keep me")
        await cache.store(Data(repeating: 1, count: 60), for: kept)
        clock.advance()

        await cache.store(Data(repeating: 1, count: 101), for: Self.key("too large"))
        #expect(await cache.data(for: Self.key("too large")) == nil)
        #expect(try Self.fileNames(in: root) == [kept.fileName])

        await cache.store(Data(repeating: 1, count: 100), for: Self.key("exact fit"))
        #expect(try Self.fileNames(in: root) == [Self.key("exact fit").fileName])
    }

    // MARK: Backup and failure

    @Test func directoryIsExcludedFromBackup() async throws {
        let root = Self.tempRoot()
        await SpeechAudioCache(root: root).prepare()
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func ioFailureIsAMissNotAnError() async throws {
        // The directory location is occupied by a regular file: creating the directory fails, and both writes and reads are treated as plain misses
        let root = Self.tempRoot()
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: root)
        let cache = SpeechAudioCache(root: root)
        await cache.prepare()
        await cache.store(Data("audio".utf8), for: Self.key())
        #expect(await cache.data(for: Self.key()) == nil)
    }

    // MARK: Concurrency

    @Test func concurrentStoresToOneKeyLeaveOneIntactClip() async throws {
        let root = Self.tempRoot()
        let cache = SpeechAudioCache(root: root)
        let key = Self.key()
        let clips = (0..<24).map { Data(repeating: UInt8($0), count: 2_000 + $0 * 37) }
        await withTaskGroup(of: Void.self) { group in
            for clip in clips {
                group.addTask { await cache.store(clip, for: key) }
                group.addTask { _ = await cache.data(for: key) }
            }
        }
        // What remains is one complete write, not a splice of several writes
        let stored = try #require(await cache.data(for: key))
        #expect(clips.contains(stored))
        #expect(try Self.fileNames(in: root) == [key.fileName])
    }

    @Test func concurrentStoresOfManyKeysStayWithinLimitAfterEviction() async throws {
        let root = Self.tempRoot()
        let cache = SpeechAudioCache(root: root, maxBytes: 1_000)
        let items = (0..<40).map { (Self.key("passage \($0)"), Data(repeating: 1, count: 60 + ($0 * 53) % 300)) }
        await withTaskGroup(of: Void.self) { group in
            for (key, clip) in items {
                group.addTask { await cache.store(clip, for: key) }
            }
        }
        let total = try Self.totalBytes(in: root)
        #expect(total <= 1_000)
        #expect(total > 0)
        #expect(try Self.fileNames(in: root).isSubset(of: Set(items.map { $0.0.fileName })))
    }
}
