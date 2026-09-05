import Foundation
import Testing
@testable import Oriveo

private final class ProviderManagerRelaySyncURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requests = []
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let modelsPayload = Data(#"{"data":[{"id":"gpt-catalog-new"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: modelsPayload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeProviderManagerRelaySyncSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderManagerRelaySyncURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Suite("ProviderManager Relay catalog sync", .serialized)
@MainActor
struct ProviderManagerRelaySyncTests {
    @Test("Catalog Refresh Retains Enabled Model Missing From Result")
    func catalogRefreshRetainsEnabledModelMissingFromResult() async throws {
        ProviderManagerRelaySyncURLProtocol.reset()
        let manager = ProviderManager()
        let retained = TestFactories.makeModel(
            id: "still-sendable",
            isAvailable: true,
            isDefault: true
        )
        let discovered = TestFactories.makeModel(id: "gpt-catalog-new")
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [retained],
            catalogModels: [retained]
        )

        let syncResult = try await OpenAIService(session: makeProviderManagerRelaySyncSession()).syncProvider(
            apiKey: "test-key",
            preferredModelID: discovered.id,
            baseURL: "https://relay.example.com/v1",
            relayRequested: RelayRequestedConfig(
                transport: .openaiChatCompletions,
                authMode: .bearer,
                securityMode: .remoteHTTPS,
                modelID: discovered.id
            )
        )

        let requests = ProviderManagerRelaySyncURLProtocol.capturedRequests()
        #expect(requests.map { $0.url?.path } == ["/v1/models"])
        #expect(syncResult.models.map(\.id) == [discovered.id])
        manager.applyRelaySyncResult(syncResult, to: &provider)

        #expect(provider.catalogModels.map(\.id) == [discovered.id])
        #expect(provider.models.contains(where: { $0.id == "still-sendable" && $0.isAvailable }))
    }

    @Test("Catalog Refresh Write Gate Preserves Concurrent Provider Changes")
    func catalogRefreshWriteGatePreservesConcurrentProviderChanges() async throws {
        ProviderManagerRelaySyncURLProtocol.reset()
        let manager = ProviderManager()
        let oldDefault = TestFactories.makeModel(id: "old-default", isDefault: true)
        let newDefault = TestFactories.makeModel(id: "new-default", isDefault: false)
        var starting = TestFactories.makeProvider(
            kind: .relay,
            models: [oldDefault, newDefault],
            catalogModels: [oldDefault, newDefault],
            baseURLText: "https://relay.example.com/v1"
        )
        starting.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            securityMode: .remoteHTTPS,
            modelID: oldDefault.id
        )
        let identity = RelayCatalogConnectionIdentity(provider: starting)
        let token = UUID()

        var current = starting
        current.status = .syncing
        current.customName = "Renamed while loading"
        current.relayRequested?.modelID = newDefault.id
        current = ProviderManager.applyingRelayDefaultModelSelection(to: current, modelID: newDefault.id)
        #expect(RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: current,
            connectionIdentity: identity
        ))

        // syncResult comes from the production `/models` decoder, not a fixture.
        let syncResult = try await OpenAIService(session: makeProviderManagerRelaySyncSession()).syncProvider(
            apiKey: starting.apiKey,
            preferredModelID: starting.defaultModel?.id,
            baseURL: starting.baseURLText,
            relayRequested: starting.relayRequested
        )
        let latestDefaultModelID = current.relayRequested?.modelID ?? current.defaultModel?.id
        manager.applyRelaySyncResult(syncResult, to: &current)
        current = ModelResolver.synchronizeDefaultSelection(in: current, preferredModelID: latestDefaultModelID)
        #expect(current.customName == "Renamed while loading")
        #expect(current.defaultModel?.id == newDefault.id)

        var rotatedKey = current
        rotatedKey.apiKey = "rotated-key"
        #expect(!RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: rotatedKey,
            connectionIdentity: identity
        ))

        var changedKind = current
        changedKind.relayKind = .custom
        #expect(!RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: changedKind,
            connectionIdentity: identity
        ))
    }

    @Test("Catalog Refresh Write Gate Keeps Connection State Out Of Band")
    func catalogRefreshWriteGateKeepsConnectionStateOutOfBand() {
        let provider = TestFactories.makeProvider(kind: .relay, status: .connected)
        let identity = RelayCatalogConnectionIdentity(provider: provider)
        let token = UUID()
        #expect(RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: provider,
            connectionIdentity: identity
        ))
        #expect(provider.status == .connected)
    }

    @Test("Generation Write Gate Rejects Changed Connection")
    func generationWriteGateRejectsChangedConnection() {
        let original = TestFactories.makeProvider(
            kind: .relay,
            baseURLText: "https://old-relay.example.com/v1"
        )
        let identity = RelayCatalogConnectionIdentity(provider: original)
        var changed = original
        changed.baseURLText = "https://new-relay.example.com/v1"
        #expect(!RelayGenerationVerificationWritePolicy.mayCommit(
            current: changed,
            connectionIdentity: identity
        ))
        #expect(RelayGenerationVerificationWritePolicy.mayCommit(
            current: original,
            connectionIdentity: identity
        ))
    }

}
