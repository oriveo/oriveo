import Foundation

// MARK: - External search executor (see the external search services contract)
//
// Only responsible for sending buildSearchRequest's result safely and handing the response to parseSearchResponse / classifySearchError:
// - A preset service first runs presetHostCheck; if not ok, not a single byte is sent (the key never leaves);
// - HTTPS only; a custom service's LAN http is resolved twice via RelayRequestSecurity to judge private network and pin the IP (anti DNS rebinding);
// - Redirects are followed only for same-origin (scheme + host + port all identical) 3xx, at most 5 hops, each hop re-running the security check; cross-origin / too many hops abort, recorded as blocked → request_rejected;
// - A response over 2 MB is aborted immediately (response_too_large); the timeout takes clampedLimits / the fixed value for custom services.

nonisolated enum SearchExecutionOutcome: Sendable, Equatable {
    case results([SearchResultItem])
    case empty
    case failure(SearchErrorClassification)
}

nonisolated struct SearchDeadlineExceeded: Error {}

/// Execution result + whether the request was really sent (false = pre-key check failed / rejected locally / empty query).
nonisolated struct SearchExecutionReport: Sendable, Equatable {
    var outcome: SearchExecutionOutcome
    var sent: Bool
}

/// Raw result of the network layer (no business judgment).
nonisolated enum SearchTransportResult: Sendable, Equatable {
    case response(status: Int, body: Data)
    case failure(SearchTransportFailure)
    /// Rejected by the local security policy (plaintext to public network, DNS rebinding, invalid address, redirect abort); reason comes from RelayRequestSecurity or the redirect check.
    case blocked(reason: String)
}

