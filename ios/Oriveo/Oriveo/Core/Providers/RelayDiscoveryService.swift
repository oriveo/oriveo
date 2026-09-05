import Foundation

enum RelayDiscoveryFailureKind: String, Equatable, Sendable {
    case invalidEndpoint
    case embeddedQuery
    case authenticationRejected
    case routeUnavailable
    case rateLimited
    case temporaryFailure
    case invalidResponse
    case network
}

enum RelayDiscoveryAttemptKind: String, Equatable, Sendable {
    case catalog
    case generationProbe
}

enum RelayDetectionEvidence: String, Equatable, Sendable {
    case catalog
    case generationProbe
}

struct RelayDiscoveryAttempt: Equatable, Sendable {
    let candidate: RelayEndpointCandidate
    let requestURL: String
    let statusCode: Int?
    let failure: RelayDiscoveryFailureKind?
    let kind: RelayDiscoveryAttemptKind
    let upstreamMessage: String?

    init(
        candidate: RelayEndpointCandidate,
        requestURL: String,
        statusCode: Int?,
        failure: RelayDiscoveryFailureKind?,
        kind: RelayDiscoveryAttemptKind = .catalog,
        upstreamMessage: String? = nil
    ) {
        self.candidate = candidate
        self.requestURL = requestURL
        self.statusCode = statusCode
        self.failure = failure
        self.kind = kind
        self.upstreamMessage = upstreamMessage
    }
}

struct RelayDetectedConfiguration: Equatable, Sendable, Identifiable {
    var id: String { "\(transport.rawValue)|\(apiBaseURL)" }

    let transport: RelayTransport
    let authMode: RelayAuthMode
    let apiBaseURL: String
    let modelIDs: [String]
    let endpointEvidence: RelayEndpointCandidateEvidence
    let generationVerified: Bool
    let detectionEvidence: RelayDetectionEvidence

    init(
        transport: RelayTransport,
        authMode: RelayAuthMode,
        apiBaseURL: String,
        modelIDs: [String],
        endpointEvidence: RelayEndpointCandidateEvidence,
        generationVerified: Bool,
        detectionEvidence: RelayDetectionEvidence = .catalog
    ) {
        self.transport = transport
        self.authMode = authMode
        self.apiBaseURL = apiBaseURL
        self.modelIDs = modelIDs
        self.endpointEvidence = endpointEvidence
        self.generationVerified = generationVerified
        self.detectionEvidence = detectionEvidence
    }
}

struct RelayDiscoveryResult: Equatable, Sendable {
    let descriptor: RelayEndpointDescriptor
    let detections: [RelayDetectedConfiguration]
    let attempts: [RelayDiscoveryAttempt]
    let blockingFailure: RelayDiscoveryFailureKind?

    var requiresUserTransportChoice: Bool { detections.count > 1 }
}

final class RelayDiscoveryService: BaseAPIService {
    private struct ProbeOutcome {
        let result: RelayDiscoveryResult?
        let attempts: [RelayDiscoveryAttempt]
    }

    static let defaultRetryBackoff: [Duration] = [.milliseconds(400), .milliseconds(1200)]

    private let retryBackoff: [Duration]

    init(session: URLSession = .shared, retryBackoff: [Duration] = RelayDiscoveryService.defaultRetryBackoff) {
        self.retryBackoff = retryBackoff
        super.init(session: session)
    }

    convenience init() {
        self.init(session: Self.makeDiscoverySession())
    }

