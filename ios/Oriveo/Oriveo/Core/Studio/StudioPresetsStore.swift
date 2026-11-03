import Foundation

/// Fetches and persists style / effect presets on top of the pure `StudioPresets` functions.
/// `current(locale:)` serves the cached body when it was fetched for the same locale and still
/// decodes, otherwise the bundled offline snapshot. `refreshIfNeeded(locale:nowMs:)` follows
/// `planRefresh` → `GET {base}/api/studio/presets?locale={tag}` (If-None-Match) →
/// `applyResponse`. One global file, `Application Support/Oriveo/Studio/presets.json`, holding
/// the cache record and the raw body; the directory is excluded from backup.
/// Not wired to any entry point yet.
actor StudioPresetsStore {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// On-disk format; `body` is the raw bytes of the last accepted response.
    private nonisolated struct StoredFile: Codable, Sendable {
        var cache: StudioPresets.Cache
        var body: Data
    }

    private let transport: Transport
    private let cacheDirectory: URL
    private let baseURL: @Sendable () -> String
    private let clock: @Sendable () -> Int64
    private let bundle: Bundle

    /// Read lazily on the actor the first time it is needed (never in init).
    private var stored: StoredFile?
    private var storedLoaded = false
    private var snapshot: JSONValue?
    private var snapshotLoaded = false
    private var decoded: (body: Data, catalog: StudioPresets.Catalog?)?
    private var inFlight: (locale: String, task: Task<StudioPresets.Outcome, Never>)?

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        cacheDirectory: URL = StudioPresetsStore.defaultCacheDirectory,
        baseURL: @escaping @Sendable () -> String = { BackendURLResolver.resolve() },
        clock: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
        bundle: Bundle = .main
    ) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.baseURL = baseURL
        self.clock = clock
        self.bundle = bundle
    }

    static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Oriveo", isDirectory: true)
            .appendingPathComponent("Studio", isDirectory: true)
    }

    /// Cached catalog for `locale`, or the offline snapshot localized to it. `nil` only when
    /// the bundled snapshot itself is missing or unreadable.
    func current(locale: String) -> StudioPresets.Catalog? {
        loadStoredIfNeeded()
        if let stored, Self.same(stored.cache.locale, locale), let catalog = catalog(for: stored.body) {
            return catalog
        }
        return offline(locale)
    }

    /// One throttled refresh; `.throttled` when the 6-hour window says not to fetch.
    /// At most one refresh runs per store: a call overlapping one for the same locale gets
    /// its outcome, a call for another locale waits for it and then plans its own.
    @discardableResult
    func refreshIfNeeded(locale: String, nowMs: Int64? = nil) async -> StudioPresets.Outcome {
        while let running = inFlight {
            let outcome = await running.task.value
            if Self.same(running.locale, locale) { return outcome }
        }
        let task = Task { await self.performRefresh(locale: locale, nowMs: nowMs) }
        inFlight = (locale, task)
        return await task.value
    }

    private func performRefresh(locale: String, nowMs: Int64?) async -> StudioPresets.Outcome {
        // Cleared on the actor before the task completes, so waiters never see a finished task.
        defer { inFlight = nil }
        loadStoredIfNeeded()
        let now = nowMs ?? clock()
        let plan = StudioPresets.planRefresh(cache: usableStored()?.cache, locale: locale, nowMs: now)
        guard plan.fetch else { return .throttled }
        let response = await fetch(locale: locale, ifNoneMatch: plan.ifNoneMatch)
        let previous = usableStored()
        let applied = StudioPresets.applyResponse(cache: previous?.cache, locale: locale, nowMs: now, response: response)
        switch applied.outcome {
        case .replaced:
            if let cache = applied.cache, let body = response.body {
                write(StoredFile(cache: cache, body: body))
            }
        case .notModified, .unchanged:
            if let cache = applied.cache, let previous {
                write(StoredFile(cache: cache, body: previous.body))
            }
        case .failed, .invalid, .throttled:
            break
        }
        return applied.outcome
    }

    /// The persisted record only when its body still decodes; otherwise it plans as no cache
    /// (fetch at once, no If-None-Match).
    private func usableStored() -> StoredFile? {
        guard let stored, catalog(for: stored.body) != nil else { return nil }
        return stored
    }

    /// Decodes `body`, remembering the result for the last body seen.
    private func catalog(for body: Data) -> StudioPresets.Catalog? {
        if let decoded, decoded.body == body { return decoded.catalog }
        let catalog = try? StudioPresets.decode(body).get()
        decoded = (body, catalog)
        return catalog
    }

    // MARK: Network

    private func fetch(locale: String, ifNoneMatch: String?) async -> StudioPresets.Response {
        let failed = StudioPresets.Response(status: 0, etag: nil, body: nil)
        var base = baseURL()
        while base.hasSuffix("/") { base.removeLast() }
        guard let tag = locale.addingPercentEncoding(withAllowedCharacters: Self.unreserved),
              let url = URL(string: "\(base)/api/studio/presets?locale=\(tag)")
        else { return failed }
        // Bypasses the system HTTP cache: freshness is decided by planRefresh / ETag only.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { return failed }
            return StudioPresets.Response(
                status: http.statusCode,
                etag: http.value(forHTTPHeaderField: "ETag"),
                // An oversized body is dropped, so a 200 with it applies as invalid.
                body: data.count > Self.maxBodyBytes ? nil : data
            )
        } catch {
            return failed
        }
    }

    private static let timeoutSeconds: TimeInterval = 15
    private static let maxBodyBytes = 1 << 20

    /// RFC 3986 unreserved characters (ASCII only); everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    // MARK: Storage

    private var cacheFileURL: URL {
        cacheDirectory.appendingPathComponent("presets.json", isDirectory: false)
    }

    private func loadStoredIfNeeded() {
        guard !storedLoaded else { return }
        storedLoaded = true
        guard let bytes = try? Data(contentsOf: cacheFileURL) else { return }
        stored = try? JSONDecoder().decode(StoredFile.self, from: bytes)
    }

    private func write(_ file: StoredFile) {
        stored = file
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = cacheDirectory
            try directory.setResourceValues(values)
            try JSONEncoder().encode(file).write(to: cacheFileURL, options: .atomic)
        } catch {
            // A failed write only affects the next cold start; memory keeps the new state.
        }
    }

    private func offline(_ locale: String) -> StudioPresets.Catalog? {
        if !snapshotLoaded {
            snapshotLoaded = true
            snapshot = StudioPresets.bundledSnapshot(bundle: bundle)
        }
        guard let snapshot,
              case .success(let catalog) = StudioPresets.decode(StudioPresets.localize(snapshot, locale))
        else { return nil }
        return catalog
    }

    /// Strict scalar equality, matching `StudioPresets`.
    private static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
}
