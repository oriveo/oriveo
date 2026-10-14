import Foundation
import Testing
@testable import Oriveo

/// Catalog side of relay multi-key (RK-2): fetch and merge catalogs key by key, three catalog envelope shapes, replacing a key does not clear the catalog, only that key is refetched.
///
/// Fixture `shared/test-fixtures/relay/key-binding.v1.json` catalogCases / shellCases;
/// production refresh, key replacement and key operation entry points all hit a fake upstream, and the assertions cover request headers and written-back results.
@Suite("Relay multi-key · catalog and key replacement", .serialized)
@MainActor
struct RelayKeyCatalogContractTests {

    // MARK: - Fixtures

    private static func section(_ name: String) throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/key-binding.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let section = try #require(root[name] as? [String: Any])
                return try #require(section["cases"] as? [[String: Any]])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func caseItem(_ section: String, _ caseId: String) throws -> [String: Any] {
        try #require(try Self.section(section).first { $0["caseId"] as? String == caseId }, "fixture is missing \(section)/\(caseId)")
    }

    /// Baseline model JSON produced by the production encoder, overlaid with fixture fields, then fed through the production decoder.
    private static func model(_ raw: [String: Any]) throws -> AIModel {
        let id = try #require(raw["id"] as? String)
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(TestFactories.makeModel(id: id))) as? [String: Any]
        )
        for (key, value) in raw { json[key] = value }
        return try JSONDecoder().decode(AIModel.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - KEY-CATALOG (pure functions)

    private func runCatalog(_ caseId: String) throws {
        let item = try Self.caseItem("catalogCases", caseId)
        let keys = try #require(item["keys"] as? [String])
        let previous = try (item["previous"] as? [[String: Any]] ?? []).map(Self.model)
        let rawResults = try #require(item["results"] as? [String: Any])
        var results: [String: RelayKeyBinding.CatalogFetch] = [:]
        for (keyID, raw) in rawResults {
            if raw as? String == "skipped" {
                results[keyID] = .skipped
            } else if let object = raw as? [String: Any], let ok = object["ok"] as? [String] {
                results[keyID] = .ok(try ok.map { try Self.model(["id": $0]) })
            } else {
                let object = try #require(raw as? [String: Any])
                results[keyID] = .failed(status: object["status"] as? Int, body: object["body"] as? String ?? "")
            }
        }
        let merged = RelayKeyBinding.mergeCatalog(keyIDs: keys, previous: previous, results: results)
        let expect = try #require(item["expect"] as? [String: Any])
        let expectedCatalog = try #require(expect["catalog"] as? [[String: Any]])
        #expect(merged.catalog.map(\.id) == expectedCatalog.compactMap { $0["id"] as? String }, "\(caseId)")
        #expect(
            merged.catalog.map { $0.relayListedByKeyIDs ?? [] } == expectedCatalog.map { $0["relayListedByKeyIDs"] as? [String] ?? [] },
            "\(caseId)"
        )
        let expectedStates = try #require(expect["statuses"] as? [String: String])
        #expect(merged.states.mapValues(\.state.rawValue) == expectedStates, "\(caseId)")
    }

    @Test("KEY-CATALOG-union_in_key_order") func catalogUnion() throws { try runCatalog("union_in_key_order") }
    @Test("KEY-CATALOG-failed_key_keeps_previous_listing") func catalogFailed() throws { try runCatalog("failed_key_keeps_previous_listing") }
    @Test("KEY-CATALOG-all_failed_keeps_everything") func catalogAllFailed() throws { try runCatalog("all_failed_keeps_everything") }
    @Test("KEY-CATALOG-dropped_by_its_only_key_leaves") func catalogDropped() throws { try runCatalog("dropped_by_its_only_key_leaves") }
    @Test("KEY-CATALOG-skipped_key_keeps_listing_and_status") func catalogSkipped() throws { try runCatalog("skipped_key_keeps_listing_and_status") }
    @Test("KEY-CATALOG-status_mapping_403_quota_and_plain") func catalogStatusMapping() throws { try runCatalog("status_mapping_403_quota_and_plain") }

    // MARK: - KEY-SHELL (production refresh decoder)

    private func runShell(_ caseId: String) async throws {
        let item = try Self.caseItem("shellCases", caseId)
        let body = try #require(item["body"] as? String)
        let expected = try #require(item["expect"] as? [String])
        #expect(try OpenAIService.relayCatalogModelIDs(from: Data(body.utf8)) == expected, "\(caseId)")

        // The same raw text lands in the catalog through the production refresh.
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { request in
            request.url?.path == "/v1/models" ? .status(200, body) : .status(404, "")
        }
        let state = Self.makeState()
        let provider = Self.relayProvider(models: [], catalog: [])
        state.providers = [provider]
        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id), "\(caseId)")
        let catalog = try #require(state.provider(for: provider.id)?.catalogModels)
        #expect(Set(catalog.map(\.id)) == Set(expected), "\(caseId)")
        #expect(catalog.allSatisfy { $0.relayListedByKeyIDs == nil }, "\(caseId) a single key does not write listers")
    }

    @Test("KEY-SHELL-openai_list") func shellOpenAI() async throws { try await runShell("openai_list") }
    @Test("KEY-SHELL-new_api_success") func shellNewAPI() async throws { try await runShell("new_api_success") }
    @Test("KEY-SHELL-anthropic_page") func shellAnthropic() async throws { try await runShell("anthropic_page") }

    // MARK: - Production refresh / key replacement / key operations

    private static var retainedStates: [AppState] = []

    private static func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-key-catalog-\(UUID().uuidString)",
            providerSession: RelayKeyCatalogFakeServer.session()
        )
        retainedStates.append(state)
        return state
    }

    private static func relayProvider(models: [AIModel], catalog: [AIModel]) -> Provider {
        Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: catalog,
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            apiKey: "sk-primary",
            apiKeyPreview: "...mary",
            baseURLText: "https://relay.example.com/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer, securityMode: .remoteHTTPS)
        )
    }

    private static func catalogBody(_ ids: [String]) -> String {
        let items = ids.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
        return #"{"object":"list","data":[\#(items)]}"#
    }

    private static func modelsRequests() -> [URLRequest] {
        RelayKeyCatalogFakeServer.captured().filter { $0.url?.path == "/v1/models" }
    }

    @Test("KEY-CATALOG production refresh: each of the two keys fetches once with its own Authorization, the results merge per catalogCases and the statuses are written")
    func productionRefreshTwoKeys() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return .status(404, "") }
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer sk-primary": return .status(200, Self.catalogBody(["alpha-model", "shared-model"]))
            case "Bearer sk-claude": return .status(200, Self.catalogBody(["claude-model", "shared-model"]))
            default: return .status(401, #"{"error":"Invalid API key"}"#)
            }
        }
        let state = Self.makeState()
        let enabled = TestFactories.makeModel(id: "kept-enabled")
        var provider = Self.relayProvider(models: [enabled], catalog: [])
        provider.relayKeys = [RelayKey(id: "initial"), RelayKey(id: "k-claude", apiKey: "sk-claude")]
        state.providers = [provider]

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id))
        let requests = Self.modelsRequests()
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer sk-primary", "Bearer sk-claude"])
        let saved = try #require(state.provider(for: provider.id))
        let remote = saved.catalogModels.filter { $0.id != "kept-enabled" }
        // After merging, apply the same ordering as the single-key refresh (by name when there is no sortRank / created), so both paths produce the same order.
        #expect(remote.map(\.id) == ["alpha-model", "claude-model", "shared-model"])
        #expect(remote.map { $0.relayListedByKeyIDs ?? [] } == [["initial"], ["k-claude"], ["initial", "k-claude"]])
        #expect(saved.relayKeys?.map { $0.status?.state } == [.ok, .ok])
        #expect(saved.models.contains { $0.id == "kept-enabled" }, "enabled models are kept as they are")
        #expect(saved.lastCheckedAt == Date(timeIntervalSince1970: 1), "the catalog is not connection evidence")
    }

    @Test("RD2-REFRESH-host_only_connection_refreshes_v1_models both keys refresh one by one through the same catalogAPIRoot")
    func productionRefreshTwoKeysHostOnly() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { _ in .status(200, Self.catalogBody(["alpha-model"])) }
        let state = Self.makeState()
        var (provider, catalogURL) = try RelayAddressNormalizeFixture.catalogProvider("host_only_connection_refreshes_v1_models")
        provider.relayKeys = [RelayKey(id: "initial"), RelayKey(id: "k-second", apiKey: "sk-second")]
        state.providers = [provider]

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id))
        let requests = RelayKeyCatalogFakeServer.captured()
        #expect(requests.compactMap { $0.url?.absoluteString } == [catalogURL, catalogURL])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer sk-primary", "Bearer sk-second"])
    }

    @Test("KEY-CATALOG production refresh: when both keys fail the catalog stays put, each key status is written, and failure is returned with the single-key failure semantics")
    func productionRefreshAllFailedKeepsCatalog() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-primary"
                ? .status(401, #"{"error":"Invalid API key"}"#)
                : .status(429, "")
        }
        let state = Self.makeState()
        let catalog = [
            try Self.model(["id": "gpt-4o"]),
            try Self.model(["id": "claude-opus-4", "relayListedByKeyIDs": ["k-claude"]]),
        ]
        var provider = Self.relayProvider(models: [], catalog: catalog)
        provider.relayKeys = [RelayKey(id: "initial"), RelayKey(id: "k-claude", apiKey: "sk-claude")]
        state.providers = [provider]
        let before = try #require(state.provider(for: provider.id)?.catalogModels)

        #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id) == false)
        #expect(Self.modelsRequests().count == 2)
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.catalogModels == before, "catalog untouched")
        #expect(saved.relayKeys?.map { $0.status?.state } == [.invalid, .limited])
        #expect(saved.relayKeys?.map { $0.status?.httpStatus } == [401, 429])
        #expect(saved.lastError == ProviderIssueMessage.catalogUnavailableKey)
        #expect(saved.status == .connected, "a catalog failure does not change the connection status")
    }

    @Test("KEY-REPLACE-single_key_keeps_catalog")
    func replaceSingleKeyKeepsCatalog() async throws {
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { request in
            if request.url?.path == "/v1/chat/completions" {
                return .status(401, #"{"error":{"message":"bad relay key"}}"#)
            }
            return .status(200, Self.catalogBody(["should-not-load"]))
        }
        let state = Self.makeState()
        let enabled = TestFactories.makeModel(id: "still-sendable")
        let catalog = [TestFactories.makeModel(id: "still-sendable"), TestFactories.makeModel(id: "old-catalog")]
        let provider = Self.relayProvider(models: [enabled], catalog: catalog)
        state.providers = [provider]
        let before = try #require(state.provider(for: provider.id)?.catalogModels)

        await #expect(throws: (any Error).self) {
            try await state.updateAPIKey(providerID: provider.id, newKey: "sk-new-relay")
        }
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.apiKey == "sk-new-relay")
        #expect(saved.catalogModels == before, "replace key only: the catalog is unchanged when verification fails")
        #expect(saved.status != .connected)
        #expect(saved.lastCheckedAt == nil)
        // Re-verification returning 401 = this key is invalid: even a single key writes the primary key status, materializing one list entry (this overrides the earlier rule that a single key writes nothing).
        #expect(saved.relayKeys?.map(\.id) == ["initial"])
        #expect(saved.relayKeys?.first?.apiKey == "")
        #expect(saved.relayKeys?.first?.status?.state == .invalid)
        #expect(saved.relayKeys?.first?.status?.httpStatus == 401)
        #expect(Self.modelsRequests().isEmpty, "a failed verification does not fetch the catalog")
    }

    @Test("KEY-REPLACE-multi_refetches_only_that_key")
    func replaceMultiRefetchesOnlyThatKey() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { request in
            guard request.url?.path == "/v1/models" else { return .status(404, "") }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-b2"
                ? .status(200, Self.catalogBody(["claude-opus-4", "claude-sonnet-4-5"]))
                : .status(500, "unexpected")
        }
        let state = Self.makeState()
        var claude = try Self.model(["id": "claude-opus-4", "relayKeyID": "k-b", "relayDeniedKeyID": "k-b"])
        claude.isDefault = false
        let catalog = [
            try Self.model(["id": "gpt-4o", "relayListedByKeyIDs": ["initial"]]),
            try Self.model(["id": "claude-opus-4", "relayListedByKeyIDs": ["k-b"]]),
        ]
        var provider = Self.relayProvider(models: [claude], catalog: catalog)
        let primaryStatus = RelayKey.Status(state: .limited, httpStatus: 429, checkedAt: Date(timeIntervalSince1970: 5))
        provider.relayKeys = [
            RelayKey(id: "initial", status: primaryStatus),
            RelayKey(id: "k-b", apiKey: "sk-b", status: RelayKey.Status(state: .invalid, httpStatus: 401, checkedAt: nil)),
        ]
        state.providers = [provider]

        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, .replaceSecret(id: "k-b", apiKey: "sk-b2")
        ))
        let requests = Self.modelsRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-b2")
        let saved = try #require(state.provider(for: provider.id))
        #expect(saved.apiKey == "sk-primary")
        #expect(saved.relayKeys?[0].status == primaryStatus, "the other keys' statuses are untouched")
        #expect(saved.relayKeys?[1].status?.state == .ok)
        #expect(ProviderCredentialResolver.secret(provider: saved, keyID: "k-b") == "sk-b2")
        let remote = saved.catalogModels
        #expect(remote.first { $0.id == "gpt-4o" }?.relayListedByKeyIDs == ["initial"], "the other keys' entries are untouched")
        #expect(remote.first { $0.id == "claude-sonnet-4-5" }?.relayListedByKeyIDs == ["k-b"])
        #expect(remote.first { $0.id == "claude-opus-4" }?.relayListedByKeyIDs == ["k-b"])
        #expect(saved.models.first { $0.id == "claude-opus-4" }?.relayDeniedKeyID == nil, "replacing the value clears the denied-access marker")
    }

    @Test("KEY-OPS production entry point: after rebind, a model without a protocol is lazily verified when enabled, sending a 1-token request with the newly bound key")
    func rebindLazilyVerifiesWithNewKey() async throws {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        RelayKeyCatalogFakeServer.install { _ in .status(404, "") }
        let state = Self.makeState()
        var model = try Self.model(["id": "gpt-4o", "relayKeyID": "initial"])
        model.isDefault = false
        var provider = Self.relayProvider(models: [model], catalog: [])
        // Lazy verification only happens when the connection protocol is auto; models on a user-chosen connection protocol follow the connection and are not probed.
        provider.relayRequested?.transport = .auto
        provider.relayKeys = [RelayKey(id: "initial"), RelayKey(id: "k-b", apiKey: "sk-b")]
        state.providers = [provider]

        #expect(await state.providerManager.applyRelayKeyOperation(
            providerID: provider.id, .rebind(modelID: "gpt-4o", keyID: "k-b")
        ))
        await state.providerManager.waitForRelayModelProbeForTesting(providerID: provider.id)
        #expect(state.provider(for: provider.id)?.models.first?.relayKeyID == "k-b")
        let pings = RelayKeyCatalogFakeServer.captured().filter { $0.httpMethod == "POST" }
        #expect(!pings.isEmpty)
        #expect(pings.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-b" })
        #expect(Self.modelsRequests().isEmpty, "rebinding does not fetch the catalog")
    }

    @Test("KEY fixture catalogCases / shellCases: every caseId has a test of the same name")
    func fixtureCasesCovered() throws {
        #expect(Set(try Self.section("catalogCases").compactMap { $0["caseId"] as? String }) == [
            "union_in_key_order", "failed_key_keeps_previous_listing", "all_failed_keeps_everything",
            "dropped_by_its_only_key_leaves", "skipped_key_keeps_listing_and_status", "status_mapping_403_quota_and_plain",
        ])
        #expect(Set(try Self.section("shellCases").compactMap { $0["caseId"] as? String }) == [
            "openai_list", "new_api_success", "anthropic_page",
        ])
    }
}

/// Fake upstream: answers per request and records all requests.
private final class RelayKeyCatalogFakeServer: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ value: @escaping (URLRequest) -> Reply) {
        lock.withLock {
            handler = value
            requests = []
        }
    }

    static func captured() -> [URLRequest] {
        lock.withLock { requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayKeyCatalogFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request) ?? .status(404, "")
        }
        guard case let .status(code, body) = reply else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
