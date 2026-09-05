import Foundation
import Testing
@testable import Oriveo

private final class RelayDiscoveryMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (status, data) = try handler(request)
            guard let requestURL = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func relayProbeBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data
}

private func makeRelayDiscoveryService(
    retryBackoff: [Duration] = [.milliseconds(1), .milliseconds(1)]
) -> RelayDiscoveryService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RelayDiscoveryMockURLProtocol.self]
    return RelayDiscoveryService(
        session: URLSession(configuration: configuration),
        retryBackoff: retryBackoff
    )
}

@Suite("Relay discovery service", .serialized)
@MainActor
struct RelayDiscoveryServiceTests {
    @Test("OpenAI catalog produces honest Chat and Responses candidates")
    func openAICatalogIsAmbiguous() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            return (200, Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-5-mini"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(result.blockingFailure == nil)
        #expect(result.requiresUserTransportChoice)
        #expect(result.detections.map(\.transport) == [.openaiChatCompletions, .openaiResponses])
        #expect(result.detections.first?.modelIDs == ["gpt-5", "gpt-5-mini"])
    }

    @Test("explicit Responses route removes ambiguity and avoids duplicate endpoint path")
    func explicitResponsesRoute() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/models")
            return (200, Data(#"{"data":[]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com/v1/responses",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(result.detections.count == 1)
        #expect(result.detections.first?.transport == .openaiResponses)
        #expect(result.detections.first?.apiBaseURL == "https://relay.example.com/v1")
    }

    @Test("404 on versioned catalog falls back to a versionless API root")
    func versionlessFallback() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var paths: [String] = []
        RelayDiscoveryMockURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            paths.append(path)
            if path == "/v1/models" {
                return (404, Data(#"{"error":"not found"}"#.utf8))
            }
            #expect(path == "/models")
            return (200, Data(#"{"data":[{"id":"local-model"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(paths == ["/v1/models", "/models"])
        #expect(result.detections.first?.apiBaseURL == "https://relay.example.com")
        #expect(result.detections.first?.endpointEvidence == .versionlessFallback)
    }

    @Test("200 HTML fallback page does not abort the remaining candidates")
    func htmlFallbackPageKeepsProbing() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var paths: [String] = []
        RelayDiscoveryMockURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            paths.append(path)
            if path == "/v1/models" {
                return (200, Data("<!doctype html><html><body>relay console</body></html>".utf8))
            }
            #expect(path == "/models")
            return (200, Data(#"{"data":[{"id":"real-model"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(paths == ["/v1/models", "/models"])
        #expect(result.detections.first?.modelIDs == ["real-model"])
        #expect(result.blockingFailure == nil)
    }

    @Test("exhausting candidates after an HTML answer reports invalidResponse, not routeUnavailable")
    func htmlOnlyRelayReportsInvalidResponse() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { _ in
            (200, Data("<!doctype html><html><body>relay console</body></html>".utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(result.detections.isEmpty)
        #expect(result.blockingFailure == .invalidResponse)
    }

    @Test("authentication rejection stops before rotating protocols or auth headers")
    func authenticationStopsDiscovery() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var requestCount = 0
        RelayDiscoveryMockURLProtocol.handler = { _ in
            requestCount += 1
            return (401, Data(#"{"error":"invalid key"}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "wrong",
            modelHint: nil
        )

        #expect(requestCount == 1)
        #expect(result.detections.isEmpty)
        #expect(result.blockingFailure == .authenticationRejected)
    }

    @Test("Gemini hint uses v1beta catalog and header authentication")
    func geminiCatalog() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1beta/models")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gem-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"models":[{"name":"models/gemini-2.5-pro"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "gem-key",
            modelHint: "gemini-2.5-pro"
        )

        #expect(result.detections.map(\.transport) == [.geminiGenerateContent])
        #expect(result.detections.first?.modelIDs == ["gemini-2.5-pro"])
    }

    @Test("well-known key prefixes only reorder candidates and do not rotate after auth rejection")
    func keyPrefixSafelyReordersCandidates() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://relay.example.com/v1/models")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"data":[{"id":"claude-proxy"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "sk-ant-test",
            modelHint: nil
        )

        #expect(result.detections.map(\.transport) == [.anthropicMessages])
    }

    @Test("catalog-less Codex relay is identified by probing the generation endpoint")
    func generationProbeIdentifiesResponsesOnlyRelay() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var probedModels: [String] = []
        RelayDiscoveryMockURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            guard path.hasSuffix("/responses") else {
                return (404, Data(#"{"code":404,"msg":"Not Found"}"#.utf8))
            }
            #expect(request.httpMethod == "POST")
            let body = try #require(relayProbeBody(from: request))
            let payload = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            probedModels.append(try #require(payload["model"] as? String))
            return (
                400,
                Data(#"{"code":400,"msg":"/,: Codex-Api"}"#.utf8)
            )
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com/codex",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(result.blockingFailure == nil)
        #expect(result.detections.map(\.transport) == [.openaiResponses])
        #expect(result.detections.first?.detectionEvidence == .generationProbe)
        #expect(result.detections.first?.modelIDs.isEmpty == true)
        #expect(result.detections.first?.generationVerified == false)
        #expect(probedModels.allSatisfy { $0 == RelayDiscoveryService.sentinelProbeModelID })
        #expect(result.attempts.contains { $0.kind == .generationProbe })
        #expect(result.attempts.last?.upstreamMessage?.contains("Codex-Api") == true)
    }

    @Test("a user-supplied model that actually generates counts as verified")
    func generationProbeWithUserModelIsVerified() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            guard path.hasSuffix("/responses") else {
                return (404, Data(#"{"code":404}"#.utf8))
            }
            let body = try #require(relayProbeBody(from: request))
            let payload = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(payload["model"] as? String == "gpt-5-codex")
            return (200, Data(#"{"id":"resp_1","output":[]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com/codex",
            apiKey: "secret",
            modelHint: "gpt-5-codex"
        )

        #expect(result.detections.map(\.transport) == [.openaiResponses])
        #expect(result.detections.first?.generationVerified == true)
    }

    @Test("SSE and opaque non-HTML 2xx responses remain compatible")
    func nonJSONGenerationSuccessRemainsCompatible() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { request in
            let path = try #require(request.url?.path)
            guard path.hasSuffix("/responses") else {
                return (404, Data(#"{"code":404}"#.utf8))
            }
            return (200, Data("data: {\"output\":[]}\n\ndata: [DONE]\n\n".utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com/codex",
            apiKey: "secret",
            modelHint: "gpt-relay"
        )

        #expect(result.detections.first?.transport == .openaiResponses)
        #expect(result.detections.first?.generationVerified == true)
    }

    @Test("default HTTPS port and explicit 443 are the same origin")
    func defaultHTTPSPortIsSameOrigin() throws {
        let implicit = try #require(URL(string: "https://relay.example.com/v1/models"))
        let explicit = try #require(URL(string: "https://relay.example.com:443/next"))
        let different = try #require(URL(string: "https://relay.example.com:8443/next"))

        #expect(RelayEndpointPolicy.isSameOrigin(implicit, explicit))
        #expect(!RelayEndpointPolicy.isSameOrigin(implicit, different))
    }

    @Test("probing stops immediately when the relay rejects the credential")
    func generationProbeStopsOnAuthRejection() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var probeCount = 0
        RelayDiscoveryMockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (404, Data(#"{"code":404}"#.utf8))
            }
            probeCount += 1
            return (401, Data(#"{"error":"invalid key"}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "wrong",
            modelHint: nil
        )

        #expect(probeCount == 1)
        #expect(result.detections.isEmpty)
        #expect(result.blockingFailure == .authenticationRejected)
    }

    @Test("exhausting both catalog and probe routes still reports routeUnavailable")
    func generationProbeExhaustionKeepsManualFallback() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var probeMethods: Set<String> = []
        RelayDiscoveryMockURLProtocol.handler = { request in
            probeMethods.insert(request.httpMethod ?? "")
            return (404, Data(#"{"code":404}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(probeMethods == ["GET", "POST"])
        #expect(result.detections.isEmpty)
        #expect(result.blockingFailure == .routeUnavailable)
        #expect(result.attempts.contains { $0.kind == .catalog })
        #expect(result.attempts.contains { $0.kind == .generationProbe })
    }

    @Test("a transient network blip is retried instead of failing the whole round")
    func transientNetworkFailureIsRetried() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var calls = 0
        RelayDiscoveryMockURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"data":[{"id":"gpt-5"}]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(calls == 2)
        #expect(result.blockingFailure == nil)
        #expect(result.detections.first?.modelIDs == ["gpt-5"])
    }

    @Test("deterministic failures are not retried")
    func deterministicFailureIsNotRetried() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var calls = 0
        RelayDiscoveryMockURLProtocol.handler = { _ in
            calls += 1
            throw URLError(.secureConnectionFailed)
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(calls == 1)
        #expect(result.blockingFailure == .network)
    }

    @Test("a blip that never clears reports the reason and says it already retried")
    func exhaustedRetriesExplainThemselves() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var calls = 0
        RelayDiscoveryMockURLProtocol.handler = { _ in
            calls += 1
            throw URLError(.timedOut)
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(calls == 3)
        #expect(result.blockingFailure == .network)
        let reason = try #require(result.attempts.last?.upstreamMessage)
        #expect(reason.contains("2"))
    }

    @Test("network failures carry the underlying reason, not just a blank status")
    func networkFailureKeepsUnderlyingReason() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        RelayDiscoveryMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com",
            apiKey: "secret",
            modelHint: nil
        )

        #expect(result.blockingFailure == .network)
        let attempt = try #require(result.attempts.last)
        #expect(attempt.statusCode == nil)
        let reason = try #require(attempt.upstreamMessage)
        #expect(reason.contains("\(URLError.timedOut.rawValue)"))
        #expect(!reason.isEmpty)
    }

    @Test("embedded endpoint query is rejected without sending a request")
    func embeddedQueryIsBlocked() async throws {
        defer { RelayDiscoveryMockURLProtocol.handler = nil }
        var requestCount = 0
        RelayDiscoveryMockURLProtocol.handler = { _ in
            requestCount += 1
            return (200, Data(#"{"data":[]}"#.utf8))
        }

        let result = try await makeRelayDiscoveryService().discover(
            endpoint: "https://relay.example.com/v1?key=secret",
            apiKey: "",
            modelHint: nil
        )

        #expect(requestCount == 0)
        #expect(result.blockingFailure == .embeddedQuery)
    }
}