nonisolated struct SearchExecutor: Sendable {
    var session: URLSession = .shared
    /// DNS resolution injected by tests; nil = system resolution.
    var resolver: RelayRequestSecurity.AddressResolver?

    init(session: URLSession = .shared, resolver: RelayRequestSecurity.AddressResolver? = nil) {
        self.session = session
        self.resolver = resolver
    }

    /// Preset service: entry is an entry in the currently adopted catalog (already validated), boundHost is the host confirmed at save time.
    func runPreset(
        entry: SearchJSON,
        regionId: String,
        boundHost: String,
        withdrawn: Bool,
        query: String,
        count: Int?,
        key: String?,
        otherServices: Int = 0
    ) async -> SearchExecutionOutcome {
        await runPresetReport(
            entry: entry, regionId: regionId, boundHost: boundHost, withdrawn: withdrawn,
            query: query, count: count, key: key, otherServices: otherServices
        ).outcome
    }

    /// Same as runPreset, also reporting whether the request was really sent (pre-key check failure and local rejection = false), for the execution-side combined entry to count requests.
    func runPresetReport(
        entry: SearchJSON,
        regionId: String,
        boundHost: String,
        withdrawn: Bool,
        query: String,
        count: Int?,
        key: String?,
        otherServices: Int = 0
    ) async -> SearchExecutionReport {
        let verdict = SearchCatalog.presetHostCheck(boundHost: boundHost, entry: entry, regionId: regionId, withdrawn: withdrawn)
        guard verdict == .ok,
              let spec = entry["transport"],
              let region = SearchCatalog.region(of: entry, id: regionId),
              let host = region["host"]?.stringValue else {
            let preflight: PresetHostVerdict = verdict == .ok ? .serviceWithdrawn : verdict
            return .init(
                outcome: .failure(SearchTransport.classifySearchError(SearchErrorInput(preflight: preflight, otherServices: otherServices))),
                sent: false
            )
        }
        let target = SearchRequestTarget(scheme: "https", host: host, port: nil, path: nil, staticParams: region["static"]?.objectValue)
        // An empty query sends no request and is treated as no results
        guard case .send(let request) = SearchTransport.buildSearchRequest(spec, target: target, query: query, count: count, key: key) else {
            return .init(outcome: .empty, sent: false)
        }
        return await execute(
            request,
            spec: spec,
            count: count,
            timeoutSec: SearchCatalog.clampedLimits(entry).timeoutSec,
            allowsCleartextLAN: false,
            custom: false,
            otherServices: otherServices
        )
    }

    /// Custom service: spec is the built-in SearXNG mapping / manual mapping / "same as X" snapshot; address is an address that already passed form validation.
    func runCustom(
        spec: SearchJSON,
        address: SearchServiceAddress,
        requestPath: String,
        query: String,
        count: Int?,
        key: String?,
        otherServices: Int = 0
    ) async -> SearchExecutionOutcome {
        await runCustomReport(
            spec: spec, address: address, requestPath: requestPath, query: query, count: count, key: key,
            otherServices: otherServices
        ).outcome
    }

    func runCustomReport(
        spec: SearchJSON,
        address: SearchServiceAddress,
        requestPath: String,
        query: String,
        count: Int?,
        key: String?,
        otherServices: Int = 0
    ) async -> SearchExecutionReport {
        let target = SearchRequestTarget(scheme: address.scheme, host: address.host, port: address.port, path: requestPath, staticParams: nil)
        guard case .send(let request) = SearchTransport.buildSearchRequest(spec, target: target, query: query, count: count, key: key) else {
            return .init(outcome: .empty, sent: false)
        }
        return await execute(
            request,
            spec: spec,
            count: count,
            timeoutSec: SearchTransport.customTimeoutSec,
            allowsCleartextLAN: address.scheme == "http",
            custom: true,
            otherServices: otherServices
        )
    }

    private func execute(
        _ request: SearchHTTPRequest,
        spec: SearchJSON,
        count: Int?,
        timeoutSec: Int,
        allowsCleartextLAN: Bool,
        custom: Bool,
        otherServices: Int
    ) async -> SearchExecutionReport {
        let rules = spec["errors"]?.arrayValue ?? []
        func failure(_ input: SearchErrorInput, sent: Bool = true) -> SearchExecutionReport {
            var input = input
            input.rules = rules
            input.custom = custom
            input.otherServices = otherServices
            return .init(outcome: .failure(SearchTransport.classifySearchError(input)), sent: sent)
        }
        switch await send(request, timeoutSec: timeoutSec, allowsCleartextLAN: allowsCleartextLAN) {
        case .failure(let transportFailure):
            return failure(SearchErrorInput(transportFailure: transportFailure))
        case .blocked(let reason):
            // Rejected by the local security policy: the request never left; when a redirect is aborted the first hop was already sent, and it still counts once
            return failure(SearchErrorInput(transportFailure: .blocked), sent: reason == "redirect_rejected")
        case .response(let status, let data):
            let body = try? SearchJSON.parse(data)
            guard (200..<300).contains(status) else {
                return failure(SearchErrorInput(status: status, body: body))
            }
            switch SearchTransport.parseSearchResponse(spec, body: body, count: count) {
            case .results(let items): return .init(outcome: .results(items), sent: true)
            case .empty: return .init(outcome: .empty, sent: true)
            case .error: return failure(SearchErrorInput(parseMismatch: true))
            }
        }
    }

    /// Send the request and read the response (≤ 2 MB). The overall deadline starts at the first DNS resolution and covers the two LAN resolutions and all redirect hops.
    func send(_ request: SearchHTTPRequest, timeoutSec: Int, allowsCleartextLAN: Bool) async -> SearchTransportResult {
        let deadline = ContinuousClock.now + .seconds(min(timeoutSec, SearchHardLimits.maxTimeoutSec))
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(), url.host != nil,
              url.user == nil, url.password == nil else {
            return .blocked(reason: "invalid_url")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = TimeInterval(min(timeoutSec, SearchHardLimits.maxTimeoutSec))
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if let body = request.body { urlRequest.httpBody = body.encodedData() }
        let pin: SearchTaskDelegate.Pin?
        switch scheme {
        case "https":
            pin = nil
        case "http" where allowsCleartextLAN:
            do {
                let addresses = try await Self.beforeDeadline(deadline) { try await self.pinnedAddresses(url) }
                urlRequest = try RelayRequestSecurity.pinCleartextRequest(urlRequest, logicalURL: url, addresses: addresses)
            } catch is SearchDeadlineExceeded {
                return .failure(.timeout)
            } catch ProviderServiceError.invalidConfiguration(let detail) {
                return .blocked(reason: detail)
            } catch {
                return .failure(.network)
            }
            pin = { try await self.pinnedAddresses($0) }
        default:
            return .blocked(reason: "cleartext_not_allowed")
        }
        let delegate = SearchTaskDelegate(originalURL: url, pin: pin, deadline: deadline)
        return await delegate.run(urlRequest, session: RelayRequestSecurity.transportSession(for: session))
    }

    /// Run the operation within the overall deadline, throwing SearchDeadlineExceeded on timeout (a hung DNS resolution cannot run past the deadline either).
    static func beforeDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw SearchDeadlineExceeded() }
            return value
        }
    }

    /// LAN plaintext: resolve twice via RelayRequestSecurity (anti DNS rebinding) and judge private network, returning the IP to pin.
    private func pinnedAddresses(_ url: URL) async throws -> Set<String> {
        let first = try await resolveAndClassify(url)
        let second = try await resolveAndClassify(url)
        guard first == second else { throw RelayRequestSecurity.securityError("dns_rebinding") }
        return first
    }

    private func resolveAndClassify(_ url: URL) async throws -> Set<String> {
        if let resolver {
            return try await RelayRequestSecurity.resolveAndClassify(url, mode: .localHTTP, resolver: resolver)
        }
        return try await RelayRequestSecurity.resolveAndClassify(url, mode: .localHTTP)
    }
}