    func discover(
        endpoint: String,
        apiKey: String,
        modelHint: String?,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS
    ) async throws -> RelayDiscoveryResult {
        let descriptor: RelayEndpointDescriptor
        do {
            descriptor = try RelayEndpointResolver.describe(endpoint)
        } catch {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Relay endpoint.")
        }

        guard !descriptor.containsEmbeddedQuery else {
            return RelayDiscoveryResult(
                descriptor: descriptor,
                detections: [],
                attempts: [],
                blockingFailure: .embeddedQuery
            )
        }

        var attempts: [RelayDiscoveryAttempt] = []
        let orderedTransports = transportOrder(
            descriptor: descriptor,
            modelHint: modelHint,
            apiKey: apiKey
        )

        for transport in orderedTransports {
            let authMode = defaultAuthMode(for: transport)
            for candidate in RelayEndpointResolver.candidates(for: descriptor, transport: transport) {
                try Task.checkCancellation()
                let catalogURL = try RelayEndpointResolver.endpointURL(
                    apiBaseURL: candidate.apiBaseURL,
                    endpointPath: "/models"
                )
                var request = URLRequest(url: catalogURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 12
                applyCatalogHeaders(
                    to: &request,
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    transport: transport
                )
                request.applyRelaySecurityMode(
                    RelayRequestedConfig(authMode: .none, securityMode: securityMode)
                )

                let data: Data
                let response: URLResponse
                do {
                    (data, response, _) = try await dataWithRetry(for: request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: nil,
                        failure: .network,
                        upstreamMessage: Self.networkFailureSummary(
                            error,
                            retriedTimes: Self.isTransientNetworkFailure(error) ? retryBackoff.count : 0
                        )
                    ))
                    return result(
                        descriptor: descriptor,
                        attempts: attempts,
                        failure: .network
                    )
                }

                guard let http = response as? HTTPURLResponse else {
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: nil,
                        failure: .network,
                        upstreamMessage: Self.nonHTTPResponseSummary
                    ))
                    return result(descriptor: descriptor, attempts: attempts, failure: .network)
                }

                switch http.statusCode {
                case 200 ..< 300:
                    guard let modelIDs = parseModelIDs(data: data, transport: transport) else {
                        attempts.append(.init(
                            candidate: candidate,
                            requestURL: catalogURL.absoluteString,
                            statusCode: http.statusCode,
                            failure: .invalidResponse,
                            upstreamMessage: Self.upstreamSummary(data)
                        ))
                        continue
                    }
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: nil,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    let transports = detectedTransports(
                        requestedTransport: transport,
                        descriptor: descriptor
                    )
                    let detections = transports.map { detectedTransport in
                        RelayDetectedConfiguration(
                            transport: detectedTransport,
                            authMode: authMode,
                            apiBaseURL: candidate.apiBaseURL,
                            modelIDs: modelIDs,
                            endpointEvidence: candidate.evidence,
                            generationVerified: false,
                            detectionEvidence: .catalog
                        )
                    }
                    return RelayDiscoveryResult(
                        descriptor: descriptor,
                        detections: detections,
                        attempts: attempts,
                        blockingFailure: nil
                    )
                case 401, 403:
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: .authenticationRejected,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    return result(
                        descriptor: descriptor,
                        attempts: attempts,
                        failure: .authenticationRejected
                    )
                case 404, 405:
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: .routeUnavailable,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    continue
                case 429:
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: .rateLimited,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    return result(descriptor: descriptor, attempts: attempts, failure: .rateLimited)
                case 500 ... 599:
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: .temporaryFailure,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    return result(
                        descriptor: descriptor,
                        attempts: attempts,
                        failure: .temporaryFailure
                    )
                default:
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: catalogURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: .invalidResponse,
                        upstreamMessage: Self.upstreamSummary(data)
                    ))
                    return result(
                        descriptor: descriptor,
                        attempts: attempts,
                        failure: .invalidResponse
                    )
                }
            }
        }

        let probe = try await probeGenerationRoutes(
            descriptor: descriptor,
            apiKey: apiKey,
            modelHint: modelHint,
            securityMode: securityMode,
            priorAttempts: attempts
        )
        attempts = probe.attempts
        if let probed = probe.result {
            return probed
        }

        let exhaustedFailure: RelayDiscoveryFailureKind = attempts.contains { $0.failure == .invalidResponse }
            ? .invalidResponse
            : .routeUnavailable
        return result(descriptor: descriptor, attempts: attempts, failure: exhaustedFailure)
    }

    private func probeGenerationRoutes(
        descriptor: RelayEndpointDescriptor,
        apiKey: String,
        modelHint: String?,
        securityMode: RelayConnectionSecurityMode,
        priorAttempts: [RelayDiscoveryAttempt]
    ) async throws -> ProbeOutcome {
        var attempts = priorAttempts
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = modelHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usesUserModel = !hint.isEmpty
        let probeModel = usesUserModel ? hint : Self.sentinelProbeModelID

        for transport in probeTransportOrder(
            descriptor: descriptor,
            modelHint: modelHint,
            apiKey: trimmedKey
        ) {
            let authMode = defaultAuthMode(for: transport)
            for candidate in RelayEndpointResolver.candidates(for: descriptor, transport: transport) {
                try Task.checkCancellation()
                guard let spec = probeSpec(for: transport, modelID: probeModel),
                      let probeURL = try? RelayEndpointResolver.endpointURL(
                          apiBaseURL: candidate.apiBaseURL,
                          endpointPath: spec.path
                      ),
                      let body = try? JSONSerialization.data(withJSONObject: spec.body) else {
                    continue
                }

                var request = URLRequest(url: probeURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 12
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                applyCatalogHeaders(to: &request, apiKey: trimmedKey, transport: transport)
                request.httpBody = body
                request.applyRelaySecurityMode(
                    RelayRequestedConfig(authMode: .none, securityMode: securityMode)
                )

                let data: Data
                let response: URLResponse
                do {
                    (data, response, _) = try await dataWithRetry(for: request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: probeURL.absoluteString,
                        statusCode: nil,
                        failure: .network,
                        kind: .generationProbe,
                        upstreamMessage: Self.networkFailureSummary(
                            error,
                            retriedTimes: Self.isTransientNetworkFailure(error) ? retryBackoff.count : 0
                        )
                    ))
                    return ProbeOutcome(
                        result: result(descriptor: descriptor, attempts: attempts, failure: .network),
                        attempts: attempts
                    )
                }

                guard let http = response as? HTTPURLResponse else {
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: probeURL.absoluteString,
                        statusCode: nil,
                        failure: .network,
                        kind: .generationProbe,
                        upstreamMessage: Self.nonHTTPResponseSummary
                    ))
                    return ProbeOutcome(
                        result: result(descriptor: descriptor, attempts: attempts, failure: .network),
                        attempts: attempts
                    )
                }

                let summary = Self.upstreamSummary(data)

                func record(_ failure: RelayDiscoveryFailureKind?) {
                    attempts.append(.init(
                        candidate: candidate,
                        requestURL: probeURL.absoluteString,
                        statusCode: http.statusCode,
                        failure: failure,
                        kind: .generationProbe,
                        upstreamMessage: summary
                    ))
                }

                func hit(generationVerified: Bool) -> ProbeOutcome {
                    let detected = RelayDiscoveryResult(
                        descriptor: descriptor,
                        detections: [
                            RelayDetectedConfiguration(
                                transport: transport,
                                authMode: authMode,
                                apiBaseURL: candidate.apiBaseURL,
                                modelIDs: [],
                                endpointEvidence: candidate.evidence,
                                generationVerified: generationVerified,
                                detectionEvidence: .generationProbe
                            ),
                        ],
                        attempts: attempts,
                        blockingFailure: nil
                    )
                    return ProbeOutcome(result: detected, attempts: attempts)
                }

                switch http.statusCode {
                case 200 ..< 300:
                    guard RelaySuccessResponsePolicy.acceptsGenerationResponse(data: data, response: http) else {
                        record(.invalidResponse)
                        continue
                    }
                    record(nil)
                    return hit(generationVerified: usesUserModel)
                case 400, 422:
                    record(nil)
                    return hit(generationVerified: false)
                case 401, 403:
                    record(.authenticationRejected)
                    return ProbeOutcome(
                        result: result(
                            descriptor: descriptor,
                            attempts: attempts,
                            failure: .authenticationRejected
                        ),
                        attempts: attempts
                    )
                case 429:
                    record(.rateLimited)
                    return ProbeOutcome(
                        result: result(descriptor: descriptor, attempts: attempts, failure: .rateLimited),
                        attempts: attempts
                    )
                case 500 ... 599:
                    record(.temporaryFailure)
                    return ProbeOutcome(
                        result: result(
                            descriptor: descriptor,
                            attempts: attempts,
                            failure: .temporaryFailure
                        ),
                        attempts: attempts
                    )
                default:
                    record(.routeUnavailable)
                    continue
                }
            }
        }
        return ProbeOutcome(result: nil, attempts: attempts)
    }

    private func probeTransportOrder(
        descriptor: RelayEndpointDescriptor,
        modelHint: String?,
        apiKey: String
    ) -> [RelayTransport] {
        if let explicit = descriptor.explicitTransport {
            return [explicit]
        }
        var ordered = transportOrder(descriptor: descriptor, modelHint: modelHint, apiKey: apiKey)
        if let chatIndex = ordered.firstIndex(of: .openaiChatCompletions) {
            ordered.insert(.openaiResponses, at: ordered.index(after: chatIndex))
        } else {
            ordered.append(.openaiResponses)
        }
        return ordered
    }

    private func probeSpec(
        for transport: RelayTransport,
        modelID: String
    ) -> (path: String, body: [String: Any])? {
        switch transport {
        case .llamacppNative:
            return ("/completion", ["prompt": "ping", "n_predict": 1])
        case .openaiChatCompletions:
            return (
                "/chat/completions",
                [
                    "model": modelID,
                    "messages": [["role": "user", "content": "ping"]],
                    "max_tokens": 1,
                ]
            )
        case .openaiResponses:
            return (
                "/responses",
                [
                    "model": modelID,
                    "input": "ping",
                    "max_output_tokens": 1,
                    "store": false,
                ]
            )
        case .anthropicMessages:
            return (
                "/messages",
                [
                    "model": modelID,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "ping"]],
                ]
            )
        case .geminiGenerateContent:
            return (
                "/models/\(modelID):generateContent",
                [
                    "contents": [["role": "user", "parts": [["text": "ping"]]]],
                    "generationConfig": ["maxOutputTokens": 1],
                ]
            )
        case .auto:
            return nil
        }
    }

    private func result(
        descriptor: RelayEndpointDescriptor,
        attempts: [RelayDiscoveryAttempt],
        failure: RelayDiscoveryFailureKind
    ) -> RelayDiscoveryResult {
        RelayDiscoveryResult(
            descriptor: descriptor,
            detections: [],
            attempts: attempts,
            blockingFailure: failure
        )
    }

    private func transportOrder(
        descriptor: RelayEndpointDescriptor,
        modelHint: String?,
        apiKey: String
    ) -> [RelayTransport] {
        if let explicit = descriptor.explicitTransport {
            return [explicit]
        }

        let hint = modelHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if descriptor.explicitVersion == "v1beta" || hint.contains("gemini") || normalizedKey.hasPrefix("aiza") {
            return [.geminiGenerateContent, .openaiChatCompletions, .anthropicMessages]
        }
        if hint.contains("claude") || normalizedKey.hasPrefix("sk-ant-") {
            return [.anthropicMessages, .openaiChatCompletions, .geminiGenerateContent]
        }
        return [.openaiChatCompletions, .anthropicMessages, .geminiGenerateContent]
    }

    private func detectedTransports(
        requestedTransport: RelayTransport,
        descriptor: RelayEndpointDescriptor
    ) -> [RelayTransport] {
        if descriptor.explicitTransport != nil {
            return [requestedTransport]
        }
        if requestedTransport == .openaiChatCompletions {
            return [.openaiChatCompletions, .openaiResponses]
        }
        return [requestedTransport]
    }

    private func defaultAuthMode(for transport: RelayTransport) -> RelayAuthMode {
        switch transport {
        case .llamacppNative: return .none
        case .anthropicMessages: return .xApiKey
        case .geminiGenerateContent: return .xGoogApiKey
        case .openaiChatCompletions, .openaiResponses, .auto: return .bearer
        }
    }

    private func applyCatalogHeaders(
        to request: inout URLRequest,
        apiKey: String,
        transport: RelayTransport
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UserAgentProvider.nativeUserAgent, forHTTPHeaderField: "User-Agent")
        guard RelayCredentialPolicy.hasStoredKey(apiKey) else { return }
        switch transport {
        case .llamacppNative:
            break
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiGenerateContent:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .openaiChatCompletions, .openaiResponses, .auto:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func parseModelIDs(data: Data, transport: RelayTransport) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rawItems: [Any]?
        if let object = root as? [String: Any] {
            if transport == .geminiGenerateContent {
                rawItems = object["models"] as? [Any]
            } else {
                rawItems = object["data"] as? [Any] ?? object["models"] as? [Any]
            }
        } else {
            rawItems = root as? [Any]
        }
        guard let rawItems else { return nil }

        var seen: Set<String> = []
        return rawItems.compactMap { item -> String? in
            let rawID: String?
            if let string = item as? String {
                rawID = string
            } else if let object = item as? [String: Any] {
                rawID = (object["id"] as? String) ?? (object["name"] as? String)
            } else {
                rawID = nil
            }
            guard var id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            if transport == .geminiGenerateContent, id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            guard seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static let sentinelProbeModelID = "oriveo-endpoint-probe-no-such-model"

    private func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse, Int) {
        var lastError: Error?
        for attemptIndex in 0 ... retryBackoff.count {
            do {
                let (data, response) = try await session.relayData(for: request)
                return (data, response, attemptIndex)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard Self.isTransientNetworkFailure(error), attemptIndex < retryBackoff.count else {
                    throw error
                }
                try await Task.sleep(for: retryBackoff[attemptIndex])
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    static func isTransientNetworkFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func networkFailureSummary(_ error: Error, retriedTimes: Int = 0) -> String {
        let description = error.localizedDescription
        var summary = description
        if let urlError = error as? URLError {
            summary = "\(description) (URLError \(urlError.errorCode))"
        }
        guard retriedTimes > 0 else { return summary }
        return summary + " • " + String(
            format: L10n.tr("Retried %d time(s) automatically.", table: .providers),
            retriedTimes
        )
    }

    static var nonHTTPResponseSummary: String {
        L10n.tr("The server did not return an HTTP response.", table: .providers)
    }

    static func upstreamSummary(_ data: Data, limit: Int = 300) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let condensed = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condensed.isEmpty else { return nil }
        return condensed.count <= limit
            ? condensed
            : String(condensed.prefix(limit)) + "…"
    }

    private static func makeDiscoverySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(
            configuration: configuration,
            delegate: RelayDiscoveryRedirectGuard(),
            delegateQueue: nil
        )
    }
}

private final class RelayDiscoveryRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              RelayEndpointPolicy.isSameOrigin(original, redirected) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
