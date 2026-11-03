import Foundation

/// Lifecycle of one Studio transfer job directory.
nonisolated enum StudioTransferState: Equatable, Sendable {
    case uploading
    case downloading
    case received
    case failed(code: Int)
    case interrupted

    /// A transfer that still expects a live URLSession task.
    var isInFlight: Bool {
        switch self {
        case .uploading, .downloading: return true
        case .received, .failed, .interrupted: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Contents of a job's `state.json`.
nonisolated struct StudioTransferRecord: Equatable, Sendable {
    var state: StudioTransferState
    /// Status code of the upload response, written when the upload task completes.
    var httpStatus: Int?
    /// URL image downloads enqueued for the job that have not completed yet.
    var pendingDownloads: Int

    init(state: StudioTransferState, httpStatus: Int? = nil, pendingDownloads: Int = 0) {
        self.state = state
        self.httpStatus = httpStatus
        self.pendingDownloads = pendingDownloads
    }
}

/// On-disk layout of a Studio transfer job:
/// `Caches/StudioTransfer/<jobId>/` holding `request.body`, `response.body`,
/// `downloads/<index>` and `state.json`. The store only moves / appends bytes and
/// records the state; it never parses response JSON or decodes images.
nonisolated struct StudioTransferStore: Sendable {
    let root: URL

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("StudioTransfer", isDirectory: true)
    }

    init(root: URL = StudioTransferStore.defaultRoot) {
        self.root = root
    }

    func directory(jobId: String) -> URL { root.appendingPathComponent(jobId, isDirectory: true) }
    func requestBodyURL(jobId: String) -> URL { directory(jobId: jobId).appendingPathComponent("request.body") }
    func responseBodyURL(jobId: String) -> URL { directory(jobId: jobId).appendingPathComponent("response.body") }
    func downloadsDirectory(jobId: String) -> URL { directory(jobId: jobId).appendingPathComponent("downloads", isDirectory: true) }
    func downloadURL(jobId: String, index: Int) -> URL { downloadsDirectory(jobId: jobId).appendingPathComponent(String(index)) }
    func stateURL(jobId: String) -> URL { directory(jobId: jobId).appendingPathComponent("state.json") }

    /// Writes `request.body` and drops any `response.body` and `downloads/` left by an earlier attempt.
    func prepareUpload(body: Data, jobId: String) throws {
        try FileManager.default.createDirectory(at: directory(jobId: jobId), withIntermediateDirectories: true)
        try body.write(to: requestBodyURL(jobId: jobId), options: .atomic)
        for stale in [responseBodyURL(jobId: jobId), downloadsDirectory(jobId: jobId)]
        where FileManager.default.fileExists(atPath: stale.path) {
            try FileManager.default.removeItem(at: stale)
        }
    }

    func appendResponse(_ data: Data, jobId: String) throws {
        let url = responseBodyURL(jobId: jobId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try FileManager.default.createDirectory(at: directory(jobId: jobId), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Moves a finished download out of the system temporary location; must run before
    /// `urlSession(_:downloadTask:didFinishDownloadingTo:)` returns.
    func moveDownload(from location: URL, jobId: String, index: Int) throws {
        let destination = downloadURL(jobId: jobId, index: index)
        try FileManager.default.createDirectory(at: downloadsDirectory(jobId: jobId), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    /// Replaces the state and keeps the other fields of an existing record.
    func writeState(_ state: StudioTransferState, jobId: String) throws {
        var value = record(jobId: jobId) ?? StudioTransferRecord(state: state)
        value.state = state
        try writeRecord(value, jobId: jobId)
    }

    func writeRecord(_ value: StudioTransferRecord, jobId: String) throws {
        try FileManager.default.createDirectory(at: directory(jobId: jobId), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StateRecord(value))
        try data.write(to: stateURL(jobId: jobId), options: .atomic)
    }

    func state(jobId: String) -> StudioTransferState? {
        record(jobId: jobId)?.state
    }

    func record(jobId: String) -> StudioTransferRecord? {
        guard let data = try? Data(contentsOf: stateURL(jobId: jobId)),
              let record = try? JSONDecoder().decode(StateRecord.self, from: data)
        else { return nil }
        return record.value
    }

    func jobIds() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    private struct StateRecord: Codable {
        var state: String
        var code: Int?
        var httpStatus: Int?
        var pendingDownloads: Int?

        init(_ value: StudioTransferRecord) {
            switch value.state {
            case .uploading: state = "uploading"
            case .downloading: state = "downloading"
            case .received: state = "received"
            case .failed(let code): state = "failed"; self.code = code
            case .interrupted: state = "interrupted"
            }
            httpStatus = value.httpStatus
            pendingDownloads = value.pendingDownloads
        }

        var value: StudioTransferRecord? {
            let decoded: StudioTransferState
            switch state {
            case "uploading": decoded = .uploading
            case "downloading": decoded = .downloading
            case "received": decoded = .received
            case "failed": decoded = .failed(code: code ?? 0)
            case "interrupted": decoded = .interrupted
            default: return nil
            }
            return StudioTransferRecord(state: decoded, httpStatus: httpStatus, pendingDownloads: max(0, pendingDownloads ?? 0))
        }
    }
}

/// Background URLSession transfer for Studio image jobs: request bodies are uploaded
/// from a file, responses and URL images land in the job directory, and a user
/// force-quit or an orphaned in-flight job is recorded as interrupted (never retried
/// automatically). Every entry point asks the Studio gate first; with the gate off no
/// session is built and nothing is written. `StudioBackgroundByokTransport` waits on a job by id,
/// cancels it and removes its directory once read.
nonisolated final class StudioBackgroundTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "\(Bundle.main.bundleIdentifier ?? "ai.oriveo.community").studio.transfer"
    /// Whole-request duration cap in seconds.
    static let resourceTimeout: TimeInterval = 180

    /// Always enabled: chat image sends use it whatever the Studio build flag.
    @MainActor static let shared = StudioBackgroundTransfer(isEnabled: true)

    static func makeConfiguration(identifier: String = sessionIdentifier) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return configuration
    }

    /// `taskDescription` of a download task; upload tasks use the bare job id.
    static func taskDescription(jobId: String, index: Int) -> String { "\(jobId)#\(index)" }

    let store: StudioTransferStore
    /// Whether this instance builds a session and accepts jobs.
    let isEnabled: Bool
    private let lock = NSLock()
    /// Serialises read-modify-write of `state.json` across the enqueuing thread and the delegate queue.
    private let stateLock = NSLock()
    private var session: URLSession?
    /// Enqueued tasks per job whose completion has not arrived yet; guarded by `stateLock`.
    private var liveTasks: [String: Int] = [:]
    /// Callers of `waitForTerminal`, resumed once the job settles; guarded by `stateLock`.
    private var waiters: [String: [CheckedContinuation<StudioTransferRecord?, Never>]] = [:]
    private var stateObserver: (@Sendable (String, StudioTransferState) -> Void)?
    private var eventsCompletionHandler: (() -> Void)?
    /// Set when the session finished its events before `handleEvents` stored a handler.
    private var eventsDelivered = false

    /// Called on the delegate queue (or the enqueuing thread) after each state write.
    var onStateChange: (@Sendable (String, StudioTransferState) -> Void)? {
        get { lock.withLock { stateObserver } }
        set { lock.withLock { stateObserver = newValue } }
    }

    /// - Parameter isEnabled: Studio gate; `nil` means `StudioAvailability.compiledIn`
    ///   (resolved inside the main-actor init, since the gate is main-actor isolated).
    @MainActor
    init(
        store: StudioTransferStore = StudioTransferStore(),
        isEnabled: Bool? = nil,
        sessionFactory: ((StudioBackgroundTransfer) -> URLSession)? = nil
    ) {
        let isEnabled = isEnabled ?? StudioAvailability.compiledIn
        self.store = store
        self.isEnabled = isEnabled
        super.init()
        guard isEnabled else { return }
        if let sessionFactory {
            session = sessionFactory(self)
        } else {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = Self.sessionIdentifier
            session = URLSession(configuration: Self.makeConfiguration(), delegate: self, delegateQueue: queue)
        }
    }

    // MARK: Enqueue

    /// Writes `request.body` and starts a file upload. Performs file IO; call off the main thread.
    @discardableResult
    func enqueueUpload(jobId: String, request: URLRequest, body: Data) -> Bool {
        guard isEnabled, let session = currentSession(), Self.isValidJobId(jobId) else { return false }
        do {
            try store.prepareUpload(body: body, jobId: jobId)
        } catch {
            return false
        }
        let task = session.uploadTask(with: request, fromFile: store.requestBodyURL(jobId: jobId))
        task.taskDescription = jobId
        update(jobId: jobId, liveDelta: 1) { _ in StudioTransferRecord(state: .uploading) }
        task.resume()
        return true
    }

    /// Starts downloading a URL image into `downloads/<index>`. The job settles as received
    /// only once every enqueued download has completed; a recorded failure stays.
    @discardableResult
    func enqueueDownload(jobId: String, url: URL, index: Int) -> Bool {
        guard isEnabled, let session = currentSession(), Self.isValidJobId(jobId), index >= 0 else { return false }
        let task = session.downloadTask(with: url)
        task.taskDescription = Self.taskDescription(jobId: jobId, index: index)
        update(jobId: jobId, liveDelta: 1) { current in
            var next = current ?? StudioTransferRecord(state: .downloading)
            // Outstanding downloads only carry over while the job is still downloading (or failed).
            let carried = next.state == .downloading || next.state.isFailed ? next.pendingDownloads : 0
            next.pendingDownloads = carried + 1
            if !next.state.isFailed { next.state = .downloading }
            return next
        }
        task.resume()
        return true
    }

    // MARK: Job lifecycle

    /// Cancels every task of the job still in the session (upload and downloads); each one then
    /// completes as failed(NSURLErrorCancelled). Returns at once; the gate off does nothing.
    func cancel(jobId: String) {
        guard isEnabled, let session = currentSession(), Self.isValidJobId(jobId) else { return }
        session.getAllTasks { tasks in
            for task in tasks where Self.parse(task.taskDescription)?.jobId == jobId {
                task.cancel()
            }
        }
    }

    /// Returns the job's record once it has settled: not uploading / downloading and every task
    /// enqueued in this process has delivered its completion (so no later callback rewrites the
    /// directory). A job with no record and no live task returns nil at once, as does the gate off.
    func waitForTerminal(jobId: String) async -> StudioTransferRecord? {
        guard isEnabled, currentSession() != nil, Self.isValidJobId(jobId) else { return nil }
        return await withCheckedContinuation { continuation in
            let ready: StudioTransferRecord?? = stateLock.withLock {
                let current = store.record(jobId: jobId)
                if liveTasks[jobId] == nil, current?.state.isInFlight != true { return .some(current) }
                waiters[jobId, default: []].append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Deletes the job directory; call after the job has settled and been read. Performs file IO;
    /// call off the main thread. The gate off does nothing.
    func removeJob(jobId: String) {
        guard isEnabled, currentSession() != nil, Self.isValidJobId(jobId) else { return }
        stateLock.withLock {
            let directory = store.directory(jobId: jobId)
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    // MARK: Reconcile

    /// After launch: in-flight jobs with no live task in the session are interrupted.
    func reconcile() async {
        guard isEnabled, let session = currentSession() else { return }
        let candidates = store.jobIds().filter { store.state(jobId: $0)?.isInFlight == true }
        guard !candidates.isEmpty else { return }
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { Self.parse($0.taskDescription)?.jobId })
        for jobId in candidates where !live.contains(jobId) {
            update(jobId: jobId) { current in
                guard var next = current, next.state.isInFlight else { return nil }
                next.state = .interrupted
                return next
            }
        }
    }

    // MARK: Background events

    /// Holds the system completion handler until the session has delivered its events;
    /// calls it right away when the events already finished before it arrived.
    @MainActor
    func handleEvents(completionHandler: @escaping () -> Void) {
        guard isEnabled, currentSession() != nil else {
            completionHandler()
            return
        }
        let alreadyDelivered = lock.withLock { () -> Bool in
            guard eventsDelivered else {
                eventsCompletionHandler = completionHandler
                return false
            }
            eventsDelivered = false
            return true
        }
        if alreadyDelivered { completionHandler() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            guard let stored = eventsCompletionHandler else {
                eventsDelivered = true
                return nil
            }
            eventsCompletionHandler = nil
            return stored
        }
        guard let handler else { return }
        nonisolated(unsafe) let completion = handler
        DispatchQueue.main.async { completion() }
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let jobId = Self.parse(dataTask.taskDescription)?.jobId else { return }
        do {
            try store.appendResponse(data, jobId: jobId)
        } catch {
            recordFailure(code: (error as NSError).code, jobId: jobId)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let parsed = Self.parse(downloadTask.taskDescription), let index = parsed.index else { return }
        // An error page is not an image: record the status and leave downloads/ untouched.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            recordFailure(code: status, jobId: parsed.jobId)
            return
        }
        do {
            try store.moveDownload(from: location, jobId: parsed.jobId, index: index)
        } catch {
            recordFailure(code: (error as NSError).code, jobId: parsed.jobId)
        }
    }

    /// Upload tasks record the response status code (4xx / 5xx still settle as received; the
    /// executor parses the body). Download tasks count down `pendingDownloads` and settle as
    /// received at zero. Only received and failed are terminal: an interrupted mark from
    /// `reconcile` is overridden by a completion the system delivers later.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let parsed = Self.parse(task.taskDescription) else { return }
        let isDownload = parsed.index != nil
        let httpStatus = isDownload ? nil : (task.response as? HTTPURLResponse)?.statusCode
        let errorState: StudioTransferState? = error.map { error in
            let nsError = error as NSError
            return Self.isUserForceQuit(nsError) ? .interrupted : .failed(code: nsError.code)
        }
        update(jobId: parsed.jobId, liveDelta: -1) { current in
            var next = current ?? StudioTransferRecord(state: isDownload ? .downloading : .uploading)
            if let httpStatus { next.httpStatus = httpStatus }
            if isDownload { next.pendingDownloads = max(0, next.pendingDownloads - 1) }
            guard !next.state.isFailed, next.state != .received else { return next }
            if let errorState {
                next.state = errorState
            } else if next.state.isInFlight || next.state == .interrupted, !isDownload || next.pendingDownloads == 0 {
                next.state = .received
            }
            return next
        }
    }

    // MARK: Helpers

    private func currentSession() -> URLSession? {
        lock.withLock { session }
    }

    /// Reads, changes and writes `state.json` under `stateLock`; `change` returns nil to leave
    /// the file untouched. `liveDelta` counts tasks enqueued (+1) and completed (-1). Waiters of a
    /// job that has settled are taken under the lock; they and the observer are called outside it.
    private func update(
        jobId: String,
        liveDelta: Int = 0,
        _ change: (StudioTransferRecord?) -> StudioTransferRecord?
    ) {
        let (written, settled, resumed) = stateLock.withLock {
            () -> (StudioTransferRecord?, StudioTransferRecord?, [CheckedContinuation<StudioTransferRecord?, Never>]) in
            if liveDelta != 0 {
                let live = max(0, liveTasks[jobId, default: 0] + liveDelta)
                liveTasks[jobId] = live == 0 ? nil : live
            }
            let current = store.record(jobId: jobId)
            let next = change(current)
            if let next { try? store.writeRecord(next, jobId: jobId) }
            let latest = next ?? current
            guard liveTasks[jobId] == nil, let latest, !latest.state.isInFlight,
                  let pending = waiters.removeValue(forKey: jobId)
            else { return (next, nil, []) }
            return (next, latest, pending)
        }
        if let written { onStateChange?(jobId, written.state) }
        for continuation in resumed {
            continuation.resume(returning: settled)
        }
    }

    private func recordFailure(code: Int, jobId: String) {
        update(jobId: jobId) { current in
            guard current?.state.isFailed != true else { return nil }
            var next = current ?? StudioTransferRecord(state: .failed(code: code))
            next.state = .failed(code: code)
            return next
        }
    }

    static func isUserForceQuit(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled else { return false }
        let reason = error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
        return reason == NSURLErrorCancelledReasonUserForceQuitApplication
    }

    private static func isValidJobId(_ jobId: String) -> Bool {
        !jobId.isEmpty && jobId != "." && jobId != ".."
            && !jobId.contains("/") && !jobId.contains("#")
    }

    private static func parse(_ description: String?) -> (jobId: String, index: Int?)? {
        guard let description, !description.isEmpty else { return nil }
        if let separator = description.lastIndex(of: "#"),
           let index = Int(description[description.index(after: separator)...]) {
            let jobId = String(description[..<separator])
            return jobId.isEmpty ? nil : (jobId, index)
        }
        return (description, nil)
    }
}
