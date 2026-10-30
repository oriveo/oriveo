import Foundation

// MARK: - Loading and adopting the external search catalog (external search services contract)
//
// Sources in order: local cache -> built-in app snapshot (Core/Search/search_catalog_view.v1.json) -> network
// (GET /api/metadata?view=search; base URL and ETag follow MetadataClient). All three go through acceptSearchCatalog:
// a failed signature check / rollback / unchanged result keeps the previous catalog. The cache stores only the adopted response's raw text, its ETag and the highest revision seen,
// and re-verifies the signature on the next cold start, trusting no locally decoded result. There is no timer: the caller decides when to refresh.
// Fetch results are handled by catalogFetchAction: 404 = the Server explicitly withdrew it, the whole preset block is unavailable (cache and built-in snapshot included), a flag is persisted locally,
// and after a restart the cache / built-in snapshot stay unused until a 200 is received and adopted successfully; 304 / other statuses / network errors keep the one in hand.

nonisolated struct SearchCatalogCacheFile: Codable, Sendable, Equatable {
        /// Raw text of the adopted response (the server's `{code,data,message}` wrapper or a bare catalog).
    var raw: String
    var etag: String?
    var maxSeenRevision: Int
}

actor SearchCatalogStore {
    static let shared = SearchCatalogStore()

    private let session: URLSession
    private let cacheDirectory: URL
    private let trustedKeys: [String: String]
    private let baseURL: @Sendable () -> String
    private let bundledData: @Sendable () -> Data?

    private(set) var state: SearchCatalogState = .empty
        /// Body of the currently adopted catalog (`data`); entries are handed to the transport layer as raw JSON.
    private(set) var document: SearchJSON?
    private var etag: String?
    private var loaded = false
        /// The Server returned 404: the whole preset block is unavailable until a 200 is received and adopted successfully.
    private(set) var presetsWithdrawn = false

    init(
        session: URLSession = .shared,
        cacheDirectory: URL = SearchCatalogStore.defaultCacheDirectory,
        trustedKeys: [String: String] = SearchCatalogKeys.production,
        baseURL: @escaping @Sendable () -> String = { BackendURLResolver.resolve() },
        bundledData: @escaping @Sendable () -> Data? = { SearchCatalogStore.bundledSnapshotData() }
    ) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.trustedKeys = trustedKeys
        self.baseURL = baseURL
        self.bundledData = bundledData
    }

    nonisolated static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SearchCatalog", isDirectory: true)
    }

        /// Built-in app snapshot: a byte-for-byte copy in the same shape as the server's `?view=search`.
    nonisolated static func bundledSnapshotData(bundle: Bundle = .main) -> Data? {
        let url = bundle.url(forResource: "search_catalog_view.v1", withExtension: "json")
            ?? bundle.url(forResource: "search_catalog_view.v1", withExtension: "json", subdirectory: "Core/Search")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

        /// Extract the catalog body: the server's httputil.OK wraps it in `{code,data,message}`; a bare catalog is accepted too.
    nonisolated static func catalogDocument(from data: Data) -> SearchJSON? {
        guard let json = try? SearchJSON.parse(data) else { return nil }
        if json["schema"] != nil { return json }
        return json["data"]
    }

        // MARK: Queries

    var isAvailable: Bool { state.current != nil }

        /// The entry in the current catalog that can send requests (active); nil if withdrawn or absent.
    func activeEntry(_ serviceId: String) -> SearchJSON? {
        guard state.current?.services.contains(where: { $0.id == serviceId && $0.status == .active }) == true else { return nil }
        return document?["services"]?.arrayValue?.first { $0["id"]?.stringValue == serviceId }
    }

        /// All entries in the current catalog that can send requests (active), in catalog order (settings page add sheet).
    func activeEntries() -> [SearchJSON] {
        let active = Set((state.current?.services ?? []).filter { $0.status == .active }.map(\.id))
        return (document?["services"]?.arrayValue ?? []).filter { $0["id"]?.stringValue.map(active.contains) == true }
    }

    func isWithdrawn(_ serviceId: String) -> Bool {
        state.current?.services.contains { $0.id == serviceId && $0.status == .withdrawn } == true
    }

        // MARK: Loading

        /// Cold start: cache -> built-in, each going through adoption once. Repeated calls have no side effects.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let cache = readCache()
        if let cache { state.maxSeenRevision = max(state.maxSeenRevision, cache.maxSeenRevision) }
        if FileManager.default.fileExists(atPath: withdrawnMarkerURL.path) {
            presetsWithdrawn = true
            return
        }
        if let cache {
            adopt(raw: Data(cache.raw.utf8), source: .cache, etag: cache.etag, persist: false)
        }
        if let bundled = bundledData() {
            adopt(raw: bundled, source: .builtin, etag: nil, persist: true)
        }
    }

        /// Network refresh: a conditional request with If-None-Match, handled by catalogFetchAction. Returns the adoption outcome on 200, nil otherwise.
    @discardableResult
    func refresh() async -> SearchCatalogAcceptance? {
        ensureLoaded()
        guard let url = URL(string: "\(baseURL())/api/metadata?view=search") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if document != nil, let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        var status: Int?
        var transportFailure: SearchTransportFailure?
        var payload = Data()
        var responseETag: String?
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            status = http?.statusCode
            responseETag = http?.value(forHTTPHeaderField: "Etag")
            payload = data
            if http == nil { transportFailure = .network }
        } catch {
            transportFailure = (error as? URLError)?.code == .timedOut ? .timeout : .network
        }
        switch SearchCatalog.catalogFetchAction(status: status, transportFailure: transportFailure) {
        case .keep:
            return nil
        case .withdrawPresets:
            withdrawPresets()
            return nil
        case .adopt:
            let result = adopt(raw: payload, source: .network, etag: responseETag, persist: true)
                        // Recover as soon as the signature verifies: adopted successfully, or unchanged against the same revision in hand
            if presetsWithdrawn, result?.accepted == true || result?.reason == "unchanged" {
                presetsWithdrawn = false
                try? FileManager.default.removeItem(at: withdrawnMarkerURL)
            }
            return result
        }
    }

        /// 404: drop the catalog in hand (including one from cache / built-in), keep the highest revision seen to prevent rollback, and persist a flag that survives restarts.
    private func withdrawPresets() {
        state.current = nil
        document = nil
        etag = nil
        presetsWithdrawn = true
        do {
            try prepareCacheDirectory()
            try Data().write(to: withdrawnMarkerURL, options: .atomic)
        } catch {
                        // A flag that failed to reach disk only affects behavior after a restart: this run's memory has already withdrawn it.
        }
    }

        /// Adopt raw text; when adopted, update memory and (as needed) persist. Returns the adoption outcome, nil if the raw text cannot be parsed.
    @discardableResult
    private func adopt(raw: Data, source: SearchCatalogSource, etag responseETag: String?, persist: Bool) -> SearchCatalogAcceptance? {
        guard let incoming = Self.catalogDocument(from: raw) else { return nil }
        let result = SearchCatalog.acceptSearchCatalog(state: state, incoming: incoming, source: source, trustedKeys: trustedKeys)
        if result.accepted {
            state = result.state
            document = incoming
            etag = responseETag
            if persist, let text = String(data: raw, encoding: .utf8) {
                writeCache(SearchCatalogCacheFile(raw: text, etag: responseETag, maxSeenRevision: state.maxSeenRevision))
            }
        } else if result.reason == "unchanged", source == .network, let responseETag {
            etag = responseETag
        }
        return result
    }

        // MARK: Cache

    private var withdrawnMarkerURL: URL {
        cacheDirectory.appendingPathComponent("presets-withdrawn", isDirectory: false)
    }

    private func prepareCacheDirectory() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = cacheDirectory
        try directory.setResourceValues(values)
    }

    private var cacheFileURL: URL {
        cacheDirectory.appendingPathComponent("catalog.json", isDirectory: false)
    }

    private func readCache() -> SearchCatalogCacheFile? {
        guard let bytes = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(SearchCatalogCacheFile.self, from: bytes)
    }

    private func writeCache(_ file: SearchCatalogCacheFile) {
        do {
            try prepareCacheDirectory()
            try JSONEncoder().encode(file).write(to: cacheFileURL, options: .atomic)
        } catch {
                        // A failed write only affects the next cold start; the catalog in memory stays usable this run.
        }
    }
}
