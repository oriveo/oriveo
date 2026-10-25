import CryptoKit
import Foundation

/// Content key of one synthesized clip. The file name is derived from the six key fields
/// (contract `constants.cache.keyFields`); `outputFormat` only picks the extension.
nonisolated struct SpeechAudioCacheKey: Sendable, Equatable {
    /// Same order as contract `constants.cache.keyFields`.
    static let fieldNames = ["textSha256", "providerKind", "model", "voice", "speed", "language"]

    let textSha256: String
    let providerKind: String
    let model: String
    let voice: String
    /// Effective speed; only two decimals take part in the key.
    let speed: Double
    let language: String
    let outputFormat: String

    init(text: String, providerKind: String, model: String, voice: String, speed: Double,
         language: String, outputFormat: String) {
        self.textSha256 = Self.sha256Hex(text)
        self.providerKind = providerKind
        self.model = model
        self.voice = voice
        self.speed = speed
        self.language = language
        self.outputFormat = outputFormat
    }

    /// Values in `fieldNames` order.
    var fieldValues: [String] {
        [textSha256, providerKind, model, voice, String(format: "%.2f", speed), language]
    }

    var fileName: String {
        "\(Self.sha256Hex(fieldValues.joined(separator: "\n"))).\(outputFormat)"
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Read-aloud audio cache as seen by `CloudSpeechEngine`; an actor so file I/O never runs on the main thread.
protocol SpeechAudioCaching: Actor {
    /// Cached audio, or nil on miss or read failure.
    func data(for key: SpeechAudioCacheKey) -> Data?
    /// Stores the clip; failures are swallowed (the next read is just a miss).
    func store(_ data: Data, for key: SpeechAudioCacheKey) async
}

/// Local cache of read-aloud audio, keyed by content. Bounded by `maxBytes`; after every write the
/// least recently used files (oldest modification date, refreshed on hit) are removed until the total
/// fits. The directory is excluded from backup. Any I/O failure counts as a miss and is never thrown.
/// An actor: reads, writes, eviction and directory setup all run off the main thread, one at a time.
/// The app shares `shared` so concurrent engines never race on the same files.
actor SpeechAudioCache: SpeechAudioCaching {

    nonisolated static let defaultMaxBytes = 52_428_800

    /// The one instance used by read-aloud and voice preview.
    nonisolated static let shared = SpeechAudioCache()

    /// Production root: `Library/Caches/Oriveo/VoiceTTS/`.
    nonisolated static var productionRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Oriveo", directoryHint: .isDirectory)
            .appending(path: "VoiceTTS", directoryHint: .isDirectory)
    }

    nonisolated let root: URL
    nonisolated let maxBytes: Int
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    /// Does no I/O; the directory is created on the first write (or `prepare()`).
    init(root: URL = SpeechAudioCache.productionRoot, maxBytes: Int = SpeechAudioCache.defaultMaxBytes,
         now: @escaping @Sendable () -> Date = { Date() }, fileManager: FileManager = .default) {
        self.root = root
        self.maxBytes = maxBytes
        self.now = now
        self.fileManager = fileManager
    }

    nonisolated func fileURL(for key: SpeechAudioCacheKey) -> URL {
        root.appending(path: key.fileName)
    }

    /// Creates the directory and excludes it from backup; failure is ignored.
    func prepare() {
        try? prepareDirectory()
    }

    /// Cached audio, or nil on miss or read failure. A hit refreshes the file's modification date.
    func data(for key: SpeechAudioCacheKey) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    /// Stores the clip and evicts down to `maxBytes`. A clip larger than `maxBytes` is not written.
    func store(_ data: Data, for key: SpeechAudioCacheKey) {
        guard data.count <= maxBytes else { return }
        let url = fileURL(for: key)
        do {
            try prepareDirectory()
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
            return
        }
        evict()
    }

    // MARK: - Internals

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = root
        try mutableDirectory.setResourceValues(values)
    }

    private func evict() {
        guard let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        var entries: [(url: URL, size: Int, modified: Date)] = urls.compactMap { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            return (url, size, modified)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort {
            $0.modified != $1.modified ? $0.modified < $1.modified
                : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        for entry in entries where total > maxBytes {
            guard (try? fileManager.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
        }
    }
}
