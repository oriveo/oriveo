import Foundation
import Testing
@testable import Oriveo

/// Relay key status reflects real requests (three platforms share the case names RL2-KEYSTATUS-NN).
///
/// Production entry points (re-verify / lazy verify / capability test / catalog refresh / key operations / replacing the primary key) hit a fake upstream, and the assertions cover the written-back `relayKeys`:
/// the status is written on the key the request actually used; generation requests only write success / invalid / restricted; the first write on a single key materializes one list entry; drafts and results whose identity has changed are not written.
@Suite("Relay 2.0 · key status write-back", .serialized)
@MainActor
struct RelayKeyStatusWritebackTests {

    // MARK: - Construction

    private static var retainedStates: [AppState] = []

    private static let chatOK = #"{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"length"}]}"#
    private static let invalidKey = #"{"error":{"message":"Invalid API key"}}"#

    private static func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-key-status-\(UUID().uuidString)",
            providerSession: RelayKeyStatusFakeServer.session()
        )
        retainedStates.append(state)
        return state
    }

    private static func model(_ id: String, keyID: String? = nil, listedBy: [String]? = nil) -> AIModel {
        var model = TestFactories.makeModel(id: id, capabilities: [.text])
        model.isDefault = false
        model.relayKeyID = keyID
        model.relayListedByKeyIDs = listedBy
        return model
    }

    private static func relayProvider(
        models: [AIModel],
        catalog: [AIModel],
        keys: [RelayKey]? = nil,
        transport: RelayTransport = .openaiChatCompletions
    ) -> Provider {
        var provider = Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: catalog,
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            apiKey: "sk-primary",
            apiKeyPreview: "...mary",
            baseURLText: "https://relay.example.com/v1",
            relayRequested: RelayRequestedConfig(transport: transport, authMode: .bearer, securityMode: .remoteHTTPS)
        )
        provider.relayKeys = keys
        return provider
    }

    private static func catalogBody(_ ids: [String]) -> String {
        let items = ids.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
        return #"{"object":"list","data":[\#(items)]}"#
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    private static func isGeneration(_ request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    private static func isCatalog(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET" && request.url?.path == "/v1/models"
    }

    private static func withInMemoryKeys(_ body: () async throws -> Void) async rethrows {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await body()
    }

    // MARK: - 01-02 re-verify

    @Test("RL2-KEYSTATUS-01 a successful re-verify on a single key -> the primary key is ok (one list entry is materialized)")
    func keyStatus01SingleReverifyOK() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (200, Self.chatOK) : (404, "")
            }
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]

            try await state.providerManager.reverifyRelayProvider(providerID: provider.id)

            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.status == .connected)
            #expect(saved.relayKeys?.map(\.id) == ["initial"])
            #expect(saved.relayKeys?.first?.apiKey == "")
            #expect(saved.relayKeys?.first?.status?.state == .ok)
            #expect(saved.apiKey == "sk-primary")
            #expect(saved.models.allSatisfy { $0.relayKeyID == nil }, "model key fields are not written")
        }
    }

    @Test("RL2-KEYSTATUS-02 a 401 on re-verify with several keys -> the sample model's effective key becomes invalid and the primary key is untouched")
    func keyStatus02MultiReverifyInvalidOnSampleKey() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                guard Self.isGeneration(request) else { return (404, "") }
                return Self.bearer(request) == "Bearer sk-b" ? (401, Self.invalidKey) : (200, Self.chatOK)
            }
            let state = Self.makeState()
            let claude = Self.model("claude-opus-4", keyID: "k-b")
            let provider = Self.relayProvider(
                models: [claude],
                catalog: [Self.model("claude-opus-4", listedBy: ["k-b"])],
                keys: [RelayKey(id: "initial"), RelayKey(id: "k-b", apiKey: "sk-b")]
            )
            state.providers = [provider]
            #expect(state.providerManager.relayVerificationSampleModelID(for: provider) == "claude-opus-4", "precondition: the sample is bound to the second key")

            await #expect(throws: (any Error).self) {
                try await state.providerManager.reverifyRelayProvider(providerID: provider.id)
            }
            let requests = RelayKeyStatusFakeServer.captured().filter(Self.isGeneration)
            #expect(requests.map(Self.bearer) == ["Bearer sk-b"])
            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.relayKeys?[1].status?.state == .invalid)
            #expect(saved.relayKeys?[1].status?.httpStatus == 401)
            #expect(saved.relayKeys?[0].status == nil)
        }
    }

    // MARK: - 03-04 lazy verify

    @Test("RL2-KEYSTATUS-03 lazy verify passes -> the bound key is ok and the other keys are untouched")
    func keyStatus03LazyProbeOK() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                guard Self.isGeneration(request) else { return (404, "") }
                return Self.bearer(request) == "Bearer sk-b" ? (200, Self.chatOK) : (500, "unexpected")
            }
            let state = Self.makeState()
            let provider = Self.relayProvider(
                models: [Self.model("claude-opus-4", keyID: "k-b")],
                catalog: [Self.model("claude-opus-4", listedBy: ["k-b"])],
                keys: [RelayKey(id: "initial"), RelayKey(id: "k-b", apiKey: "sk-b")],
                transport: .auto
            )
            state.providers = [provider]

            await state.providerManager.probeRelayModelTransport(providerID: provider.id, modelID: "claude-opus-4")

            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.models.first?.relayTransport != nil, "precondition: lazy verify passed and wrote back the protocol")
            #expect(saved.relayKeys?[1].status?.state == .ok)
            #expect(saved.relayKeys?[0].status == nil)

            // A single probe after manually choosing the protocol also writes (the key answering 401 -> invalid).
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (401, Self.invalidKey) : (404, "")
            }
            let passed = await state.providerManager.probeRelayModelTransportOnce(
                providerID: provider.id, modelID: "claude-opus-4", transport: .openaiChatCompletions
            )
            #expect(passed == false)
            let afterOnce = try #require(state.provider(for: provider.id))
            #expect(afterOnce.relayKeys?[1].status?.state == .invalid)
            #expect(afterOnce.relayKeys?[1].status?.httpStatus == 401)
            #expect(afterOnce.relayKeys?[0].status == nil)
        }
    }

    @Test("RL2-KEYSTATUS-04 lazy verify route 404 -> key status unchanged (a single key does not materialize a list)")
    func keyStatus04LazyProbeRoute404LeavesKey() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { _ in (404, "404 page not found") }
            let state = Self.makeState()
            let provider = Self.relayProvider(
                models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")], transport: .auto
            )
            state.providers = [provider]

            await state.providerManager.probeRelayModelTransport(providerID: provider.id, modelID: "gpt-4o")

            #expect(!RelayKeyStatusFakeServer.captured().filter(Self.isGeneration).isEmpty, "precondition: the lazy-verify request was actually sent")
            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.models.first?.relayTransport == nil)
            #expect(saved.relayKeys == nil)
        }
    }

    // MARK: - 05 capability test

    @Test("RL2-KEYSTATUS-05 capability test 200 -> that key is ok; then an item returning 401 -> invalid")
    func keyStatus05CapabilityTestWrites() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            let ok = RelayCapabilityTest.Response(
                status: 200, contentType: "text/event-stream",
                body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
            let observed = KeyStatusBox<[RelayKey.Status.State?]>([])
            let result = await state.providerManager.runRelayCapabilityTest(providerID: provider.id, modelID: "gpt-4o") { kind, _ in
                observed.value.append(state.provider(for: provider.id)?.relayKeys?.first?.status?.state)
                return kind == .text
                    ? ok
                    : RelayCapabilityTest.Response(status: 401, contentType: "application/json", body: Data(Self.invalidKey.utf8))
            }
            #expect(result != nil)
            #expect(observed.value.count >= 2, "precondition: at least one more item after text")
            let afterText: RelayKey.Status.State? = observed.value.count >= 2 ? observed.value[1] : nil
            #expect(afterText == .ok, "text 200 writes ok")
            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.relayKeys?.map(\.id) == ["initial"])
            #expect(saved.relayKeys?.first?.status?.state == .invalid)
            #expect(saved.relayKeys?.first?.status?.httpStatus == 401)
        }
    }

    // MARK: - 06-07 key operations

    @Test("RL2-KEYSTATUS-06 add -> all keys refetch, and the primary key gets status and listers")
    func keyStatus06AddRefetchesAll() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                guard Self.isCatalog(request) else { return (404, "") }
                switch Self.bearer(request) {
                case "Bearer sk-primary": return (200, Self.catalogBody(["gpt-4o", "gpt-4.1"]))
                case "Bearer sk-b": return (200, Self.catalogBody(["claude-opus-4"]))
                default: return (401, Self.invalidKey)
                }
            }
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]

            #expect(await state.providerManager.applyRelayKeyOperation(
                providerID: provider.id, .add(id: "k-b", name: nil, apiKey: "sk-b")
            ))
            #expect(RelayKeyStatusFakeServer.captured().filter(Self.isCatalog).map(Self.bearer) == ["Bearer sk-primary", "Bearer sk-b"])
            let saved = try #require(state.provider(for: provider.id))
            #expect(saved.relayKeys?.map { $0.status?.state } == [.ok, .ok])
            #expect(saved.catalogModels.first { $0.id == "gpt-4.1" }?.relayListedByKeyIDs == ["initial"])
            #expect(saved.catalogModels.first { $0.id == "claude-opus-4" }?.relayListedByKeyIDs == ["k-b"])
        }
    }

    @Test("RL2-KEYSTATUS-07 replacing the value of a single primary key -> that key's status is cleared first; the new status is written after verification and fetching succeed")
    func keyStatus07ReplacePrimaryClearsThenWrites() async throws {
        try await Self.withInMemoryKeys {
            // First replacement: verification returns 503 (says nothing about the key) -> nothing written, leaving only "cleared".
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (503, "busy") : (200, Self.catalogBody(["gpt-4o"]))
            }
            let state = Self.makeState()
            let invalid = RelayKey.Status(state: .invalid, httpStatus: 401, checkedAt: Date(timeIntervalSince1970: 5))
            let provider = Self.relayProvider(
                models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")],
                keys: [RelayKey(id: "initial", status: invalid)]
            )
            state.providers = [provider]

            await #expect(throws: (any Error).self) {
                try await state.updateAPIKey(providerID: provider.id, newKey: "sk-new-1")
            }
            var saved = try #require(state.provider(for: provider.id))
            #expect(saved.apiKey == "sk-new-1")
            #expect(saved.relayKeys?.map(\.id) == ["initial"])
            #expect(saved.relayKeys?.first?.status == nil, "the old status is cleared first after the value is replaced")

            // Second replacement: verification 200 and catalog 200 -> the new status is ok.
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (200, Self.chatOK) : (200, Self.catalogBody(["gpt-4o", "gpt-4.1"]))
            }
            try await state.updateAPIKey(providerID: provider.id, newKey: "sk-new-2")
            saved = try #require(state.provider(for: provider.id))
            #expect(RelayKeyStatusFakeServer.captured().contains(where: Self.isCatalog), "precondition: the catalog was fetched")
            #expect(saved.relayKeys?.first?.status?.state == .ok)
            #expect(saved.status == .connected)
        }
    }

    // MARK: - 08 draft

    @Test("RL2-KEYSTATUS-08 'Test connection' on an unsaved draft (production verifyRelayGeneration) -> nothing is written on success or failure")
    func keyStatus08DraftTestWritesNothing() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            var draft = provider
            draft.relayRequested?.headers = [RelayKeyValue(key: "X-Draft", value: "1")]

            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (200, Self.chatOK) : (404, "") }
            try await state.providerManager.verifyRelayGeneration(draft)
            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (401, Self.invalidKey) : (404, "") }
            await #expect(throws: (any Error).self) {
                try await state.providerManager.verifyRelayGeneration(draft)
            }
            #expect(RelayKeyStatusFakeServer.captured().filter(Self.isGeneration).count == 1)
            #expect(state.provider(for: provider.id)?.relayKeys == nil)
        }
    }

    // MARK: - 09 single-key catalog refresh

    @Test("RL2-KEYSTATUS-09 every single-key catalog refresh path writes (catalogCases mapping): success ok, 403 denied, 429 restricted, onlyKeyID writes the same")
    func keyStatus09SingleKeyCatalogPathsWrite() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            @MainActor func status() -> RelayKey.Status? { state.provider(for: provider.id)?.relayKeys?.first?.status }

            RelayKeyStatusFakeServer.install { _ in (200, Self.catalogBody(["gpt-4o"])) }
            #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id))
            #expect(status()?.state == .ok)

            RelayKeyStatusFakeServer.install { _ in (403, "Forbidden") }
            #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id) == false)
            #expect(status()?.state == .denied)
            #expect(status()?.httpStatus == 403)

            RelayKeyStatusFakeServer.install { _ in (429, "") }
            #expect(await state.providerManager.refreshRelayCatalog(providerID: provider.id, onlyKeyID: "initial") == false)
            #expect(status()?.state == .limited)
            #expect(status()?.httpStatus == 429)

            RelayKeyStatusFakeServer.install { _ in (200, Self.catalogBody(["gpt-4o"])) }
            try await state.providerManager.reverifyRelayProvider(providerID: provider.id, refreshCatalog: true)
            #expect(status()?.state == .ok)
            #expect(state.provider(for: provider.id)?.relayKeys?.count == 1)
        }
    }

    // MARK: - 12 identity changed

    @Test("RL2-KEYSTATUS-12 the connection identity changed during the request -> nothing written (address changed in the capability test, key value replaced during lazy verify)")
    func keyStatus12IdentityChangedDropsWrite() async throws {
        try await Self.withInMemoryKeys {
            // Capability test: the address changes while the text request is in flight, and the 401 that comes back is not written.
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            _ = await state.providerManager.runRelayCapabilityTest(providerID: provider.id, modelID: "gpt-4o") { _, _ in
                if var current = state.provider(for: provider.id) {
                    current.baseURLText = "https://other-relay.example.com/v1"
                    state.providerManager.updateProvider(current)
                }
                return RelayCapabilityTest.Response(status: 401, contentType: "application/json", body: Data(Self.invalidKey.utf8))
            }
            #expect(state.provider(for: provider.id)?.relayKeys == nil)

            // Lazy verify: the primary key value is replaced while in flight, and the 401 for the old value is not written.
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (401, Self.invalidKey) : (404, "")
            }
            let probeState = Self.makeState()
            let auto = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")], transport: .auto)
            probeState.providers = [auto]
            let probe = Task { await probeState.providerManager.probeRelayModelTransport(providerID: auto.id, modelID: "gpt-4o") }
            var spins = 0
            while probeState.relayModelProbeStates[auto.id]?["gpt-4o"] != .inFlight, spins < 10_000 {
                await Task.yield()
                spins += 1
            }
            #expect(probeState.relayModelProbeStates[auto.id]?["gpt-4o"] == .inFlight, "precondition: lazy verify in flight")
            if var current = probeState.provider(for: auto.id) {
                current.apiKey = "sk-replaced"
                current.apiKeyPreview = APIKeyMask.masked("sk-replaced")
                probeState.providerManager.updateProvider(current)
            }
            await probe.value
            await probeState.providerManager.waitForRelayModelProbeForTesting(providerID: auto.id)
            #expect(probeState.provider(for: auto.id)?.relayKeys?.first?.status?.state != .invalid)
        }
    }

    // MARK: - 13-18 (follow-up cases from per-platform reports)

    @Test("RL2-KEYSTATUS-13 after a single primary key is replaced, the fail-closed verification returning 401 -> the primary key is invalid (one list entry is materialized) and the catalog is not fetched")
    func keyStatus13ReplacePrimaryFailClosedWrites() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (401, Self.invalidKey) : (200, Self.catalogBody(["gpt-4o"]))
            }
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]

            await #expect(throws: (any Error).self) {
                try await state.updateAPIKey(providerID: provider.id, newKey: "sk-new")
            }
            let saved = try #require(state.provider(for: provider.id))
            #expect(RelayKeyStatusFakeServer.captured().filter(Self.isGeneration).map(Self.bearer) == ["Bearer sk-new"])
            #expect(!RelayKeyStatusFakeServer.captured().contains(where: Self.isCatalog))
            #expect(saved.relayKeys?.map(\.id) == ["initial"])
            #expect(saved.relayKeys?.first?.status?.state == .invalid)
            #expect(saved.relayKeys?.first?.status?.httpStatus == 401)
        }
    }

    @Test("RL2-KEYSTATUS-14 unverified save: the path that replaced the primary key value (single-key replacement) clears the status first; 'Save anyway' on the edit page does not change the primary key value and the status follows the live value")
    func keyStatus14UnverifiedSaveClearsReplacedPrimary() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                Self.isGeneration(request) ? (503, "busy") : (404, "")
            }
            let state = Self.makeState()
            let invalid = RelayKey.Status(state: .invalid, httpStatus: 401, checkedAt: Date(timeIntervalSince1970: 5))
            let provider = Self.relayProvider(
                models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")],
                keys: [RelayKey(id: "initial", status: invalid)]
            )
            state.providers = [provider]

            await #expect(throws: (any Error).self) {
                try await state.updateAPIKey(providerID: provider.id, newKey: "sk-new")
            }
            var live = try #require(state.provider(for: provider.id))
            #expect(live.status != .connected, "precondition: saved unverified")
            #expect(live.relayKeys?.first?.status == nil, "replacing the value clears it")

            // "Save anyway (unverified)" on the edit page: this page does not change the key, so after merging both the primary key value and status take the live values.
            let ok = RelayKey.Status(state: .ok, httpStatus: nil, checkedAt: Date())
            live.relayKeys = [RelayKey(id: "initial", status: ok)]
            state.providerManager.updateProvider(live)
            let baseline = RelayEditView.Editor(from: live)
            var draft = baseline
            draft.endpoint = "https://relay.example.com/v2"
            let normalized = try #require(RelayEditSavePolicy.normalizedEndpoint(draft.endpoint, securityMode: draft.securityMode))
            let commit = RelayEditSaveCommit.unverified(
                draft: RelayEditSavePolicy.normalizedDraft(draft, normalizedEndpoint: normalized),
                baseline: baseline, normalizedEndpoint: normalized, onto: live
            )
            #expect(commit.provider.apiKey == "sk-new")
            #expect(commit.provider.relayKeys?.first?.status == ok)
        }
    }

    @Test("RL2-KEYSTATUS-15 a request without a key (auth=none / empty key) -> nothing written and nothing materialized: relayKeys stays nil after the catalog fetch succeeds")
    func keyStatus15NoCredentialWritesNothing() async throws {
        try await Self.withInMemoryKeys {
            RelayKeyStatusFakeServer.install { request in
                Self.isCatalog(request) ? (200, Self.catalogBody(["gpt-4o"])) : (404, "")
            }
            let state = Self.makeState()
            var keyless = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            keyless.relayRequested?.authMode = RelayAuthMode.none
            keyless.apiKey = ""
            keyless.apiKeyPreview = APIKeyMask.masked("")
            state.providers = [keyless]
            #expect(await state.providerManager.refreshRelayCatalog(providerID: keyless.id))
            #expect(state.provider(for: keyless.id)?.relayKeys == nil)

            // Auth is required but the key is empty: even a 401 says nothing about "this" key.
            RelayKeyStatusFakeServer.install { _ in (401, Self.invalidKey) }
            var empty = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            empty.apiKey = ""
            empty.apiKeyPreview = APIKeyMask.masked("")
            state.providers = [empty]
            #expect(await state.providerManager.refreshRelayCatalog(providerID: empty.id) == false)
            #expect(state.provider(for: empty.id)?.relayKeys == nil)
        }
    }

    @Test("RL2-KEYSTATUS-16 edit save: when verification passes and the connection is saved, the key actually sent is written ok; when verification fails and nothing is saved, nothing is written; tapping 'Save anyway' writes invalid on save")
    func keyStatus16EditSaveWritesOnPersist() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            let baseline = RelayEditView.Editor(from: provider)
            var draft = baseline
            draft.endpoint = "https://relay.example.com/v2"
            let normalized = try #require(RelayEditSavePolicy.normalizedEndpoint(draft.endpoint, securityMode: draft.securityMode))
            let normalizedDraft = RelayEditSavePolicy.normalizedDraft(draft, normalizedEndpoint: normalized)
            let observed = KeyStatusBox<RelayKeyStatusObservation?>(nil)
            @MainActor func save() async -> RelayEditSaveCommit.Outcome {
                await RelayEditSaveCommit.run(
                    draft: normalizedDraft, baseline: baseline, normalizedEndpoint: normalized,
                    live: { state.provider(for: provider.id) },
                    verify: { candidate in try await state.providerManager.verifyRelayGeneration(candidate) { observed.value = $0 } },
                    isCurrent: { true },
                    persist: { state.providerManager.updateProvider($0) },
                    applyKeyStatus: { ProviderManager.applyRelayKeyStatusObservation(observed.value, to: &$0) }
                )
            }

            // Failure: nothing is written while the failure card is showing.
            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (401, Self.invalidKey) : (404, "") }
            guard case .verificationFailed = await save() else {
                Issue.record("verification should fail")
                return
            }
            #expect(state.provider(for: provider.id)?.relayKeys == nil, "nothing is written when not saved")
            #expect(observed.value?.keyID == "initial")
            #expect(observed.value?.state == .invalid)
            // Tapping "Save anyway (unverified)": written at the moment of saving.
            let live = try #require(state.provider(for: provider.id))
            var unverified = RelayEditSaveCommit.unverified(
                draft: normalizedDraft, baseline: baseline, normalizedEndpoint: normalized, onto: live
            ).provider
            #expect(ProviderManager.applyRelayKeyStatusObservation(observed.value, to: &unverified))
            state.providerManager.updateProvider(unverified)
            #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.state == .invalid)
            #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.httpStatus == 401)

            // Pass: ok is written on save.
            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (200, Self.chatOK) : (404, "") }
            var again = normalizedDraft
            again.endpoint = "https://relay.example.com/v3"
            let normalizedAgain = try #require(RelayEditSavePolicy.normalizedEndpoint(again.endpoint, securityMode: again.securityMode))
            let outcome = await RelayEditSaveCommit.run(
                draft: RelayEditSavePolicy.normalizedDraft(again, normalizedEndpoint: normalizedAgain),
                baseline: normalizedDraft, normalizedEndpoint: normalizedAgain,
                live: { state.provider(for: provider.id) },
                verify: { candidate in try await state.providerManager.verifyRelayGeneration(candidate) { observed.value = $0 } },
                isCurrent: { true },
                persist: { state.providerManager.updateProvider($0) },
                applyKeyStatus: { ProviderManager.applyRelayKeyStatusObservation(observed.value, to: &$0) }
            )
            guard case .persisted = outcome else {
                Issue.record("should have been saved")
                return
            }
            #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.state == .ok)
        }
    }

    @Test("RL2-KEYSTATUS-17 'Test connection' on the edit page: the result is written when it is persisted (draft equals saved), otherwise not")
    func keyStatus17TestConnectionWritesWhenPersisted() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [provider]
            var draft = provider
            draft.baseURLText = "https://relay.example.com/v2"

            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (200, Self.chatOK) : (404, "") }
            try await state.providerManager.verifyRelayGenerationRecordingKeyStatus(draft, providerID: provider.id, persists: false)
            #expect(state.provider(for: provider.id)?.relayKeys == nil, "draft differs from saved: nothing written")

            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (401, Self.invalidKey) : (404, "") }
            await #expect(throws: (any Error).self) {
                try await state.providerManager.verifyRelayGenerationRecordingKeyStatus(provider, providerID: provider.id, persists: true)
            }
            #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.state == .invalid)

            RelayKeyStatusFakeServer.install { request in Self.isGeneration(request) ? (200, Self.chatOK) : (404, "") }
            try await state.providerManager.verifyRelayGenerationRecordingKeyStatus(provider, providerID: provider.id, persists: true)
            #expect(state.provider(for: provider.id)?.relayKeys?.first?.status?.state == .ok)
        }
    }

    @Test("RL2-KEYSTATUS-18 2xx but the body is a web page / has no parsable content -> treated as failure, ok is not written (lazy verify / re-verify / capability test)")
    func keyStatus18WebPage2xxIsNotSuccess() async throws {
        try await Self.withInMemoryKeys {
            let page = "<!doctype html><html><body>console</body></html>"
            RelayKeyStatusFakeServer.install { _ in (200, page) }
            let state = Self.makeState()
            let auto = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")], transport: .auto)
            state.providers = [auto]
            await state.providerManager.probeRelayModelTransport(providerID: auto.id, modelID: "gpt-4o")
            #expect(!RelayKeyStatusFakeServer.captured().filter(Self.isGeneration).isEmpty, "precondition: the lazy-verify request was actually sent")
            #expect(state.provider(for: auto.id)?.models.first?.relayTransport == nil, "precondition: a web page does not count as passing")
            #expect(state.provider(for: auto.id)?.relayKeys == nil)

            let chat = Self.relayProvider(models: [Self.model("gpt-4o")], catalog: [Self.model("gpt-4o")])
            state.providers = [chat]
            await #expect(throws: (any Error).self) {
                try await state.providerManager.reverifyRelayProvider(providerID: chat.id)
            }
            #expect(state.provider(for: chat.id)?.relayKeys == nil)

            _ = await state.providerManager.runRelayCapabilityTest(providerID: chat.id, modelID: "gpt-4o") { _, _ in
                RelayCapabilityTest.Response(status: 200, contentType: "text/html", body: Data(page.utf8))
            }
            #expect(state.provider(for: chat.id)?.relayKeys == nil)
        }
    }

    @Test("RL2-KEYSTATUS-19 when the value of a key is replaced while a chat send is in flight, neither the success nor the 401 for the old value writes a status, and the denied-access marker is untouched")
    func keyStatus19SendIdentityChangedDropsWrite() async throws {
        try await Self.withInMemoryKeys {
            let state = Self.makeState()
            let provider = Self.relayProvider(
                models: [Self.model("gpt-4o"), Self.model("claude-opus-4", keyID: "k-b")],
                catalog: [Self.model("gpt-4o"), Self.model("claude-opus-4", listedBy: ["k-b"])],
                keys: [RelayKey(id: "initial"), RelayKey(id: "k-b", apiKey: "sk-b")]
            )
            state.providers = [provider]
            let manager = state.providerManager
            // Identity recorded when the send started (the same function as the ChatManager send entry).
            let primarySent = ProviderManager.relayKeyWriteIdentity(provider, modelID: "gpt-4o")
            let boundSent = ProviderManager.relayKeyWriteIdentity(provider, modelID: "claude-opus-4")

            // In flight: the primary key and k-b both get new values (replaceSecret clears the status).
            var replaced = try #require(RelayKeyBinding.apply(.replaceSecret(id: "initial", apiKey: "sk-primary-2"), to: provider))
            replaced = try #require(RelayKeyBinding.apply(.replaceSecret(id: "k-b", apiKey: "sk-b2"), to: replaced))
            manager.updateProvider(replaced)
            manager.recordRelayKeyAccessSuccess(providerID: provider.id, modelID: "gpt-4o", keyID: "initial", sentIdentity: primarySent)
            manager.recordRelayKeyAccessFailure(
                providerID: provider.id, modelID: "claude-opus-4", keyID: "k-b",
                outcome: .keyInvalid, httpStatus: 401, sentIdentity: boundSent
            )
            manager.recordRelayKeyAccessFailure(
                providerID: provider.id, modelID: "claude-opus-4", keyID: "k-b",
                outcome: .modelAccessDenied, httpStatus: 404, sentIdentity: boundSent
            )
            var saved = try #require(state.provider(for: provider.id))
            #expect(saved.relayKeys?.map { $0.status } == [nil, nil], "results for the old value are not recorded against the new value")
            #expect(saved.models.first { $0.id == "claude-opus-4" }?.relayDeniedKeyID == nil)

            // Identity unchanged: written as usual.
            let current = try #require(state.provider(for: provider.id))
            manager.recordRelayKeyAccessFailure(
                providerID: provider.id, modelID: "claude-opus-4", keyID: "k-b",
                outcome: .keyInvalid, httpStatus: 401,
                sentIdentity: ProviderManager.relayKeyWriteIdentity(current, modelID: "claude-opus-4")
            )
            saved = try #require(state.provider(for: provider.id))
            #expect(saved.relayKeys?[1].status?.state == .invalid)
        }
    }
}

private final class KeyStatusBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Fake upstream: answers per request (status code, body) and records all requests.
private final class RelayKeyStatusFakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(_ value: @escaping (URLRequest) -> (Int, String)) {
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
        configuration.protocolClasses = [RelayKeyStatusFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, body) = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request) ?? (404, "")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": body.hasPrefix("<") ? "text/html" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
