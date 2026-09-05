import Foundation
import Testing
@testable import Oriveo

private final class LocalCandidateProbeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Local engine contract classify", .serialized)
struct LocalEngineContractClassifyTests {
    private static let lmStudioV0Payload = """
    {
      "data": [
        {
          "id": "qwen/qwen3-0.6b",
          "object": "model",
          "type": "llm",
          "publisher": "qwen",
          "arch": "qwen3",
          "compatibility_type": "mlx",
          "quantization": "4bit",
          "state": "loaded",
          "max_context_length": 40960
        }
      ],
      "object": "list"
    }
    """

    private static let lmStudioOpenAIPayload = """
    {
      "data": [
        { "id": "qwen/qwen3-0.6b", "object": "model", "owned_by": "organization_owner" }
      ],
      "object": "list"
    }
    """

    private func json(_ raw: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(raw.utf8))
    }

    private func candidateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCandidateProbeProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Lm Studio V0 Classifies Ready")
    func lmStudioV0ClassifiesReady() throws {
        let state = LocalEngineContract.classify(
            engine: .lmstudio,
            status: 200,
            contentType: "application/json; charset=utf-8",
            json: try json(Self.lmStudioV0Payload)
        )
        #expect(state == .ready)
    }

    @Test("Lm Studio Open AIShape Stays Wrong Engine")
    func lmStudioOpenAIShapeStaysWrongEngine() throws {
        let state = LocalEngineContract.classify(
            engine: .lmstudio,
            status: 200,
            contentType: "application/json; charset=utf-8",
            json: try json(Self.lmStudioOpenAIPayload)
        )
        #expect(state == .wrongEngine)
    }

    @Test("Lm Studio Template Paths Match Classify Shape")
    func lmStudioTemplatePathsMatchClassifyShape() {
        let template = LocalEngineTemplate.all[.lmstudio]
        #expect(template?.probePath == "/api/v0/models")
        #expect(template?.catalogPath == "/api/v0/models")
        #expect(template?.introspectionPath == "/api/v0/models")
    }

    @Test("five local engines expose explicit authentication and transport policies")
    func localEngineAuthenticationMatrixIsComplete() {
        for engine in LocalEngineKind.allCases where engine != .openwebui {
            let policy = LocalEngineAuthenticationPolicy.policy(for: engine)
            #expect(policy.authMode == .none)
            #expect(!policy.requiresCredential)
            #expect(policy.permits(securityMode: .localHTTP, hasCredential: false))
            #expect(policy.permits(securityMode: .privateVPN, hasCredential: false))
        }

        let openWebUI = LocalEngineAuthenticationPolicy.policy(for: .openwebui)
        #expect(openWebUI.authMode == .bearer)
        #expect(openWebUI.requiresCredential)
        #expect(!openWebUI.permits(securityMode: .remoteHTTPS, hasCredential: false))
        #expect(openWebUI.permits(securityMode: .remoteHTTPS, hasCredential: true))
        #expect(!openWebUI.permits(securityMode: .localHTTP, hasCredential: true))
        #expect(!openWebUI.permits(securityMode: .privateVPN, hasCredential: true))
    }

    @Test("every local connection failure has one primary recovery action")
    func localFailureRecoveryMatrixIsComplete() {
        #expect(LocalConnectionRecoveryAction.action(for: .invalidEndpoint) == .editAddress)
        #expect(LocalConnectionRecoveryAction.action(for: .cleartextCredentials) == .editAddress)
        #expect(LocalConnectionRecoveryAction.action(for: .wrongEngine) == .chooseEngine)
        #expect(LocalConnectionRecoveryAction.action(for: .engineLoading) == .waitAndRetry)
        #expect(LocalConnectionRecoveryAction.action(for: .noModels) == .chooseModel)
        #expect(LocalConnectionRecoveryAction.action(for: .engineStopped) == .startEngine)
        #expect(LocalConnectionRecoveryAction.action(for: .outOfMemory) == .freeMemory)
        #expect(LocalConnectionRecoveryAction.action(for: .contextExceeded) == .shortenContext)
        #expect(LocalConnectionRecoveryAction.action(for: .timeout) == .waitAndRetry)
        #expect(LocalConnectionRecoveryAction.action(for: .localNetworkDenied) == .openSettings)
    }

    @Test("a verified manual model remains visible even when the catalog omitted it")
    func manualModelIsIncludedInPersistedCatalogPresentation() {
        #expect(LocalEngineConnector.catalogModelIDs(
            discovered: ["catalog-a", "catalog-b"],
            selected: "manual-model"
        ) == ["manual-model", "catalog-a", "catalog-b"])
        #expect(LocalEngineConnector.catalogModelIDs(
            discovered: ["catalog-a", "manual-model"],
            selected: "manual-model"
        ) == ["catalog-a", "manual-model"])
    }

    @Test("generic HTTP discovery stays a candidate until the selected engine signature matches")
    func discoveryCandidateRequiresProductionSignatureProbe() async throws {
        let session = candidateSession()
        LocalCandidateProbeProtocol.responseBody = Data(#"{"models":[{"name":"llama3.2"}]}"#.utf8)
        let endpoint = try await LocalEngineConnector.verifyCandidate(
            engine: .ollama,
            endpoint: "https://example.com",
            securityMode: .remoteHTTPS,
            session: session
        )
        #expect(endpoint == "https://example.com")

        LocalCandidateProbeProtocol.responseBody = Data(#"{"data":[{"id":"not-ollama"}]}"#.utf8)
        await #expect(throws: LocalEngineConnectionError.wrongEngine) {
            _ = try await LocalEngineConnector.verifyCandidate(
                engine: .ollama,
                endpoint: "https://example.com",
                securityMode: .remoteHTTPS,
                session: session
            )
        }
    }
}
