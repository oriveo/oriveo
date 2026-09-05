import Foundation

enum BoundedNetworkDataError: Error, Equatable {
    case tooLarge
}

final class BoundedNetworkDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var cancelled = false

    init(maxBytes: Int, configuration: URLSessionConfiguration = .ephemeral) {
        self.maxBytes = max(0, maxBytes)
        self.configuration = configuration
    }

    func data(from url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: url)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expected = response.expectedContentLength
        if expected > 0, expected > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(.failure(BoundedNetworkDataError.tooLarge), cancelSession: true)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceedsLimit = data.count > maxBytes || buffer.count > maxBytes - data.count
        if !finished, !exceedsLimit {
            buffer.append(data)
        }
        lock.unlock()

        if exceedsLimit {
            finish(.failure(BoundedNetworkDataError.tooLarge), cancelSession: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error), cancelSession: false)
        } else {
            lock.lock()
            let data = buffer
            lock.unlock()
            finish(.success(data), cancelSession: false)
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()), cancelSession: true)
    }

    private func finish(_ result: Result<Data, Error>, cancelSession: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        if cancelSession {
            session?.invalidateAndCancel()
        } else {
            session?.finishTasksAndInvalidate()
        }
        continuation?.resume(with: result)
    }
}
