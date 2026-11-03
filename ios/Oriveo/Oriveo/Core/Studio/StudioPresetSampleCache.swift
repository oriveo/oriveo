import CryptoKit
import Foundation

/// Local cache of style sample images, keyed by `sample.sha256`. A hit returns the stored bytes
/// with no network. A miss resolves the sample URL against the backend base, downloads it through
/// `StudioImageFetcher` (capped at `maxBytes`, must decode as png / jpeg / webp) and stores it only
/// when its lowercase-hex SHA-256 equals the key. One download per key is in flight at a time;
/// later callers await the same download. Entries live in `Library/Caches/Oriveo/StudioSamples/<sha>`
/// (atomic write, excluded from backup). Any I/O failure counts as a miss and is never thrown.
/// Policy: `clientCases.sampleCache` in `shared/studio-contracts/studio_presets.v1.json`.
actor StudioPresetSampleCache {
    nonisolated enum Verification: String, Sendable {
        case ok
        case shaMismatch = "sha_mismatch"
    }

    /// Bytes of the image at the URL, or nil on any failure.
    typealias Downloader = @Sendable (URL) async -> Data?

    /// Same as `clientCases.sampleCache.policy.maxBytes`.
    nonisolated static let maxBytes = 2_097_152

    /// Production root: `Library/Caches/Oriveo/StudioSamples/`.
    nonisolated static var productionRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Oriveo", directoryHint: .isDirectory)
            .appending(path: "StudioSamples", directoryHint: .isDirectory)
    }

    /// Default downloader: the bytes of a successful `StudioImageFetcher` fetch.
    nonisolated static let defaultDownload: Downloader = { url in
        guard case .success(let image) = await StudioImageFetcher(maxBytes: maxBytes).fetch(url) else {
            return nil
        }
        return image.bytes
    }

    /// Absolute sample URL, or nil when it must not be fetched. A path starting with a single `/`
    /// joins the base (trailing slashes trimmed, base path kept, query / fragment verbatim); an
    /// absolute URL is kept only with a literal lowercase `https://` scheme and a host. Anything
    /// else (http, other schemes, protocol-relative, bare relative, leading space, empty) is nil.
    nonisolated static func resolveSampleURL(base: String, url: String) -> URL? {
        if url.hasPrefix("https://") {
            guard let absolute = URL(string: url), absolute.scheme == "https",
                  let host = absolute.host(), !host.isEmpty else { return nil }
            return absolute
        }
        guard url.hasPrefix("/"), !url.hasPrefix("//") else { return nil }
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let joined = URL(string: trimmed + url),
              let scheme = joined.scheme?.lowercased(), StudioImageFetcher.Policy.schemes.contains(scheme),
              let host = joined.host(), !host.isEmpty else { return nil }
        return joined
    }

    /// `ok` when the lowercase-hex SHA-256 of `bytes` equals `sha256`.
    nonisolated static func verify(_ bytes: Data, sha256: String) -> Verification {
        sha256Hex(bytes) == sha256 ? .ok : .shaMismatch
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated let root: URL
    private let baseURL: @Sendable () -> String
    private let download: Downloader
    private let fileManager: FileManager
    private var inFlight: [String: Task<Data?, Never>] = [:]

    /// Does no I/O; the directory is created on the first write.
    init(
        root: URL = StudioPresetSampleCache.productionRoot,
        baseURL: @escaping @Sendable () -> String = { BackendURLResolver.resolve() },
        download: @escaping Downloader = StudioPresetSampleCache.defaultDownload,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.baseURL = baseURL
        self.download = download
        self.fileManager = fileManager
    }

    /// Sample bytes, or nil when the URL cannot be resolved, the download fails or the digest
    /// does not match (the caller then shows `placeholderColor`).
    func data(_ sample: StudioPresets.Sample) async -> Data? {
        let key = sample.sha256
        // A key that is not a lowercase-hex digest can never verify; it is also unsafe as a file name.
        guard Self.isDigest(key) else { return nil }
        if let pending = inFlight[key] { return await pending.value }
        if let stored = readEntry(key) { return stored }
        guard let url = Self.resolveSampleURL(base: baseURL(), url: sample.url) else { return nil }
        let download = self.download
        let task = Task<Data?, Never> {
            guard let bytes = await download(url), Self.verify(bytes, sha256: key) == .ok else { return nil }
            return bytes
        }
        inFlight[key] = task
        let bytes = await task.value
        inFlight[key] = nil
        if let bytes { writeEntry(bytes, key) }
        return bytes
    }

    /// Removes every entry whose key is not in `keep`.
    func prune(keep: Set<String>) {
        guard let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where !keep.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Internals

    private nonisolated static func isDigest(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func entryURL(_ key: String) -> URL {
        root.appending(path: key)
    }

    /// Stored bytes, or nil on miss. An entry that exists but cannot be read, or is empty, is removed.
    private func readEntry(_ key: String) -> Data? {
        let url = entryURL(key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        try? fileManager.removeItem(at: url)
        return nil
    }

    private func writeEntry(_ data: Data, _ key: String) {
        let url = entryURL(key)
        do {
            try prepareDirectory()
            try data.write(to: url, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = root
        try mutableDirectory.setResourceValues(values)
    }
}
