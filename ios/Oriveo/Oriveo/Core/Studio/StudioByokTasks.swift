import Foundation

/// BYOK image task management, pure logic only (no UI, no transport): per-attempt
/// timeout, retry decision, URLError to phase, split-batch aggregation, the 4-slot
/// round queue reducer and launch reconciliation.
///
/// Cases: the shared studio contracts fixture `byok_image_tasks.v1.json`, read by the iOS /
/// Android / Web contract tests alike.
nonisolated enum StudioByokTasks {
    static let defaultTimeoutSeconds = 180
    static let maxTimeoutSeconds = 180
    static let maxConcurrentRounds = 4
    static let maxAutoRetries = 1

    /// Where a transport failure happened; decides retry and billing exposure.
    enum Phase: String, CaseIterable, Equatable, Sendable {
        case preConnect = "pre_connect"
        case afterSend = "after_send"
        case timeout
        case cancelled
    }

    struct RetryDecision: Equatable, Sendable {
        var retry: Bool
        /// `nil` when retrying or cancelled.
        var errorKind: StudioImageErrorKind?
        var retried: Bool
        var mayBeBilled: Bool
    }

    enum RoundStatus: String, CaseIterable, Equatable, Sendable {
        case completed
        case partial
        case failed
        case cancelled
    }

    struct BatchResult: Equatable, Sendable {
        var images: Int
        var errorKind: StudioImageErrorKind?
    }

    struct Aggregate: Equatable, Sendable {
        var status: RoundStatus
        var delivered: Int
        var errorKind: StudioImageErrorKind?
    }

    enum ReconcileAction: String, CaseIterable, Equatable, Sendable {
        case keep
        case process
        case keepRunning = "keep_running"
        case interrupted
        case failedTimeout = "failed_timeout"
    }

    enum QueueEvent: Equatable, Sendable {
        case submit(String)
        case finish(String)
        case cancel(String)
        case response(String)
    }

    enum QueueEffect: Equatable, Sendable {
        case start(String)
        case cancelled(String, mayBeBilled: Bool)
        case accept(String)
        case drop(String)
    }

    /// One slot per round, FIFO. Ids are round ids.
    struct QueueState: Equatable, Sendable {
        var running: [String] = []
        var queued: [String] = []

        /// Applies one event and returns the effects in emission order.
        mutating func reduce(_ event: QueueEvent) -> [QueueEffect] {
            switch event {
            case .submit(let id):
                if running.contains(id) || queued.contains(id) { return [] }
                queued.append(id)
                return promote()
            case .finish(let id):
                guard let index = running.firstIndex(of: id) else { return [] }
                running.remove(at: index)
                return promote()
            case .cancel(let id):
                if let index = running.firstIndex(of: id) {
                    running.remove(at: index)
                    return [.cancelled(id, mayBeBilled: true)] + promote()
                }
                if let index = queued.firstIndex(of: id) {
                    queued.remove(at: index)
                    return [.cancelled(id, mayBeBilled: false)]
                }
                return []
            case .response(let id):
                return running.contains(id) ? [.accept(id)] : [.drop(id)]
            }
        }

        /// Fills free slots from the queue head.
        private mutating func promote() -> [QueueEffect] {
            var effects: [QueueEffect] = []
            while running.count < StudioByokTasks.maxConcurrentRounds, !queued.isEmpty {
                let id = queued.removeFirst()
                running.append(id)
                effects.append(.start(id))
            }
            return effects
        }
    }

    /// Total duration of one HTTP attempt; a retry gets a fresh full timeout.
    static func effectiveTimeoutSeconds(_ timeoutSeconds: Int?) -> Int {
        guard let timeoutSeconds, timeoutSeconds > 0 else { return defaultTimeoutSeconds }
        return min(timeoutSeconds, maxTimeoutSeconds)
    }

    /// Only a first-attempt pre_connect failure is retried, once. HTTP responses never
    /// reach here (error classification decides those).
    static func retryDecision(phase: Phase, attempt: Int) -> RetryDecision {
        let retried = attempt > 0
        switch phase {
        case .preConnect:
            let retry = attempt < maxAutoRetries
            return RetryDecision(
                retry: retry, errorKind: retry ? nil : .network, retried: retried, mayBeBilled: false
            )
        case .afterSend:
            return RetryDecision(retry: false, errorKind: .network, retried: retried, mayBeBilled: true)
        case .timeout:
            return RetryDecision(retry: false, errorKind: .timeout, retried: retried, mayBeBilled: true)
        case .cancelled:
            return RetryDecision(retry: false, errorKind: nil, retried: retried, mayBeBilled: false)
        }
    }

    /// Failures before the request body could have left the device: DNS, connect,
    /// offline / cellular restrictions, ATS, TLS handshake and certificates.
    private static let preConnectCodes: Set<Int> = [
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
        URLError.Code.notConnectedToInternet.rawValue,
        URLError.Code.internationalRoamingOff.rawValue,
        URLError.Code.dataNotAllowed.rawValue,
        URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue,
        URLError.Code.secureConnectionFailed.rawValue,
        URLError.Code.serverCertificateHasBadDate.rawValue,
        URLError.Code.serverCertificateUntrusted.rawValue,
        URLError.Code.serverCertificateHasUnknownRoot.rawValue,
        URLError.Code.serverCertificateNotYetValid.rawValue,
        URLError.Code.clientCertificateRejected.rawValue,
        URLError.Code.clientCertificateRequired.rawValue,
    ]

    /// `urlErrorCode` is an `NSURLErrorDomain` code.
    /// Checked in order: cancelled, timed out, pre-connect; anything else (connection
    /// lost, bad server response, unknown) is after_send.
    static func transportPhase(urlErrorCode: Int) -> Phase {
        if urlErrorCode == URLError.Code.cancelled.rawValue { return .cancelled }
        if urlErrorCode == URLError.Code.timedOut.rawValue { return .timeout }
        if preConnectCodes.contains(urlErrorCode) { return .preConnect }
        return .afterSend
    }

    /// Sums each batch's images capped at that batch's size. `results[i]` belongs to
    /// `batches[i]`; results past `batches.count` are ignored; cancelled wins and delivers nothing.
    static func aggregate(n: Int, batches: [Int], results: [BatchResult], cancelled: Bool) -> Aggregate {
        if cancelled { return Aggregate(status: .cancelled, delivered: 0, errorKind: nil) }
        let delivered = zip(batches, results).reduce(0) { sum, pair in
            sum + max(0, min(pair.1.images, pair.0))
        }
        if delivered >= n { return Aggregate(status: .completed, delivered: n, errorKind: nil) }
        let firstKind = results.prefix(batches.count).lazy.compactMap(\.errorKind).first
        if delivered > 0 {
            return Aggregate(status: .partial, delivered: delivered, errorKind: firstKind ?? .partial)
        }
        return Aggregate(status: .failed, delivered: 0, errorKind: firstKind ?? .decodeFailed)
    }

    /// Launch reconciliation of a persisted round. `status` is the round status wire name.
    static func reconcile(
        status: String,
        startedAtMs: Int64?,
        nowMs: Int64,
        timeoutSeconds: Int?,
        responseReceived: Bool,
        transferActive: Bool
    ) -> ReconcileAction {
        switch status {
        case "queued": return .interrupted
        case "running": break
        default: return .keep
        }
        if responseReceived { return .process }
        if transferActive { return .keepRunning }
        guard let startedAtMs, nowMs >= startedAtMs else { return .interrupted }
        let limitMs = Int64(effectiveTimeoutSeconds(timeoutSeconds)) * 1000
        return nowMs - startedAtMs >= limitMs ? .failedTimeout : .interrupted
    }
}
