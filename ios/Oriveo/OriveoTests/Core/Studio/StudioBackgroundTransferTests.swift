import Foundation
import Testing
@testable import Oriveo

final class StudioTransferURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Background transfer for Studio image jobs: files, states, gate.
@Suite("Studio background transfer", .serialized)
struct StudioBackgroundTransferTests {

    // MARK: Fixtures

    private static let endpoint = URL(string: "https://studio.example.test/v1/images/generations")!
    private static let imageURL = URL(string: "https://cdn.example.test/image-0.png")!

    private static func makeStubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioTransferURLProtocol.self]
        return configuration
    }

    private static func makeSession() -> URLSession {
        URLSession(configuration: makeStubConfiguration())
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioBackgroundTransferTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeTransfer(
        root: URL,
        isEnabled: Bool = true,
        onSessionCreated: (@Sendable () -> Void)? = nil
    ) -> StudioBackgroundTransfer {
        StudioBackgroundTransfer(
            store: StudioTransferStore(root: root),
            isEnabled: isEnabled,
            sessionFactory: { delegate in
                onSessionCreated?()
                return URLSession(configuration: makeStubConfiguration(), delegate: delegate, delegateQueue: nil)
            }
        )
    }

    private static func response(_ status: Int, url: URL = endpoint) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private static func reset(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        StudioTransferURLProtocol.requestHandler = handler
        StudioTransferURLProtocol.capturedRequests = []
    }

    /// Runs `start` and returns the first state that is neither uploading nor downloading,
    /// or nil when none arrives within 15 seconds.
    private static func awaitSettledState(
        _ transfer: StudioBackgroundTransfer,
        start: () throws -> Void
    ) async rethrows -> StudioTransferState? {
        let (stream, continuation) = AsyncStream.makeStream(of: StudioTransferState.self)
        transfer.onStateChange = { _, state in continuation.yield(state) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            continuation.finish()
        }
        defer { timeout.cancel() }
        try start()
        for await state in stream where state != .uploading && state != .downloading {
            return state
        }
        return nil
    }

    /// Runs `start` and returns every state notified up to and including the first settled one.
    private static func collectStates(
        _ transfer: StudioBackgroundTransfer,
        start: () throws -> Void
    ) async rethrows -> [StudioTransferState] {
        let (stream, continuation) = AsyncStream.makeStream(of: StudioTransferState.self)
        transfer.onStateChange = { _, state in continuation.yield(state) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            continuation.finish()
        }
        defer { timeout.cancel() }
        try start()
        var states: [StudioTransferState] = []
        for await state in stream {
            states.append(state)
            if state != .uploading && state != .downloading { break }
        }
        return states
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: Configuration

    @Test("makeConfiguration builds the background session configuration")
    func configuration() {
        let configuration = StudioBackgroundTransfer.makeConfiguration()
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        #expect(!bundleId.isEmpty)
        #expect(StudioBackgroundTransfer.sessionIdentifier == "\(bundleId).studio.transfer")
        #expect(configuration.identifier == StudioBackgroundTransfer.sessionIdentifier)
        #expect(configuration.timeoutIntervalForResource == 180)
        #expect(configuration.sessionSendsLaunchEvents)
        #expect(!configuration.isDiscretionary)
    }

    // MARK: Upload

    @Test("upload writes request.body, appends response.body and settles as received")
    func uploadReceived() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let responseBody = Data(#"{"data":[{"b64_json":"AAAA"}]}"#.utf8)
        Self.reset { _ in (Self.response(200), responseBody) }
        defer { Self.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let store = StudioTransferStore(root: root)
        let body = Data(#"{"prompt":"a red fox","n":1}"#.utf8)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let settled = try await Self.awaitSettledState(transfer) {
            try #require(transfer.enqueueUpload(jobId: "job-upload", request: request, body: body))
        }

        #expect(settled == .received)
        #expect(store.record(jobId: "job-upload") == StudioTransferRecord(state: .received, httpStatus: 200, pendingDownloads: 0))
        #expect(try Data(contentsOf: store.requestBodyURL(jobId: "job-upload")) == body)
        #expect(try Data(contentsOf: store.responseBodyURL(jobId: "job-upload")) == responseBody)
        #expect(StudioTransferURLProtocol.capturedRequests.first?.url == Self.endpoint)
        #expect(StudioTransferURLProtocol.capturedRequests.first?.httpMethod == "POST")
    }

    @Test("an upload answered with 429 records the status code and still settles as received")
    func uploadErrorStatusReceived() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let responseBody = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        Self.reset { _ in (Self.response(429), responseBody) }
        defer { Self.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let store = StudioTransferStore(root: root)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"

        let settled = try await Self.awaitSettledState(transfer) {
            try #require(transfer.enqueueUpload(jobId: "job-429", request: request, body: Data("{}".utf8)))
        }

        let state = try #require(store.record(jobId: "job-429"))
        #expect(settled == .received)
        #expect(state.httpStatus == 429)
        #expect(state.state == .received)
        #expect(try Data(contentsOf: store.responseBodyURL(jobId: "job-429")) == responseBody)
    }

    @Test("prepareUpload for a reused job id clears the previous downloads and response.body")
    func prepareUploadClearsPreviousAttempt() throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.prepareUpload(body: Data("first".utf8), jobId: "job-retry")
        try store.appendResponse(Data("old response".utf8), jobId: "job-retry")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioDownload-\(UUID().uuidString).tmp")
        try Data("old image".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try store.moveDownload(from: temporary, jobId: "job-retry", index: 0)
        #expect(FileManager.default.fileExists(atPath: store.downloadURL(jobId: "job-retry", index: 0).path))

        try store.prepareUpload(body: Data("second".utf8), jobId: "job-retry")

        #expect(try Data(contentsOf: store.requestBodyURL(jobId: "job-retry")) == Data("second".utf8))
        #expect(!FileManager.default.fileExists(atPath: store.responseBodyURL(jobId: "job-retry").path))
        #expect(!FileManager.default.fileExists(atPath: store.downloadsDirectory(jobId: "job-retry").path))
    }

    @Test("a user force-quit cancellation records interrupted")
    func forceQuitInterrupted() throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeState(.uploading, jobId: "job-quit")
        let transfer = Self.makeTransfer(root: root)
        let task = Self.makeSession().dataTask(with: Self.endpoint)
        task.taskDescription = "job-quit"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication]
        )

        transfer.urlSession(Self.makeSession(), task: task, didCompleteWithError: error)

        #expect(NSURLErrorCancelledReasonUserForceQuitApplication == 0)
        #expect(store.state(jobId: "job-quit") == .interrupted)
    }

    @Test(
        "other completion errors record failed with the error code",
        arguments: [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonBackgroundUpdatesDisabled]
            ),
        ]
    )
    func otherErrorFailed(error: NSError) throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeState(.uploading, jobId: "job-failed")
        let transfer = Self.makeTransfer(root: root)
        let task = Self.makeSession().dataTask(with: Self.endpoint)
        task.taskDescription = "job-failed"

        transfer.urlSession(Self.makeSession(), task: task, didCompleteWithError: error)

        #expect(store.state(jobId: "job-failed") == .failed(code: error.code))
    }

    // MARK: Download

    @Test("download moves the payload into downloads/<index> and settles as received")
    func downloadReceived() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        Self.reset { _ in (Self.response(200, url: Self.imageURL), image) }
        defer { Self.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let store = StudioTransferStore(root: root)

        let settled = try await Self.awaitSettledState(transfer) {
            try #require(transfer.enqueueDownload(jobId: "job-download", url: Self.imageURL, index: 1))
        }

        #expect(settled == .received)
        #expect(store.record(jobId: "job-download") == StudioTransferRecord(state: .received, httpStatus: nil, pendingDownloads: 0))
        #expect(try Data(contentsOf: store.downloadURL(jobId: "job-download", index: 1)) == image)
        #expect(StudioTransferURLProtocol.capturedRequests.first?.url == Self.imageURL)
    }

    @Test("two downloads of one job stay downloading until both complete, then settle as received")
    func twoDownloadsReceivedAfterBoth() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchSemaphore(value: 0)
        Self.reset { request in
            _ = gate.wait(timeout: .now() + 10)
            guard let url = request.url else { throw URLError(.badURL) }
            return (Self.response(200, url: url), Data(url.lastPathComponent.utf8))
        }
        defer { Self.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let store = StudioTransferStore(root: root)
        let first = URL(string: "https://cdn.example.test/image-0.png")!
        let second = URL(string: "https://cdn.example.test/image-1.png")!

        let states = try await Self.collectStates(transfer) {
            try #require(transfer.enqueueDownload(jobId: "job-pair", url: first, index: 0))
            try #require(transfer.enqueueDownload(jobId: "job-pair", url: second, index: 1))
            #expect(store.record(jobId: "job-pair") == StudioTransferRecord(state: .downloading, pendingDownloads: 2))
            gate.signal()
            gate.signal()
        }

        #expect(states == [.downloading, .downloading, .downloading, .received])
        #expect(store.record(jobId: "job-pair") == StudioTransferRecord(state: .received, pendingDownloads: 0))
        #expect(try Data(contentsOf: store.downloadURL(jobId: "job-pair", index: 0)) == Data("image-0.png".utf8))
        #expect(try Data(contentsOf: store.downloadURL(jobId: "job-pair", index: 1)) == Data("image-1.png".utf8))
    }

    @Test(
        "one failed download of two records failed and the other completion does not overwrite it",
        arguments: [true, false]
    )
    func oneOfTwoDownloadsFailed(failFirst: Bool) throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeRecord(StudioTransferRecord(state: .downloading, pendingDownloads: 2), jobId: "job-half")
        let transfer = Self.makeTransfer(root: root)
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let failed = Self.makeSession().downloadTask(with: Self.imageURL)
        failed.taskDescription = StudioBackgroundTransfer.taskDescription(jobId: "job-half", index: failFirst ? 0 : 1)
        let succeeded = Self.makeSession().downloadTask(with: Self.imageURL)
        succeeded.taskDescription = StudioBackgroundTransfer.taskDescription(jobId: "job-half", index: failFirst ? 1 : 0)

        if failFirst {
            transfer.urlSession(Self.makeSession(), task: failed, didCompleteWithError: failure)
            #expect(store.record(jobId: "job-half") == StudioTransferRecord(state: .failed(code: NSURLErrorTimedOut), pendingDownloads: 1))
            transfer.urlSession(Self.makeSession(), task: succeeded, didCompleteWithError: nil)
        } else {
            transfer.urlSession(Self.makeSession(), task: succeeded, didCompleteWithError: nil)
            #expect(store.record(jobId: "job-half") == StudioTransferRecord(state: .downloading, pendingDownloads: 1))
            transfer.urlSession(Self.makeSession(), task: failed, didCompleteWithError: failure)
        }

        #expect(store.record(jobId: "job-half") == StudioTransferRecord(state: .failed(code: NSURLErrorTimedOut), pendingDownloads: 0))
    }

    @Test("didFinishDownloadingTo moves the temporary file before returning")
    func downloadMovesTemporaryFile() throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeState(.downloading, jobId: "job-move")
        let transfer = Self.makeTransfer(root: root)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioDownload-\(UUID().uuidString).tmp")
        let payload = Data("image-bytes".utf8)
        try payload.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let task = Self.makeSession().downloadTask(with: Self.imageURL)
        task.taskDescription = StudioBackgroundTransfer.taskDescription(jobId: "job-move", index: 2)

        transfer.urlSession(Self.makeSession(), downloadTask: task, didFinishDownloadingTo: temporary)

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try Data(contentsOf: store.downloadURL(jobId: "job-move", index: 2)) == payload)
    }

    @Test("a download answered with 404 records failed(404) and moves nothing into downloads")
    func downloadErrorStatusFailed() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        Self.reset { _ in (Self.response(404, url: Self.imageURL), Data("<html>not found</html>".utf8)) }
        defer { Self.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let store = StudioTransferStore(root: root)

        let settled = try await Self.awaitSettledState(transfer) {
            try #require(transfer.enqueueDownload(jobId: "job-404", url: Self.imageURL, index: 0))
        }

        #expect(settled == .failed(code: 404))
        #expect(store.state(jobId: "job-404") == .failed(code: 404))
        let downloads = (try? FileManager.default.contentsOfDirectory(atPath: store.downloadsDirectory(jobId: "job-404").path)) ?? []
        #expect(downloads.isEmpty)
    }

    // MARK: Reconcile

    @Test("reconcile marks in-flight jobs without a live task as interrupted")
    func reconcileOrphans() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeState(.uploading, jobId: "job-orphan-upload")
        try store.writeState(.downloading, jobId: "job-orphan-download")
        try store.writeState(.received, jobId: "job-done")
        try store.writeState(.failed(code: NSURLErrorTimedOut), jobId: "job-failed")
        let transfer = Self.makeTransfer(root: root)

        await transfer.reconcile()

        #expect(store.state(jobId: "job-orphan-upload") == .interrupted)
        #expect(store.state(jobId: "job-orphan-download") == .interrupted)
        #expect(store.state(jobId: "job-done") == .received)
        #expect(store.state(jobId: "job-failed") == .failed(code: NSURLErrorTimedOut))
    }

    @Test("a real completion delivered after reconcile overrides interrupted, and received stays terminal")
    func reconcileInterruptedThenCompleted() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioTransferStore(root: root)
        try store.writeState(.uploading, jobId: "job-late")
        let transfer = Self.makeTransfer(root: root)
        await transfer.reconcile()
        #expect(store.state(jobId: "job-late") == .interrupted)
        let task = Self.makeSession().dataTask(with: Self.endpoint)
        task.taskDescription = "job-late"

        transfer.urlSession(Self.makeSession(), task: task, didCompleteWithError: nil)
        #expect(store.state(jobId: "job-late") == .received)

        let forceQuit = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication]
        )
        transfer.urlSession(Self.makeSession(), task: task, didCompleteWithError: forceQuit)
        #expect(store.state(jobId: "job-late") == .received)
    }

    // MARK: Gate

    @Test("gate off builds no session, writes no files and returns false")
    func gateOff() async {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = Counter()
        let transfer = Self.makeTransfer(root: root, isEnabled: false, onSessionCreated: { sessions.increment() })
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"

        #expect(!transfer.enqueueUpload(jobId: "job-gated", request: request, body: Data("{}".utf8)))
        #expect(!transfer.enqueueDownload(jobId: "job-gated", url: Self.imageURL, index: 0))
        await transfer.reconcile()

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(sessions.count == 0)
    }

    // MARK: Background events

    @Test("handleEvents calls the completion handler only after the session finishes its events")
    func handleEventsDeferred() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = Self.makeTransfer(root: root)
        let calls = Counter()

        transfer.handleEvents {
            #expect(Thread.isMainThread)
            calls.increment()
        }
        #expect(calls.count == 0)
        transfer.urlSessionDidFinishEvents(forBackgroundURLSession: Self.makeSession())
        for _ in 0..<100 where calls.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(calls.count == 1)
    }

    @Test("events finished before handleEvents still call the completion handler exactly once")
    func handleEventsAfterEventsFinished() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = Self.makeTransfer(root: root)
        let calls = Counter()
        let later = Counter()

        transfer.urlSessionDidFinishEvents(forBackgroundURLSession: Self.makeSession())
        transfer.handleEvents {
            #expect(Thread.isMainThread)
            calls.increment()
        }
        for _ in 0..<100 where calls.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(calls.count == 1)

        // The delivered flag is consumed: the next handler waits for the next events.
        transfer.handleEvents { later.increment() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(later.count == 0)
        #expect(calls.count == 1)
    }

    @Test("handleEvents with the gate off calls the completion handler immediately")
    func handleEventsGateOff() {
        let root = Self.makeDirectory()
        let transfer = Self.makeTransfer(root: root, isEnabled: false)
        var called = false

        transfer.handleEvents { called = true }

        #expect(called)
    }
}
