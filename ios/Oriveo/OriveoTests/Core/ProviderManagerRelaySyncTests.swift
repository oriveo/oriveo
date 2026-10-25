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

@Suite("ProviderManager Relay catalog sync", .serialized, .sharedProcessState)
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

    @Test("Catalog Refresh Write Gate Merges The Latest Names Without Re-marking The Default And Rejects Old Results After A Key Change")
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
        manager.applyRelaySyncResult(syncResult, to: &current)
        #expect(current.customName == "Renamed while loading")
        // A relay has no default model: after the catalog merge nothing is marked default, and the representative model is the first enabled one.
        #expect(current.catalogModels.allSatisfy { !$0.isDefault })
        // Write-side rule before persisting (refreshRelayCatalog persists through updateProvider): models keep no isDefault and no modelID.
        let persisted = ProviderManager.relayWriteNormalized(current)
        #expect(persisted.models.allSatisfy { !$0.isDefault })
        #expect(persisted.relayRequested?.modelID == nil)

        var rotatedKey = current
        rotatedKey.apiKey = "rotated-key"
        #expect(!RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: rotatedKey,
            connectionIdentity: identity
        ))

        // relayKind is a display value derived from the default protocol at save time and is never read for outbound
        // requests. An existing "fully custom + chosen protocol" connection has it rewritten to the protocol's kind the
        // first time only the headers are saved, and that must not void an in-flight catalog refresh.
        var changedKind = current
        changedKind.relayKind = .custom
        #expect(RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: changedKind,
            connectionIdentity: identity
        ))
        #expect(RelayCatalogConnectionIdentity(provider: changedKind).sameConnection(as: identity))
        #expect(RelayGenerationVerificationWritePolicy.mayCommit(current: changedKind, connectionIdentity: identity))

        // A field that really affects outbound requests (the protocol) still voids it.
        var changedTransport = current
        changedTransport.relayRequested?.transport = .openaiResponses
        #expect(!RelayCatalogRefreshWritePolicy.mayFinish(
            requestToken: token,
            activeToken: token,
            current: changedTransport,
            connectionIdentity: identity
        ))
    }

    // MARK: - RD2-REFRESH (the address-normalize.v1.json catalogCases fixture, through the production refresh path)

    private static var retainedStates: [AppState] = []

    private func runRefresh(_ caseId: String) async throws {
        ProviderManagerRelaySyncURLProtocol.reset()
        await MetadataClient.shared.resetForTesting()
        let (provider, catalogURL) = try RelayAddressNormalizeFixture.catalogProvider(caseId)
        let state = AppState(
            seedDemoData: false,
            sessionUID: "rd2-refresh-\(UUID().uuidString)",
            providerSession: makeProviderManagerRelaySyncSession()
        )
        Self.retainedStates.append(state)
        state.providers = [provider]

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id), "\(caseId)")
        let requested = ProviderManagerRelaySyncURLProtocol.capturedRequests().compactMap { $0.url?.absoluteString }
        #expect(requested == [catalogURL], "\(caseId)")
    }

    @Test("RD2-REFRESH-host_only_connection_refreshes_v1_models") func refreshHostOnly() async throws { try await runRefresh("host_only_connection_refreshes_v1_models") }
    @Test("RD2-REFRESH-verified_root_from_detection_wins") func refreshVerifiedRoot() async throws { try await runRefresh("verified_root_from_detection_wins") }
    @Test("RD2-REFRESH-versionless_verified_root_is_not_versioned_again") func refreshVersionless() async throws { try await runRefresh("versionless_verified_root_is_not_versioned_again") }
    @Test("RD2-REFRESH-per_transport_root_of_the_connection_transport_wins") func refreshPerTransport() async throws { try await runRefresh("per_transport_root_of_the_connection_transport_wins") }
    @Test("RD2-REFRESH-stored_chat_route_is_trimmed_before_models") func refreshStoredChatRoute() async throws { try await runRefresh("stored_chat_route_is_trimmed_before_models") }
    @Test("RD2-REFRESH-messages_connection_refreshes_its_v1_root") func refreshMessages() async throws { try await runRefresh("messages_connection_refreshes_its_v1_root") }
    @Test("RD2-REFRESH-gemini_connection_refreshes_its_v1beta_root") func refreshGemini() async throws { try await runRefresh("gemini_connection_refreshes_its_v1beta_root") }
    @Test("RD2-REFRESH-existing_v4_segment_is_not_versioned_again") func refreshExistingV4() async throws { try await runRefresh("existing_v4_segment_is_not_versioned_again") }

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
