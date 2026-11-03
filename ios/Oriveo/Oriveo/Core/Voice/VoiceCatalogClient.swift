import Foundation

/// The three states of the voice catalog: unavailable (the server has no voice view), load failed (and no usable cache), available.
nonisolated enum VoiceCatalogState: Sendable, Hashable {
    case unavailable
    case loadFailed
    case available(VoiceCatalog)

    var catalog: VoiceCatalog? {
        if case .available(let catalog) = self { return catalog }
        return nil
    }
}

/// Subscription handle for the catalog: carries the state at subscribe time; after `cancel()` no more pushes arrive (including ones in the in-flight round not yet reached).
nonisolated struct VoiceCatalogSubscription: Sendable {
    let id: UUID
    /// State at subscribe time (subscribing and reading the current state are one step, so no push is missed in between).
    let state: VoiceCatalogState?
    let client: VoiceCatalogClient

    func cancel() async {
        await client.unsubscribe(id)
    }
}

/// Fetches and caches `GET /api/metadata?view=voice`.
/// One global cache (not per account): `Application Support/Oriveo/Voice/catalog.json`, storing the raw data bytes + ETag; the directory is excluded from backup.
actor VoiceCatalogClient {
    static let shared = VoiceCatalogClient()

    /// On-disk format; data is the JSON bytes of the data object in the envelope.
    private struct CacheFile: Codable {
        let etag: String?
        let data: Data
    }

    private struct CacheEntry {
        let catalog: VoiceCatalog
        let etag: String?
    }

    private enum FetchResult {
        case updated(catalog: VoiceCatalog, rawData: Data, etag: String?)
        case notModified
        case notFound
        case failed
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private let baseURL: @Sendable () -> String
    /// Reads the cache file bytes; injectable so tests can count reads and the thread they run on.
    private let readCacheFile: @Sendable (URL) -> Data?
    private var cache: CacheEntry?
    /// Whether the cold-start cache has been read: the cache is read on first use on the actor, not in init (which may run on the main thread).
    private var cacheLoaded = false
    private var storedState: VoiceCatalogState?
    /// nil means this process has no verdict yet (never refreshed and no cold-start cache).
    var state: VoiceCatalogState? {
        loadCacheIfNeeded()
        return storedState
    }
    /// Subscribers (e.g. the read-aloud catalog snapshot): when refresh yields a state different from the previous one, they are awaited in subscription order.
    private var subscribers: [(id: UUID, handler: @Sendable (VoiceCatalogState) async -> Void)] = []

    init(
        session: URLSession = .shared,
        cacheDirectory: URL = VoiceCatalogClient.defaultCacheDirectory,
        baseURL: @escaping @Sendable () -> String = { BackendURLResolver.resolve() },
        readCacheFile: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.baseURL = baseURL
        self.readCacheFile = readCacheFile
    }

    /// Cold start reads the cache first so a usable catalog exists before the first refresh; read only once on the actor (a synchronous disk read on the main thread is a blocker).
    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let cached = readCacheFile(cacheFileURL).flatMap(Self.decodeCache)
        cache = cached
        storedState = cached.map { .available($0.catalog) }
    }

    static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Oriveo", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
    }

    /// Subscribes to state changes and returns a handle that can unsubscribe (carries the state at subscribe time).
    func subscribe(_ handler: @escaping @Sendable (VoiceCatalogState) async -> Void) -> VoiceCatalogSubscription {
        let id = UUID()
        subscribers.append((id: id, handler: handler))
        return VoiceCatalogSubscription(id: id, state: state, client: self)
    }

    /// Unsubscribes; unsubscribing again is a no-op.
    func unsubscribe(_ id: UUID) {
        subscribers.removeAll { $0.id == id }
    }

    /// Requests the catalog once and updates the state; on a change it pushes to subscribers and returns only after they finish handling it.
    /// 200 decodes and writes the cache; 304 uses the cache; 404 means unavailable (cache cleared); any other failure keeps the previous cache, and without a cache it is a load failure.
    @discardableResult
    func refresh() async -> VoiceCatalogState {
        loadCacheIfNeeded()
        let next: VoiceCatalogState
        switch await fetch(etag: cache?.etag) {
        case .updated(let catalog, let rawData, let etag):
            cache = CacheEntry(catalog: catalog, etag: etag)
            writeCache(CacheFile(etag: etag, data: rawData))
            next = .available(catalog)
        case .notModified:
            next = cache.map { .available($0.catalog) } ?? .loadFailed
        case .notFound:
            cache = nil
            removeCache()
            next = .unavailable
        case .failed:
            next = cache.map { .available($0.catalog) } ?? .loadFailed
        }
        let changed = next != storedState
        storedState = next
        if changed {
            for subscriber in subscribers {
                // A subscriber may unsubscribe while an earlier subscriber handles a push: an unsubscribed one is no longer called.
                guard subscribers.contains(where: { $0.id == subscriber.id }) else { continue }
                await subscriber.handler(next)
            }
        }
        return next
    }

    // MARK: - Network

    private func fetch(etag: String?) async -> FetchResult {
        guard let url = URL(string: "\(baseURL())/api/metadata?view=voice") else { return .failed }
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 304:
                return etag == nil ? .failed : .notModified
            case 404:
                return .notFound
            case 200:
                guard let rawData = Self.voiceData(fromEnvelope: data),
                      let catalog = VoiceCatalogDecoder.decode(jsonData: rawData) else {
                    return .failed
                }
                return .updated(catalog: catalog, rawData: rawData, etag: http.value(forHTTPHeaderField: "Etag"))
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Standard envelope `{code, data, message}`: extracts data and re-serializes it to bytes; a data that is not an object or a view other than voice counts as failure.
    private static func voiceData(fromEnvelope body: Data) -> Data? {
        guard let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = envelope["data"] as? [String: Any],
              data["view"] as? String == "voice" else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: data)
    }

    // MARK: - Cache

    private var cacheFileURL: URL {
        cacheDirectory.appendingPathComponent("catalog.json", isDirectory: false)
    }

    private static func decodeCache(_ bytes: Data) -> CacheEntry? {
        guard let file = try? JSONDecoder().decode(CacheFile.self, from: bytes),
              let catalog = VoiceCatalogDecoder.decode(jsonData: file.data) else {
            return nil
        }
        return CacheEntry(catalog: catalog, etag: file.etag)
    }

    private func writeCache(_ file: CacheFile) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = cacheDirectory
            try mutableDirectory.setResourceValues(values)
            try JSONEncoder().encode(file).write(to: cacheFileURL, options: .atomic)
        } catch {
            // A failed write only affects the next cold start; the catalog in memory stays usable.
        }
    }

    private func removeCache() {
        try? FileManager.default.removeItem(at: cacheFileURL)
    }
}