/// Task-level delegate for one search request: accumulate the response by chunk (cancel immediately beyond 2 MB), overall request deadline, redirect decisions.
///
/// Redirects (same convention on all platforms): follow only same-origin (scheme + host + port all identical) 3xx, at most 5 hops, each hop re-running the security check
/// (LAN plaintext is re-resolved via RelayRequestSecurity and the IP re-pinned); cross-origin, too many hops, or a failed recheck all abort, no further request is sent,
/// recorded as locally rejected (blocked), which the executor maps to request_rejected via classifySearchError.
nonisolated final class SearchTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Pin = @Sendable (URL) async throws -> Set<String>

    static let maxRedirects = 5

    private let originalURL: URL
    private let pin: Pin?
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var hops = 0
    /// Method and body of the current hop (rewritten hop by hop per the contract, not relying on URLSession defaults).
    private var currentMethod = "GET"
    private var currentBody: Data?
    private var rejectedRedirect = false
    private var response: HTTPURLResponse?
    private var received = Data()
    private var tooLarge = false
    private var timedOut = false
    private var continuation: CheckedContinuation<SearchTransportResult, Never>?
    private var result: SearchTransportResult?

    /// pin: the resolved IP pinned for a LAN plaintext request; nil = https.
    /// deadline: the overall deadline of the whole request (counted from the first DNS resolution).
    init(originalURL: URL, pin: Pin?, deadline: ContinuousClock.Instant) {
        self.originalURL = originalURL
        self.pin = pin
        self.deadline = deadline
    }

    func run(_ request: URLRequest, session: URLSession) async -> SearchTransportResult {
        lock.withLock {
            currentMethod = request.httpMethod ?? "GET"
            currentBody = request.httpBody
        }
        let task = session.dataTask(with: request)
        task.delegate = self
        // Overall deadline of the whole request (timeoutInterval only covers idle): lives only within this one request and is cancelled on completion
        let deadline = self.deadline
        let watchdog = Task { [weak self, weak task] in
            try await Task.sleep(until: deadline, clock: .continuous)
            self?.lock.withLock { self?.timedOut = true }
            task?.cancel()
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SearchTransportResult, Never>) in
                let finished: SearchTransportResult? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let finished {
                    continuation.resume(returning: finished)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Response

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let oversized = response.expectedContentLength > Int64(SearchHardLimits.maxResponseBytes)
        lock.withLock {
            self.response = http
            if oversized { tooLarge = true }
        }
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded: Bool = lock.withLock {
            received.append(data)
            if received.count > SearchHardLimits.maxResponseBytes {
                tooLarge = true
                received = Data()
                return true
            }
            return false
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let resumption: (CheckedContinuation<SearchTransportResult, Never>, SearchTransportResult)? = lock.withLock {
            let outcome: SearchTransportResult
            if rejectedRedirect {
                outcome = .blocked(reason: "redirect_rejected")
            } else if tooLarge {
                outcome = .failure(.tooLarge)
            } else if timedOut || (error as? URLError)?.code == .timedOut {
                outcome = .failure(.timeout)
            } else if error == nil, let response {
                outcome = .response(status: response.statusCode, body: received)
            } else {
                outcome = .failure(.network)
            }
            guard result == nil else { return nil }
            result = outcome
            guard let pending = self.continuation else { return nil }
            self.continuation = nil
            return (pending, outcome)
        }
        if let resumption {
            resumption.0.resume(returning: resumption.1)
        }
    }

    // MARK: Redirects

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hop: Int = lock.withLock {
            hops += 1
            return hops
        }
        guard hop <= Self.maxRedirects, let next = request.url, next.user == nil, next.password == nil else {
            reject(task, completionHandler)
            return
        }
        let request = rewritingMethod(request, status: response.statusCode)
        guard let pin else {
            guard next.scheme?.lowercased() == "https", RelayEndpointPolicy.isSameOrigin(originalURL, next) else {
                reject(task, completionHandler)
                return
            }
            completionHandler(request)
            return
        }
        Task {
            // The request address was replaced with the pinned IP, so a relative Location would resolve onto the IP: switch back to the logical host and then check same-origin
            var logical = next
            if next.host != originalURL.host, var components = URLComponents(url: next, resolvingAgainstBaseURL: false),
               let addresses = try? await pin(originalURL), let host = next.host, addresses.contains(host) {
                components.host = originalURL.host
                logical = components.url ?? next
            }
            guard logical.scheme?.lowercased() == "http", RelayEndpointPolicy.isSameOrigin(originalURL, logical),
                  let addresses = try? await pin(logical),
                  let pinned = try? RelayRequestSecurity.pinCleartextRequest(request, logicalURL: logical, addresses: addresses) else {
                reject(task, completionHandler)
                return
            }
            completionHandler(pinned)
        }
    }

    /// 303, and POST hitting 301 / 302 → GET with the body dropped (Content-Type removed); 307 / 308 keep the method and body as is.
    private func rewritingMethod(_ request: URLRequest, status: Int) -> URLRequest {
        var next = request
        let (method, body): (String, Data?) = lock.withLock {
            if status == 303 || ([301, 302].contains(status) && currentMethod == "POST") {
                currentMethod = "GET"
                currentBody = nil
            }
            return (currentMethod, currentBody)
        }
        next.httpMethod = method
        next.httpBodyStream = nil
        next.httpBody = body
        if body == nil { next.setValue(nil, forHTTPHeaderField: "Content-Type") }
        return next
    }

    private func reject(_ task: URLSessionTask, _ completionHandler: (URLRequest?) -> Void) {
        lock.withLock { rejectedRedirect = true }
        completionHandler(nil)
        task.cancel()
    }
}
