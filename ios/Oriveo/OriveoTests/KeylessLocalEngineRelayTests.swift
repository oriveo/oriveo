import Foundation
import Testing
@testable import Oriveo

private final class KeylessRelayCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedURLs: [String] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURLs.append(request.url?.absoluteString ?? "")
        let body = """
        {"data":[{"id":"qwen/qwen3-0.6b","object":"model"}],"object":"list"}
        """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Keyless local engine relay", .serialized)
struct KeylessLocalEngineRelayTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeylessRelayCaptureProtocol.self]
        return URLSession(configuration: config)
    }

    private func localEngineConfig() -> RelayRequestedConfig {
        var config = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: RelayAuthMode.none,
            securityMode: .localHTTP
        )
        config.engineProfile = "lmstudio"
        config.resolvedAPIBaseURL = "http://192.168.31.250:1234/v1"
        return config
    }

    @Test("Keyless Gate Semantics")
    func keylessGateSemantics() {
        let service = OpenAIService(session: makeSession())
        #expect(throws: Never.self) {
            try service.validateRelayAPIKeyIfRequired("", relayRequested: localEngineConfig())
        }
        #expect(throws: (any Error).self) {
            try service.validateRelayAPIKeyIfRequired("", relayRequested: RelayRequestedConfig())
        }
        #expect(throws: (any Error).self) {
            try service.validateRelayAPIKeyIfRequired("", relayRequested: nil)
        }
    }

    @Test("Keyless Catalog Sync Passes Gates")
    func keylessCatalogSyncPassesGates() async {
        let service = OpenAIService(session: makeSession())
        do {
            _ = try await service.syncProvider(
                apiKey: "",
                preferredModelID: nil,
                baseURL: "http://192.168.31.250:1234",
                relayRequested: localEngineConfig()
            )
        } catch let error as ProviderServiceError {
            if case .invalidAPIKey = error {
                Issue.record("A local-engine empty key should not be intercepted up front")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        var request = URLRequest(url: URL(string: "http://192.168.31.250:1234/v1/models")!)
        request.applyRelaySecurityMode(localEngineConfig())
        await #expect(throws: Never.self) {
            _ = try await RelayRequestSecurity.prepare(request)
        }
    }

    @Test("Cloud Relay Catalog Sync Still Requires Key")
    func cloudRelayCatalogSyncStillRequiresKey() async {
        KeylessRelayCaptureProtocol.capturedURLs = []
        let service = OpenAIService(session: makeSession())
        do {
            _ = try await service.syncProvider(
                apiKey: "",
                preferredModelID: nil,
                baseURL: "https://relay.example.com/v1",
                relayRequested: RelayRequestedConfig()
            )
            Issue.record("A cloud-relay empty key should not pass catalog sync")
        } catch let error as ProviderServiceError {
            guard case .invalidAPIKey = error else {
                Issue.record("Expected invalidAPIKey, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ProviderServiceError.invalidAPIKey, got \(error)")
        }
        #expect(KeylessRelayCaptureProtocol.capturedURLs.isEmpty)
    }
}
