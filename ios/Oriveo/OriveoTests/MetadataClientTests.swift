import Foundation
import os
import Testing
@testable import Oriveo

/// Collects the thread each snapshot release happens on, for the off-main-thread regression assertions.
private final class SnapshotReleaseThreadRecorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[Bool]>(initialState: [])

    func record(isMainThread: Bool) {
        storage.withLock { $0.append(isMainThread) }
    }

    var flags: [Bool] { storage.withLock { $0 } }
}

private final class MetadataClientMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var stub = Stub(statusCode: 304, headers: [:], data: Data())
    private static var capturedETags: [String?] = []
    private static var capturedURLs: [URL] = []

    static func configure(_ value: Stub) {
        lock.lock()
        stub = value
        capturedETags = []
        capturedURLs = []
        lock.unlock()
    }

    static func etags() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return capturedETags
    }

    static func urls() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return capturedURLs
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataClientMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responseStub = Self.stub
        Self.capturedETags.append(request.value(forHTTPHeaderField: "If-None-Match"))
        if let url = request.url { Self.capturedURLs.append(url) }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responseStub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseStub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !responseStub.data.isEmpty {
            client?.urlProtocol(self, didLoad: responseStub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private final class MetadataDecodeErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(message: String, tags: [String: String])] = []

    func record(error: Error, tags: [String: String]) {
        lock.lock()
        events.append((error.localizedDescription, tags))
        lock.unlock()
    }

    func snapshot() -> [(message: String, tags: [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private func metadataLeanFixture() throws -> [String: Any] {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent(
            "shared/model-contracts/metadata_lean_contract.v1.json"
        )
        if FileManager.default.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        folder.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

@Suite("MetadataClient metadata matching", .serialized, .sharedProcessState)
struct MetadataClientTests {

    @Test("A network metadata decode failure is reported through the sanitized error reporter")
    func networkDecodeFailureIsReported() async {
        let malformed = Data(#"{"code":0,"data":{"version":1,"providers":{"openAI":{"models":null}}}}"#.utf8)
        MetadataClientMockURLProtocol.configure(.init(
            statusCode: 200,
            headers: ["Etag": "etag-malformed"],
            data: malformed
        ))
        let recorder = MetadataDecodeErrorRecorder()
        let client = MetadataClient(
            session: MetadataClientMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { error, tags in recorder.record(error: error, tags: tags) }
        )
        await client.resetForTesting()

        await client.forceRefresh()

        let event = recorder.snapshot().first
        #expect(recorder.snapshot().count == 1)
        #expect(event?.message == "metadata_payload_decode_failed")
        #expect(event?.tags["operation"] == "decode")
        #expect(event?.tags["source"] == "network")
        #expect(event?.tags["http_status"] == "200")
        #expect(event?.tags["byte_count"] == String(malformed.count))
        await client.resetForTesting()
    }

    @Test("After an account switch, bootstrap and legacy-format migration stay strictly bound to their own partitions")
    func bootstrapAndMigrationRemainAccountBound() async throws {
        let savedUID = AppSessionStore.activeUID
        let firstUID = "metadata-r3-first-\(UUID().uuidString)"
        let secondUID = "metadata-r3-second-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.activeUID = savedUID
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: firstUID))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: secondUID))
        }

        let client = MetadataClient()
        AppSessionStore.activeUID = firstUID
        await client.resetForTesting()
        try await client.writePersistedCacheForTesting(
            payload: #"{"version":31,"view":"lean","contractVersion":1,"providers":{}}"#,
            version: 31,
            contractVersion: 1,
            etag: "etag-first",
            boundUID: firstUID
        )

        AppSessionStore.activeUID = secondUID
        await client.resetForTesting()
        try await client.writePersistedCacheForTesting(
            payload: #"{"version":32,"view":"lean","contractVersion":1,"providers":{}}"#,
            version: 32,
            contractVersion: 1,
            etag: "etag-second",
            boundUID: secondUID
        )

        AppSessionStore.activeUID = firstUID
        await client.initialize()
        #expect(await client.grdbPersistCountSnapshotForTesting() == 1)
        #expect(client.syncMetadataETag() == "etag-first")

        AppSessionStore.activeUID = secondUID
        await client.initialize()
        #expect(await client.grdbPersistCountSnapshotForTesting() == 2)
        #expect(client.syncMetadataETag() == "etag-second")

        AppSessionStore.activeUID = firstUID
        await client.resetForTesting()
        AppSessionStore.activeUID = secondUID
        await client.resetForTesting()
    }

    @Test("capability observation also publishes when content changes within the same version, and schedules only the nearest expiry")
    func capabilityObservationPublishesContentAndNearestExpiry() async throws {
        let client = MetadataClient.shared
        await client.resetForTesting()
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let nearest = now + 500
        let later = now + 5_000
        func payload(etagMarker: String) -> String {
            """
            {
              "version": 7,
              "providers": {"openAI": {
                "resolveMap": {"model-a":"model-a","model-b":"model-b"},
                "models": {
                  "model-a": {"canonicalModelId":"model-a","transport":"openai_responses",
                    "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[{
                      "key":"tool_call","support":"supported","source":"server_typed",
                      "grade":"machine_verified","scope":"provider_model_transport",
                      "providerKind":"openAI","modelId":"model-a","transport":"openai_responses",
                      "observedAt":\(now - 1_000),"expiresAt":\(nearest)
                    }]},"displayName":"\(etagMarker)"},
                  "model-b": {"canonicalModelId":"model-b","transport":"openai_responses",
                    "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[{
                      "key":"vision_input","support":"supported","source":"server_typed",
                      "grade":"machine_verified","scope":"provider_model_transport",
                      "providerKind":"openAI","modelId":"model-b","transport":"openai_responses",
                      "observedAt":\(now - 1_000),"expiresAt":\(later)
                    }]}}
                }
              }}
            }
            """
        }

        let before = await CapabilityEvidenceObservationBridge.shared.contentRevision
        try await client.loadForTesting(json: payload(etagMarker: "first"), metadataETag: "etag-a")
        let afterFirst = await CapabilityEvidenceObservationBridge.shared.contentRevision
        let scheduled = await CapabilityEvidenceObservationBridge.shared.nearestExpiryForTesting
        #expect(afterFirst == before + 1)
        #expect(scheduled == nearest)

        // The payload version is still 7, but the 200 content / ETag changed generation, so it must publish once more.
        try await client.loadForTesting(json: payload(etagMarker: "second"), metadataETag: "etag-b")
        let afterSecond = await CapabilityEvidenceObservationBridge.shared.contentRevision
        #expect(afterSecond == afterFirst + 1)

        try await Task.sleep(for: .milliseconds(750))
        let afterExpiry = await CapabilityEvidenceObservationBridge.shared.contentRevision
        let nextScheduled = await CapabilityEvidenceObservationBridge.shared.nearestExpiryForTesting
        #expect(afterExpiry == afterSecond + 1)
        #expect(nextScheduled == later)
        await client.resetForTesting()
    }

    /// Regression: the nested Dictionary / JSONValue tree decoded from a 3 MB metadata payload
    /// can cross the watchdog's 2 s threshold with a single recursive release. With twenty-odd
    /// `sync*` reads inside SwiftUI bodies the main thread can be the last owner at any time, so deallocation must
    /// always be handed to the release queue through `MetadataSnapshotBox` / `replaceTable`.
    ///
    /// It asserts two things: replacing the snapshot is really wired to that channel (otherwise no release event is observed),
    /// and the release never lands on the main thread. Whoever turns `replaceTable(...)` back into a bare assignment or removes the box
    /// turns the first assertion red.
    @Test("Recursive deallocation of a large snapshot never lands on the main thread")
    @MainActor
    func snapshotReleaseNeverRunsOnMainThread() async throws {
        // First drain release tasks left behind by earlier cases so their events are not counted here
        MetadataClient.waitForSnapshotReleaseDrainForTesting()

        let recorder = SnapshotReleaseThreadRecorder()
        MetadataClient.snapshotReleaseThreadObserverForTesting = { isMain in
            recorder.record(isMainThread: isMain)
        }
        defer { MetadataClient.snapshotReleaseThreadObserverForTesting = nil }

        let client = MetadataClient()
        // First load -> replace within the same generation -> clear: all three replacements drop an old snapshot
        try await loadTestPayload(into: client)
        try await loadTestPayload(into: client)
        await client.resetForTesting()

        MetadataClient.waitForSnapshotReleaseDrainForTesting()

        let flags = recorder.flags
        #expect(!flags.isEmpty, "No snapshot release event was observed, so the replacement path bypasses the release queue")
        #expect(flags.allSatisfy { $0 == false }, "A snapshot release landed on the main thread: \(flags)")
    }

    /// Second path of the same regression: `ProviderCatalogResolver` has no await at all,
    /// yet it calls `contractVersionSnapshot` / `providerModelIDs` /
    /// `providerDefaultModelID` / `resolveCatalogModel` on the synchronous SwiftUI path. These four used to be actor-isolated methods
    /// that read `table` directly, bypassing `MetadataSnapshotBox` and `sharedStateLock`.
    ///
    /// This code is itself a compile-time assertion: if any of them goes back to actor isolation,
    /// the await-free synchronous calls inside `Task.detached` fail to compile. At runtime it also asserts
    /// that the catalog resolution path yields real values and that no snapshot release in between lands on the main thread.
    @Test("Metadata reads on the catalog resolution path use the shared snapshot and stay off the main thread")
    @MainActor
    func catalogResolverMetadataReadsAreNonisolated() async throws {
        MetadataClient.waitForSnapshotReleaseDrainForTesting()

        let recorder = SnapshotReleaseThreadRecorder()
        MetadataClient.snapshotReleaseThreadObserverForTesting = { isMain in
            recorder.record(isMainThread: isMain)
        }
        defer { MetadataClient.snapshotReleaseThreadObserverForTesting = nil }

        await MetadataClient.shared.resetForTesting()
        try await loadTestPayload(into: MetadataClient.shared)

        // Synchronous reads on a background thread: if the four methods were still actor-isolated, this would not even compile
        let offMain = await Task.detached { () -> (isMain: Bool, modelCount: Int, resolved: Bool, hasDefault: Bool, degrade: Bool) in
            let client = MetadataClient.shared
            let ids = client.providerModelIDs(providerKind: .openAI)
            let resolved = client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
            let defaultID = client.providerDefaultModelID(providerKind: .openAI)
            let contract = client.contractVersionSnapshot()
            return (
                Thread.isMainThread,
                ids.count,
                resolved != nil,
                defaultID != nil,
                contract.shouldSafeDegrade
            )
        }.value

        #expect(offMain.isMain == false)
        #expect(offMain.modelCount > 0)
        #expect(offMain.resolved)
        #expect(offMain.hasDefault)
        #expect(offMain.degrade == false)

        // The production path itself: the resolver runs the whole catalog synchronously on the main thread
        let provider = Provider(
            id: .init(),
            kind: .openAI,
            status: .connected,
            models: [],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "sk-test",
            apiKeyPreview: "sk-...test",
            lastError: nil,
            baseURLText: nil
        )
        ProviderCatalogResolver.resetMemoForTesting()
        let catalog = ProviderCatalogResolver.resolve(provider: provider)
        #expect(!catalog.catalog.isEmpty, "The resolver should get the official catalog from the shared snapshot")

        ProviderCatalogResolver.resetMemoForTesting()
        await MetadataClient.shared.resetForTesting()
        MetadataClient.waitForSnapshotReleaseDrainForTesting()

        let flags = recorder.flags
        #expect(!flags.isEmpty, "No snapshot release event was observed, so the replacement path bypasses the release queue")
        #expect(flags.allSatisfy { $0 == false }, "A snapshot release landed on the main thread: \(flags)")
    }

    @Test("resolveMap O(1) exact match returns backend capabilities and pricing")
    func exactMatch() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(metadata != nil)
        #expect(metadata?.displayName == "GPT-4o")
        #expect(metadata?.capabilities.contains(.image) == true)
        #expect(metadata?.capabilities.contains(.file) == true)
        #expect(metadata?.promptPerToken == 0.0000025)
        #expect(metadata?.completionPerToken == 0.00001)
    }

    @Test("resolveMap alias match (date-suffixed variant)")
    func aliasMatch() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(
            modelID: "gpt-4o-2024-08-06",
            providerKind: .openAI
        )

        #expect(metadata != nil)
        #expect(metadata?.canonicalModelId == "gpt-4o")
        #expect(metadata?.displayName == "GPT-4o")
    }

    @Test("Snapshot model IDs are normalized even when resolveMap has no alias")
    func hyphenatedSnapshotFallback() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(
            modelID: "gpt-5.4-nano-2026-03-01",
            providerKind: .openAI
        )

        #expect(metadata != nil)
        #expect(metadata?.canonicalModelId == "gpt-5.4-nano")
        #expect(metadata?.displayName == "GPT-5.4 nano")
        #expect(abs((metadata?.promptPerToken ?? 0) - 0.0000002) < 0.000000000001)
        #expect(metadata?.completionPerToken == 0.00000125)
    }

    @Test("A modelID not found in resolveMap returns nil")
    func unknownModelReturnsNil() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(
            modelID: "gpt-unknown-model",
            providerKind: .openAI
        )

        #expect(metadata == nil)
    }

    @Test("Anthropic provider parses correctly")
    func anthropicMatch() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(
            modelID: "claude-sonnet-4-20250514",
            providerKind: .anthropic
        )

        #expect(metadata != nil)
        #expect(metadata?.canonicalModelId == "claude-sonnet-4")
        #expect(metadata?.capabilities.contains(.reasoning) == true)
        #expect(metadata?.promptPerToken == 0.000003)
    }

    @Test("uiHints parse correctly (groupKey, rank, recommended)")
    func uiHintsParsing() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(metadata?.uiHints.groupKey == "gpt-4o")
        #expect(metadata?.uiHints.groupName == "GPT-4o")
        #expect(metadata?.uiHints.rank == 130)
        #expect(metadata?.uiHints.recommended == true)
    }

    @Test("profiles parse correctly (reasoning profile ref)")
    func profilesParsing() async throws {
        let client = try await makeLoadedClient()

        let metadata = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(metadata?.profiles.reasoning == "oai_responses")
        #expect(metadata?.profiles.webSearch == nil)
    }

    @Test("generation profile is expanded only from the shared template; an unknown template keeps zero injection")
    func generationProfileExpansion() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {
                "temperature": {
                  "group": "sampling",
                  "valueSchema": "number",
                  "range": { "min": 0, "max": 2 },
                  "interactionGroup": "sampling_strategy",
                  "portability": "portable",
                  "risk": "normal",
                  "conflictsWith": ["top_p"],
                  "constraints": [{ "mode": "normal" }]
                }
              },
              "templates": {
                "openai_chat_completions": {
                  "transport": "openai_chat_completions",
                  "wire": { "temperature": "temperature" }
                }
              }
            }
          },
          "providers": {
            "openAI": {
              "resolveMap": { "contract-model": "contract-model", "unknown-template": "unknown-template" },
              "models": {
                "contract-model": {
                  "profiles": {
                    "generation": {
                      "template": "openai_chat_completions",
                      "parameters": [{ "id": "temperature", "support": "supported", "source": "provider_metadata" }]
                    }
                  }
                },
                "unknown-template": {
                  "profiles": {
                    "generation": {
                      "template": "future_transport",
                      "parameters": [{ "id": "temperature", "support": "future_supported", "source": "future_source" }]
                    }
                  }
                }
              }
            }
          }
        }
        """)

        let expanded = await client.resolveCatalogModel(modelID: "contract-model", providerKind: .openAI)?.generationProfile
        #expect(expanded?.wire?["temperature"] == "temperature")
        #expect(expanded?.parameters?.first?.group == "sampling")
        #expect(expanded?.parameters?.first?.range == GenerationParameterRange(min: 0, max: 2))
        #expect(expanded?.parameters?.first?.portability == "portable")
        #expect(expanded?.parameters?.first?.conflictsWith == ["top_p"])
        #expect(expanded?.parameters?.first?.constraints?.first?["mode"] == .string("normal"))

        let unknown = await client.resolveCatalogModel(modelID: "unknown-template", providerKind: .openAI)
        #expect(unknown?.generationProfile == nil)
    }

    @Test("A model-level generation enumValues overrides the global value of the shared platform schema; when absent it falls back to the global value")
    func generationProfileModelLevelEnumValuesOverridesSharedSchema() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {
                "reasoning_effort": {
                  "group": "reasoning",
                  "valueSchema": "string",
                  "enumValues": ["low", "medium", "high", "xhigh"]
                }
              },
              "templates": {
                "openai_responses": {
                  "transport": "openai_responses",
                  "wire": { "reasoning_effort": "reasoning.effort" }
                }
              }
            }
          },
          "providers": {
            "openAI": {
              "resolveMap": { "narrowed-model": "narrowed-model", "fallback-model": "fallback-model" },
              "models": {
                "narrowed-model": {
                  "profiles": {
                    "generation": {
                      "template": "openai_responses",
                      "parameters": [{
                        "id": "reasoning_effort",
                        "support": "supported",
                        "source": "authoritative_metadata",
                        "enumValues": ["low", "high"]
                      }]
                    }
                  }
                },
                "fallback-model": {
                  "profiles": {
                    "generation": {
                      "template": "openai_responses",
                      "parameters": [{ "id": "reasoning_effort", "support": "supported", "source": "provider_metadata" }]
                    }
                  }
                }
              }
            }
          }
        }
        """)

        let narrowed = await client.resolveCatalogModel(modelID: "narrowed-model", providerKind: .openAI)?.generationProfile
        #expect(narrowed?.parameters?.first?.enumValues == [.string("low"), .string("high")])

        let fallback = await client.resolveCatalogModel(modelID: "fallback-model", providerKind: .openAI)?.generationProfile
        #expect(fallback?.parameters?.first?.enumValues == [.string("low"), .string("medium"), .string("high"), .string("xhigh")])
    }

    @Test("lean parameter table dereferencing and identity completion: the ref is authoritative and an existing wrong identity is not let through")
    func leanParameterTableAndEvidenceIdentityFallback() async throws {
        let client = MetadataClient()
        let envelope = try #require(try metadataLeanFixture()["leanResponse"] as? [String: Any])
        var data = try #require(envelope["data"] as? [String: Any])
        var providers = try #require(data["providers"] as? [String: Any])
        var openAI = try #require(providers["openAI"] as? [String: Any])
        var models = try #require(openAI["models"] as? [String: Any])
        var model = try #require(models["gpt-fixture"] as? [String: Any])
        var modelProfiles = try #require(model["profiles"] as? [String: Any])
        var generation = try #require(modelProfiles["generation"] as? [String: Any])
        generation["parameters"] = [[
            "id": "polluted_inline", "support": "unsupported", "source": "polluted_inline"
        ]]
        modelProfiles["generation"] = generation
        model["profiles"] = modelProfiles
        var evidence = try #require(model["capabilityEvidenceView"] as? [String: Any])
        var candidates = try #require(evidence["candidates"] as? [[String: Any]])
        var conflict = try #require(candidates.first)
        conflict["key"] = "web_search"
        conflict["providerKind"] = "wrong-provider"
        candidates.append(conflict)
        evidence["candidates"] = candidates
        model["capabilityEvidenceView"] = evidence
        models["gpt-fixture"] = model
        openAI["models"] = models
        providers["openAI"] = openAI
        data["providers"] = providers
        try await client.loadForTesting(
            json: try jsonString(data), metadataETag: "etag-lean"
        )

        let resolved = try #require(await client.resolveCatalogModel(
            modelID: "gpt-fixture", providerKind: .openAI
        ))
        #expect(resolved.generationProfile?.parameters?.compactMap(\.id) == ["temperature", "top_p"])
        #expect(resolved.generationProfile?.parameters?.first?.group == "sampling")
        #expect(resolved.capabilityEvidenceOwnedKeys == ["tool_call", "web_search"])
        #expect(resolved.capabilityEvidenceCandidates.map(\.key) == ["tool_call"])
        #expect(resolved.capabilityEvidenceCandidates.first?.providerKind == ProviderKind.openAI.rawValue)
        #expect(resolved.capabilityEvidenceCandidates.first?.modelID == "gpt-fixture")
        #expect(resolved.capabilityEvidenceCandidates.first?.transport == "openai_chat_completions")
        await client.resetForTesting()
    }

    @Test("generation decisions are equal between full evidence and lean profile")
    func fullAndLeanGenerationDecisionsAreEquivalent() async throws {
        func payload(lean: Bool) -> String {
            let table = lean ? """
              "view":"lean","generationParameterTables":{"sha256:matrix":[
                {"id":"temperature","support":"supported","source":"provider_metadata"}
              ]},
            """ : ""
            let parameters = lean
                ? "\"parametersRef\":\"sha256:matrix\",\"parameters\":[{\"id\":\"polluted_inline\",\"support\":\"unsupported\",\"source\":\"polluted_inline\"}]"
                : "\"parameters\":[{\"id\":\"temperature\",\"support\":\"supported\",\"source\":\"provider_metadata\"}]"
            let evidence = lean ? "{\"candidates\":[]}" : """
              {"schema":"capability-evidence-view/v1","candidates":[{
                "key":"generation_parameter/temperature","support":"supported",
                "source":"server_profile","grade":"effect_verified","scope":"provider_model_transport",
                "providerKind":"openAI","modelId":"m","transport":"openai_chat_completions",
                "generationRevision":"generation-r1"
              }]}
            """
            return """
            {"version":2,\(table)
              "profiles":{"generation":{
                "parameters":{"temperature":{"group":"sampling","valueSchema":"number"}},
                "templates":{"openai_chat_completions":{
                  "transport":"openai_chat_completions","wire":{"temperature":"temperature"}
                }}
              }},
              "providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
                "canonicalModelId":"m","transport":"openai_chat_completions",
                "profiles":{"generation":{"template":"openai_chat_completions",
                  "revision":"generation-r1",\(parameters)}},
                "capabilityEvidenceView":\(evidence)
              }}}}
            }
            """
        }
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "m")])
        let model = TestFactories.makeModel(id: "m")

        try await MetadataClient.shared.loadForTesting(json: payload(lean: false), metadataETag: "etag-full")
        let full = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, explicitParameterIDs: ["temperature"]
        )
        try await MetadataClient.shared.loadForTesting(json: payload(lean: true), metadataETag: "etag-lean")
        let lean = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, explicitParameterIDs: ["temperature"]
        )

        #expect(full.resolution(for: "temperature")?.support == lean.resolution(for: "temperature")?.support)
        #expect(full.resolution(for: "temperature")?.requestPolicy == lean.resolution(for: "temperature")?.requestPolicy)
        #expect(full.permitsOutbound("temperature") == lean.permitsOutbound("temperature"))

        let invalidRef = payload(lean: true).replacingOccurrences(
            of: "\"parametersRef\":\"sha256:matrix\"",
            with: "\"parametersRef\":\"\""
        )
        try await MetadataClient.shared.loadForTesting(json: invalidRef, metadataETag: "etag-invalid-ref")
        let invalidParameters = await MetadataClient.shared.resolveCatalogModel(
            modelID: "m", providerKind: .openAI
        )?.generationProfile?.parameters ?? []
        #expect(invalidParameters.isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("modelFacts is fetched on demand only on the subscription path, and a separate ETag hits 304")
    func modelFactsUsesOnDemandEndpointAndIndependentETag() async throws {
        let response = try JSONSerialization.data(
            withJSONObject: try #require(try metadataLeanFixture()["modelFactsResponse"])
        )
        MetadataClientMockURLProtocol.configure(.init(
            statusCode: 200, headers: ["Etag": "facts-etag-1"], data: response
        ))
        let client = MetadataClient(
            session: MetadataClientMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true
        )
        await client.resetForTesting()
        try await client.loadForTesting(
            json: #"{"version":2,"view":"lean","providers":{}}"#,
            metadataETag: "metadata-etag"
        )

        await client.refreshModelFacts()
        #expect(MetadataClientMockURLProtocol.urls().first?.path == "/api/metadata/model-facts")
        #expect(client.syncModelFacts(providerKind: .openAI, modelID: "gpt-out-of-catalog")?.toolCall == true)
        #expect(client.syncModelFactsRevision() == "sha256:facts-fixture")

        MetadataClientMockURLProtocol.configure(.init(statusCode: 304, headers: [:], data: Data()))
        await client.refreshModelFacts()
        #expect(MetadataClientMockURLProtocol.etags() == ["facts-etag-1"])
        #expect(client.syncModelFactsRevision() == "sha256:facts-fixture")

        MetadataClientMockURLProtocol.configure(.init(statusCode: 404, headers: [:], data: Data()))
        await client.refreshModelFacts()
        #expect(MetadataClientMockURLProtocol.etags() == ["facts-etag-1"])
        #expect(client.syncModelFactsRevision() == nil)
        #expect(client.syncModelFacts(providerKind: .openAI, modelID: "gpt-out-of-catalog") == nil)
        await client.resetForTesting()
    }

    /// When model-facts merge / are withdrawn while the picker is open: the intent index used by chip filtering must be invalidated, and after a rebuild it must agree with the per-row badges.
    @Test("modelFacts merge and withdrawal advance the capability signal and invalidate the picker intent index (304 does not advance the generation)")
    func modelFactsChangesInvalidatePickerIntentIndex() async throws {
        let response = try JSONSerialization.data(
            withJSONObject: try #require(try metadataLeanFixture()["modelFactsResponse"])
        )
        let client = MetadataClient(
            session: MetadataClientMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true
        )
        await client.resetForTesting()
        try await client.loadForTesting(
            json: #"{"version":2,"view":"lean","providers":{}}"#,
            metadataETag: "metadata-etag"
        )

        // Reasoning levels on the subscription path come only from modelFacts, so a new fact table generation is a new badge generation.
        var subscriptionProvider = TestFactories.makeProvider(kind: .openAI, models: [])
        subscriptionProvider.authMode = .subscription
        var subscriptionModel = TestFactories.makeModel(id: "gpt-out-of-catalog", capabilities: [.text, .reasoning])
        subscriptionModel.reasoningModeAvailable = true
        subscriptionModel.upstreamAPIBackend = "responses"
        let provider = subscriptionProvider
        let model = subscriptionModel
        let sections = [ModelPickerSection(provider: provider, models: [model])]
        let rowKey = ModelPickerCapabilityFilter.indexKey(providerID: provider.id, modelID: model.id)

        func snapshot() async -> (key: ModelPickerCapabilityIndexKey, index: ModelPickerCapabilityFilter.IntentIndex, live: [ModelPickerCapabilityFilter.Capability]) {
            await MainActor.run {
                (
                    ModelPickerCapabilityIndexKey.current(catalogGeneration: 0),
                    ModelPickerCapabilityFilter.intentIndex(sections: sections),
                    ModelPickerCapabilityFilter.intentCapabilities(model: model, provider: provider)
                )
            }
        }

        let before = await snapshot()
        #expect(before.index[rowKey]?.contains(.reasoning) == false, "Reasoning must not light up without a fact table")

        MetadataClientMockURLProtocol.configure(.init(
            statusCode: 200, headers: ["Etag": "facts-etag-1"], data: response
        ))
        await client.refreshModelFacts()
        let merged = await snapshot()
        #expect(merged.key.revision != before.key.revision, "Merging the fact table must advance the capability evidence signal")
        #expect(merged.key != before.key)
        #expect(merged.live.contains(.reasoning), "After merging, the per-row badge should light up reasoning, otherwise this case cannot observe the divergence")
        #expect(merged.index[rowKey] == merged.live)
        #expect(before.index[rowKey] != merged.live, "The old index really disagrees with the new badge, so it would keep being used if the key did not advance")

        MetadataClientMockURLProtocol.configure(.init(statusCode: 304, headers: [:], data: Data()))
        await client.refreshModelFacts()
        let notModified = await snapshot()
        #expect(notModified.key == merged.key, "A 304 does not advance the generation and must not rebuild the index")

        MetadataClientMockURLProtocol.configure(.init(statusCode: 404, headers: [:], data: Data()))
        await client.refreshModelFacts()
        let withdrawn = await snapshot()
        #expect(withdrawn.key.revision != merged.key.revision, "Withdrawing the fact table must advance the signal too")
        #expect(withdrawn.key != merged.key)
        #expect(withdrawn.index[rowKey] == withdrawn.live)
        #expect(withdrawn.live.contains(.reasoning) == false)
        await client.resetForTesting()
    }

    @Test("generation resolver keeps 0, supports omit, drops only the later-declared one of a conflict, and injects nothing for an unknown profile")
    func generationResolverSemantics() async throws {
        let fixture = try await makeGenerationWriterFixture()
        var body: [String: Any] = [:]
        let zeroOptions = ChatRequestOptions(generationParameters: .init(values: [
            "temperature": .init(state: .value, value: .number(0))
        ]))
        func apply(_ options: ChatRequestOptions, to body: inout [String: Any]) -> GenerationParameterApplication {
            CapabilityEvidenceRequestContext.$current.withValue(fixture.identity) {
                ProfileParamsResolver.applyGenerationParameters(
                    to: &body, options: options, profile: fixture.profile,
                    finalRequest: fixture.request, effectiveTransport: fixture.transport
                )
            }
        }
        #expect(apply(zeroOptions, to: &body).isClean)
        #expect(body["temperature"] as? Double == 0)

        let omitOptions = ChatRequestOptions(generationParameters: .init(values: [
            "temperature": .init(state: .omit)
        ]))
        #expect(apply(omitOptions, to: &body).isClean)
        #expect(body["temperature"] == nil)

        // Two mutually exclusive items: the one declared first is kept and the later one only drops itself, instead of dropping the whole group.
        let conflicting = ChatRequestOptions(generationParameters: .init(values: [
            "temperature": .init(state: .value, value: .number(0.2)),
            "top_p": .init(state: .value, value: .number(0.8))
        ]))
        #expect(apply(conflicting, to: &body).dropped == [.init(parameterID: "top_p", reason: .conflict)])
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["top_p"] == nil)
        body = [:]

        var schemaBody: [String: Any] = [:]
        let schemaOptions = ChatRequestOptions(generationParameters: .init(values: [
            "json_schema": .init(state: .value, value: .object(["type": .string("object")])),
            "max_output_tokens": .init(state: .value, value: .number(256))
        ]))
        #expect(apply(schemaOptions, to: &schemaBody).isClean)
        let responseFormat = schemaBody["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_schema")
        // When the request always carries tools (tool-loop search), only the JSON Schema is dropped; the max tokens in the same request still go out.
        var toolBody: [String: Any] = ["tools": [["type": "function"]]]
        #expect(apply(schemaOptions, to: &toolBody).dropped == [.init(parameterID: "json_schema", reason: .conflict)])
        #expect(toolBody["response_format"] == nil)
        #expect(toolBody["max_tokens"] as? Double == 256)

        let unknown = ChatRequestOptions(generationParameters: .init(values: [
            "temperature": .init(state: .value, value: .number(0.3))
        ]))
        #expect(ProfileParamsResolver.applyGenerationParameters(
            to: &body, options: unknown, profile: nil,
            finalRequest: fixture.request, effectiveTransport: fixture.transport
        ).isClean)
        #expect(body.isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("final generation scope reads the new ETag and profile revision from the same metadata pair")
    func finalGenerationScopeUsesAtomicMetadataPair() async throws {
        await MetadataClient.shared.resetForTesting()
        func payload(revision: String) -> String {
            """
            {
              "version": 1,
              "profiles": {"generation": {
                "version": 1,
                "parameters": {"temperature": {"valueSchema": "number"}},
                "templates": {"openai_chat_completions": {
                  "transport": "openai_chat_completions", "wire": {"temperature": "temperature"}
                }}
              }},
              "providers": {"openAI": {
                "resolveMap": {"atomic-model": "atomic-model"},
                "models": {"atomic-model": {
                  "canonicalModelId": "atomic-model",
                  "transport": "openai_chat_completions",
                  "profiles": {"generation": {
                    "template": "openai_chat_completions",
                    "revision": "\(revision)",
                    "parameters": [{"id":"temperature","support":"supported","source":"authoritative_metadata"}]
                  }}
                }}
              }}
            }
            """
        }
        try await MetadataClient.shared.loadForTesting(
            json: payload(revision: "generation-old"), metadataETag: "etag-old"
        )
        try await MetadataClient.shared.loadForTesting(
            json: payload(revision: "generation-new"), metadataETag: "etag-new"
        )

        let initial = CapabilityEvidenceRequestIdentity(query: .init(
            partitionID: "u1", connectionInstanceID: "official-1",
            connectionGeneration: "cg1", credentialEpoch: "ce1",
            providerKind: ProviderKind.openAI.rawValue, authMode: ProviderAuthMode.apiKey.rawValue, modelID: "atomic-model",
            effectiveTransport: "openai_chat_completions",
            metadataRevision: "etag-old", generationRevision: "generation-old",
            now: 1_000, hasExplicitValue: true
        ))
        let request = URLRequest(url: try #require(URL(string: "https://api.test/v1/chat/completions")))
        let scoped = try #require(CapabilityEvidenceRequestContext.$current.withValue(initial) {
            CapabilityEvidenceRequestContext.generationScope(
                for: request,
                effectiveTransport: "openai_chat_completions",
                relayEngineProfile: nil,
                relayDeclaredProfile: nil
            )
        })
        #expect(scoped.query.metadataRevision == "etag-new")
        #expect(scoped.query.generationRevision == "generation-new")
        let projection = CapabilityEvidenceProductionAdapter.generationRequestProjection(
            identity: scoped,
            relayEngineProfile: nil,
            explicitParameterIDs: ["temperature"]
        )
        #expect(projection.permitsOutbound("temperature"))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("generation resolver drops an invalid schema value without touching the request")
    func generationResolverRejectsInvalidSchemaValue() async throws {
        let fixture = try await makeGenerationWriterFixture()
        let options = ChatRequestOptions(generationParameters: .init(values: [
            "max_output_tokens": .init(state: .value, value: .number(0.5))
        ]))
        var body: [String: Any] = ["model": "test"]
        let application = CapabilityEvidenceRequestContext.$current.withValue(fixture.identity) {
            ProfileParamsResolver.applyGenerationParameters(
                to: &body, options: options, profile: fixture.profile,
                finalRequest: fixture.request, effectiveTransport: fixture.transport
            )
        }
        #expect(application.dropped == [.init(parameterID: "max_output_tokens", reason: .invalidValue)])
        #expect(body["max_tokens"] == nil)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("The reasoning profile returns only the levels declared by the server")
    func supportedReasoningModes() async throws {
        let client = try await makeLoadedClient()

        let modes = await client.supportedReasoningModes(profileName: "oai_responses")
        #expect(modes == [.automatic, .fast, .balanced, .deep])
    }

    @Test("A non-empty profile name that is missing from the profiles table (withdrawn by the server / old snapshot) collapses to automatic only, with no fail-open fake levels")
    func supportedReasoningModesWithdrawnProfileCollapsesToAutomatic() async throws {
        let client = try await makeLoadedClient()

        let modes = await client.supportedReasoningModes(profileName: "profile_withdrawn_by_server")
        #expect(modes == [.automatic])
    }

    @Test("An empty profileName is the normal relay case and must stay fail-open, returning all levels")
    func supportedReasoningModesNilProfileNameStaysFailOpen() async throws {
        let client = try await makeLoadedClient()

        let modes = await client.supportedReasoningModes(profileName: nil)
        #expect(modes == ReasoningMode.allCases)
    }

    @Test("A reasoning level beyond the profile is clamped to the highest allowed level")
    func clampReasoningMode() async throws {
        let client = try await makeLoadedClient()

        let mode = await client.clampReasoningMode(.max, profileName: "oai_responses")
        #expect(mode == .deep)
    }

    @Test("defaultModelId marks isDefault")
    func defaultModelIdFlag() async throws {
        let client = try await makeLoadedClient()

        let defaultModel = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(defaultModel?.isDefault == true)

        // claude-sonnet-4-20250514 resolves to claude-sonnet-4 and defaultModelId is also claude-sonnet-4, so it is the default too
        let alsoDefault = await client.resolveCatalogModel(modelID: "claude-sonnet-4-20250514", providerKind: .anthropic)
        #expect(alsoDefault?.isDefault == true)
    }

    @Test("estimateCost uses resolveMap pricing")
    func estimateCost() async throws {
        let client = try await makeLoadedClient()

        let cost = await client.estimateCost(
            modelID: "gpt-4o",
            providerKind: .openAI,
            promptTokens: 1000,
            completionTokens: 500
        )

        // promptPerToken = 2.5/1M = 0.0000025, completionPerToken = 10/1M = 0.00001
        // 1000 * 0.0000025 + 500 * 0.00001 = 0.0025 + 0.005 = 0.0075
        #expect(abs(cost - 0.0075) < 0.0001)
    }

    @Test("estimateCost handles OpenAI snapshot model IDs with hyphenated dates")
    func estimateCostForHyphenatedSnapshot() async throws {
        let client = try await makeLoadedClient()

        let cost = await client.estimateCost(
            modelID: "gpt-5.4-nano-2026-03-01",
            providerKind: .openAI,
            promptTokens: 1_000,
            completionTokens: 500
        )

        #expect(abs(cost - 0.000825) < 0.000001)
    }

    @Test("The compatibility lookup returns pricing")
    func lookupPricing() async throws {
        let client = try await makeLoadedClient()

        let pricing = await client.lookup(modelID: "gpt-4o", providerKind: .openAI)
        #expect(pricing != nil)
        #expect(pricing?.promptPerToken == 0.0000025)
        #expect(pricing?.completionPerToken == 0.00001)
    }

    @Test("The compatibility capabilities call returns the capability list")
    func lookupCapabilities() async throws {
        let client = try await makeLoadedClient()

        let caps = await client.capabilities(modelID: "gpt-4o", providerKind: .openAI)
        #expect(caps != nil)
        #expect(caps?.contains(.image) == true)
        #expect(caps?.contains(.file) == true)
    }

    @Test("pricingStatus controls the visibility of free and unknown pricing")
    func pricingStatusControlsResolvedPricing() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-12T00:00:00Z",
          "providers": {
            "openRouter": {
              "displayName": "OpenRouter",
              "defaultModelId": "meta-llama/llama-3.3-8b-instruct:free",
              "resolveMap": {
                "meta-llama/llama-3.3-8b-instruct:free": "meta-llama/llama-3.3-8b-instruct:free",
                "openai/gpt-3.5-turbo-0125": "openai/gpt-3.5-turbo-0125"
              },
              "models": {
                "meta-llama/llama-3.3-8b-instruct:free": {
                  "canonicalModelId": "meta-llama/llama-3.3-8b-instruct:free",
                  "displayName": "Llama 3.3 8B Instruct",
                  "pricingStatus": "free",
                  "pricing": {
                    "promptPerMToken": 0,
                    "completionPerMToken": 0
                  },
                  "capabilities": ["text"],
                  "profiles": {}
                },
                "openai/gpt-3.5-turbo-0125": {
                  "canonicalModelId": "openai/gpt-3.5-turbo-0125",
                  "displayName": "GPT-3.5 Turbo",
                  "pricingStatus": "unknown",
                  "pricing": {
                    "promptPerMToken": 0,
                    "completionPerMToken": 0
                  },
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let free = await client.resolveCatalogModel(
            modelID: "meta-llama/llama-3.3-8b-instruct:free",
            providerKind: .openRouter
        )
        #expect(free?.pricingStatus == "free")
        #expect(free?.promptPerToken == 0)
        #expect(free?.completionPerToken == 0)

        let unknown = await client.resolveCatalogModel(
            modelID: "openai/gpt-3.5-turbo-0125",
            providerKind: .openRouter
        )
        #expect(unknown?.pricingStatus == "unknown")
        #expect(unknown?.promptPerToken == nil)
        #expect(unknown?.completionPerToken == nil)
    }

    @Test("A non-token pricing model keeps the richer fields and the token prices stay nil")
    func nonTokenPricingPreservesEnhancedFields() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-20T10:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-image-1",
              "resolveMap": {
                "gpt-image-1": "gpt-image-1"
              },
              "models": {
                "gpt-image-1": {
                  "canonicalModelId": "gpt-image-1",
                  "displayName": "GPT Image 1",
                  "billingSku": "gpt-image-1/payg",
                  "pricingUnit": "per_image",
                  "sourceSummary": {
                    "sourceKind": "official_registry",
                    "sourceName": "OpenAI Pricing Registry",
                    "fetchedAt": "2026-04-20T10:00:00Z"
                  },
                  "pricingStatus": "priced",
                  "pricing": {
                    "promptPerMToken": null,
                    "completionPerMToken": null,
                    "costPerUnit": 0.04,
                    "costInputBatches": 0.5,
                    "costOutputBatches": 0.7,
                    "costInputPriority": 0.09,
                    "costOutputPriority": 0.12,
                    "cacheReadInputPerMToken": 0.3,
                    "cacheCreationInputPerMToken": 0.45
                  },
                  "supportsPdfInput": true,
                  "supportsServiceTier": true,
                  "capabilities": ["text", "imageGeneration"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let resolved = await client.resolveCatalogModel(
            modelID: "gpt-image-1",
            providerKind: .openAI
        )
        #expect(resolved != nil)
        #expect(resolved?.pricingStatus == "priced")
        #expect(resolved?.billingSku == "gpt-image-1/payg")
        #expect(resolved?.pricingUnit == "per_image")
        #expect(resolved?.sourceSummary?.sourceKind == "official_registry")
        #expect(resolved?.sourceSummary?.sourceName == "OpenAI Pricing Registry")
        #expect(resolved?.promptPerToken == nil)
        #expect(resolved?.completionPerToken == nil)
        #expect(resolved?.costPerUnit == 0.04)
        #expect(resolved?.costInputBatches == 0.5)
        #expect(resolved?.costOutputBatches == 0.7)
        #expect(resolved?.costInputPriority == 0.09)
        #expect(resolved?.costOutputPriority == 0.12)
        #expect(resolved?.cacheReadInputPerMToken == 0.3)
        #expect(resolved?.cacheCreationInputPerMToken == 0.45)
        #expect(resolved?.supportsPdfInput == true)
        #expect(resolved?.supportsServiceTier == true)
    }

    @Test("estimateCost falls back to costPerUnit for non-token pricing")
    func estimateCostForNonTokenPricing() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-04-20T10:00:00Z",
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-image-1",
              "resolveMap": {
                "gpt-image-1": "gpt-image-1"
              },
              "models": {
                "gpt-image-1": {
                  "canonicalModelId": "gpt-image-1",
                  "displayName": "GPT Image 1",
                  "pricingUnit": "per_image",
                  "pricingStatus": "priced",
                  "pricing": {
                    "costPerUnit": 0.04
                  }
                }
              }
            }
          }
        }
        """)

        let cost = await client.estimateCost(
            modelID: "gpt-image-1",
            providerKind: .openAI,
            promptTokens: 0,
            completionTokens: 0
        )

        #expect(cost == 0.04)
    }

    // MARK: - contractVersion awareness

    @Test("capability contract v2 decodes an explicit null as authoritative unknown")
    func capabilityContractV2DecodesExplicitUnknown() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "capabilityContractVersion": 2,
          "providers": {
            "openAI": {
              "resolveMap": { "tri-state-model": "tri-state-model" },
              "models": {
                "tri-state-model": {
                  "modelRef": "modelref0123456789abcd",
                  "toolCall": null,
                  "libraryAgentic": null
                }
              }
            }
          }
        }
        """)

        let metadata = await client.resolveCatalogModel(
            modelID: "tri-state-model",
            providerKind: .openAI
        )
        #expect(metadata?.capabilityContractVersion == 2)
        #expect(metadata?.modelRef == "modelref0123456789abcd")
        #expect(metadata?.toolCall == nil)
        #expect(metadata?.libraryAgentic == nil)
    }

    @Test("capability contract v2 and the tri-state capability bits survive a GRDB cache roundtrip")
    func capabilityContractV2SurvivesPersistedCacheRoundTrip() async throws {
        let payload = """
        {
          "version": 1,
          "view": "lean",
          "contractVersion": 1,
          "capabilityContractVersion": 2,
          "providers": {
            "openAI": {
              "resolveMap": { "cached-tri-state-model": "cached-tri-state-model" },
              "models": {
                "cached-tri-state-model": {
                  "modelRef": "cachedrf0123456789abcd",
                  "toolCall": null,
                  "libraryAgentic": null
                }
              }
            }
          }
        }
        """

        let writer = MetadataClient()
        await writer.resetForTesting()
        try await writer.writePersistedCacheForTesting(
            payload: payload,
            version: 1,
            contractVersion: 1,
            etag: "capability-v2"
        )

        let reader = MetadataClient()
        await reader.initialize()
        let restored = await reader.resolveCatalogModel(
            modelID: "cached-tri-state-model",
            providerKind: .openAI
        )
        #expect(restored?.capabilityContractVersion == 2)
        #expect(restored?.modelRef == "cachedrf0123456789abcd")
        #expect(restored?.toolCall == nil)
        #expect(restored?.libraryAgentic == nil)
        await reader.resetForTesting()
    }

    @Test("Hydrating the current GRDB format is read-only and does not write back")
    func currentGRDBCacheHydrationDoesNotRewrite() async throws {
        let payload = #"{"version":3,"view":"lean","contractVersion":1,"providers":{}}"#
        let writer = MetadataClient()
        await writer.resetForTesting()
        try await writer.writePersistedCacheForTesting(
            payload: payload,
            version: 3,
            contractVersion: 1,
            etag: "etag-current"
        )
        await writer.markPersistedCacheAsCurrentFormatForTesting()

        let reader = MetadataClient()
        await reader.initialize()

        #expect(await reader.grdbPersistCountSnapshotForTesting() == 0)
        #expect(await reader.syncMetadataETag() == "etag-current")
        await reader.resetForTesting()
    }

    @Test("An old GRDB snapshot without a format marker is migrated only once")
    func legacyGRDBCacheHydrationRewritesOnlyOnce() async throws {
        let payload = #"{"version":3,"view":"lean","contractVersion":1,"providers":{}}"#
        let writer = MetadataClient()
        await writer.resetForTesting()
        try await writer.writePersistedCacheForTesting(
            payload: payload,
            version: 3,
            contractVersion: 1,
            etag: "etag-legacy-grdb"
        )

        let migratingReader = MetadataClient()
        await migratingReader.initialize()
        #expect(await migratingReader.grdbPersistCountSnapshotForTesting() == 1)

        let currentReader = MetadataClient()
        await currentReader.initialize()
        #expect(await currentReader.grdbPersistCountSnapshotForTesting() == 0)
        await currentReader.resetForTesting()
    }

    /// First launch for an upgrading user: pre-lean versions persisted the full view (measured raw 3,054,711 B in production).
    /// Decoding it on cold start would keep the whole tree alive until the first lean 200 replaces it, which means
    /// an extra 3 MB Dictionary/JSONValue tree out of thin air, exactly the fuel for the recursive deallocation regression above.
    @Test("A persisted cache that is not the lean view is always discarded and the network is used")
    func nonLeanPersistedCacheIsDiscarded() async throws {
        let writer = MetadataClient()
        await writer.resetForTesting()
        // No view field = the old full view (by contract, full omits this key to keep its historical byte shape)
        try await writer.writePersistedCacheForTesting(
            payload: #"{"version":7,"contractVersion":1,"providers":{}}"#,
            version: 7,
            contractVersion: 1,
            etag: "etag-full-view"
        )
        #expect(await writer.readPersistedCacheForTesting() == nil, "A full-view cache must not be hydrated")

        let reader = MetadataClient()
        await reader.initialize()
        #expect(reader.syncMetadataETag() == nil, "After discarding, the old ETag must not be reused; the network must be hit again")
        await reader.resetForTesting()

        // Control: the same record as a lean view hydrates normally
        try await writer.writePersistedCacheForTesting(
            payload: #"{"version":7,"view":"lean","contractVersion":1,"providers":{}}"#,
            version: 7,
            contractVersion: 1,
            etag: "etag-lean-view"
        )
        #expect(await writer.readPersistedCacheForTesting()?.version == 7)
        await writer.resetForTesting()
    }

    @Test("An old UserDefaults payload is migrated into GRDB read-only and cleaned up immediately")
    func legacyUserDefaultsCacheMigratesOnceAndIsRemoved() async throws {
        let payload = #"{"version":4,"view":"lean","contractVersion":1,"providers":{}}"#
        let writer = MetadataClient()
        await writer.resetForTesting()
        try await writer.writeLegacyUserDefaultsCacheForTesting(
            json: payload,
            timestamp: Date().timeIntervalSince1970,
            etag: "etag-legacy"
        )

        let reader = MetadataClient()
        await reader.initialize()

        #expect(await reader.grdbPersistCountSnapshotForTesting() == 1)
        #expect(await reader.legacyUserDefaultsPayloadExistsForTesting() == false)
        #expect(await reader.readPersistedCacheForTesting()?.version == 4)
        await reader.resetForTesting()
    }

    @Test("The capability public namespace is written to GRDB only, and private provenance is removed")
    func capabilityEvidencePersistenceIsStrictlySanitized() async throws {
        let payload = """
        {
          "version": 9,
          "view": "lean",
          "contractVersion": 1,
          "providers": {"openAI": {
            "resolveMap": {
              "safe-model":"safe-model",
              "absent-model":"absent-model",
              "null-model":"null-model",
              "malformed-model":"malformed-model"
            },
            "models": {
              "safe-model": {
                "canonicalModelId":"safe-model", "transport":"openai_responses",
                "capabilityEvidenceView": {
                  "schema":"capability-evidence-view/v1",
                  "privateNamespace":"PRIVATE_NAMESPACE_SENTINEL",
                  "candidates":[{
                    "key":"tool_call", "support":"supported", "source":"server_typed",
                    "grade":"machine_verified", "scope":"provider_model_transport",
                    "providerKind":"openAI", "modelId":"safe-model",
                    "transport":"openai_responses", "observedAt":1000, "expiresAt":9999999999999,
                    "sourceRef":"PRIVATE_SOURCE_REF_SENTINEL",
                    "artifactHash":"PRIVATE_ARTIFACT_HASH_SENTINEL",
                    "endpoint":"PRIVATE_ENDPOINT_SENTINEL",
                    "rawError":"PRIVATE_RAW_ERROR_SENTINEL"
                  }]
                }
              },
              "absent-model": {"canonicalModelId":"absent-model"},
              "null-model": {"canonicalModelId":"null-model", "capabilityEvidenceView":null},
              "malformed-model": {
                "canonicalModelId":"malformed-model",
                "capabilityEvidenceView":{"rawError":"PRIVATE_MALFORMED_SENTINEL"}
              }
            }
          }}
        }
        """

        let writer = MetadataClient()
        await writer.resetForTesting()
        let persisted = try await writer.persistSanitizedCacheForTesting(json: payload, etag: "etag-safe")
        #expect(persisted.userDefaultsPayload == nil)
        let value = try #require(persisted.grdbPayload)
        #expect(value.contains("tool_call"))
        #expect(!value.contains("PRIVATE_"))
        #expect(!value.contains("sourceRef"))
        #expect(!value.contains("artifactHash"))
        #expect(!value.contains("rawError"))

        let reader = MetadataClient()
        await reader.initialize()
        let safe = await reader.resolveCatalogModel(modelID: "safe-model", providerKind: .openAI)
        #expect(safe?.capabilityEvidenceOwnedKeys == ["tool_call"])
        #expect(safe?.capabilityEvidenceCandidates.count == 1)
        let absent = await reader.resolveCatalogModel(modelID: "absent-model", providerKind: .openAI)
        #expect(absent?.capabilityEvidenceViewPresent == false)
        let explicitNull = await reader.resolveCatalogModel(modelID: "null-model", providerKind: .openAI)
        #expect(explicitNull?.capabilityEvidenceViewPresent == true)
        #expect(explicitNull?.capabilityEvidenceViewMalformed == true)
        let malformed = await reader.resolveCatalogModel(modelID: "malformed-model", providerKind: .openAI)
        #expect(malformed?.capabilityEvidenceViewPresent == true)
        #expect(malformed?.capabilityEvidenceViewMalformed == true)
        await reader.resetForTesting()
    }

    @Test("A contractVersion equal to the client-supported version parses normally")
    func contractVersionCurrentParsesNormally() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 42,
          "contractVersion": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "validationModelId": "gpt-4o",
              "resolveMap": { "gpt-4o": "gpt-4o" },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "capabilities": ["text"],
                  "pricing": { "promptPerMToken": 2.5, "completionPerMToken": 10.0 },
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let metadata = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(metadata?.displayName == "GPT-4o")
        let snapshot = await client.contractVersionSnapshot()
        #expect(snapshot.metadataContractVersion == 1)
        #expect(snapshot.isCompatible)
        #expect(!snapshot.shouldSafeDegrade)
    }

    @Test("A contractVersion older than the client's built-in version parses through the compatibility path")
    func contractVersionLegacyParsesCompat() async throws {
        let client = MetadataClient()
        // A missing contractVersion field -> treated as the old version (0 / missing)
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": { "gpt-4o": "gpt-4o" },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "capabilities": ["text"],
                  "pricing": { "promptPerMToken": 1.0, "completionPerMToken": 4.0 },
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        // Does not crash and can parse
        let metadata = await client.resolveCatalogModel(modelID: "gpt-4o", providerKind: .openAI)
        #expect(metadata?.displayName == "GPT-4o")
        let snapshot = await client.contractVersionSnapshot()
        #expect(snapshot.isCompatible, "A missing contractVersion should take the compatibility path and not trigger safe degrade")
        #expect(!snapshot.shouldSafeDegrade)
    }

    @Test("A contractVersion more than 2 above the client-supported version enters safe degrade")
    func contractVersionTooNewTriggersSafeDegrade() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 99,
          "contractVersion": 99,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-4o",
              "resolveMap": { "gpt-4o": "gpt-4o" },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let snapshot = await client.contractVersionSnapshot()
        #expect(snapshot.shouldSafeDegrade, "A contractVersion that is too new (>= N+2) must enter safe degrade")
    }

    // MARK: - BYOK key validation contract parsing (probe / probePath / authMode / headerProfile / invalidKeySignals)

    @Test("The provider-level validation contract can be read by MetadataClient")
    func validationContractReadable() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "qwen": {
              "defaultModelId": "qwen-max",
              "validation": {
                "probe": "list_models",
                "probePath": "/models",
                "authMode": "bearer",
                "headerProfile": "none",
                "invalidKeySignals": [{ "status": 401 }]
              },
              "resolveMap": {
                "qwen-max": "qwen-max"
              },
              "models": {
                "qwen-max": {
                  "canonicalModelId": "qwen-max",
                  "displayName": "Qwen Max",
                  "capabilities": ["text"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let validation = try #require(await client.providerValidation(providerKind: .qwen))
        #expect(validation.probe == "list_models")
        #expect(validation.probePath == "/models")
        #expect(validation.authMode == "bearer")
        #expect(validation.headerProfile == "none")
        #expect(validation.invalidKeySignals?.count == 1)
        #expect(validation.invalidKeySignals?.first?.status == 401)
        #expect(validation.invalidKeySignals?.first?.bodyIncludes == nil)
    }

    @Test("The provider-level attachmentSupport can be read by MetadataClient")
    func attachmentSupportReadable() async throws {
        let client = MetadataClient()
        try await client.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "qwen": {
              "defaultModelId": "qwen-max",
              "attachmentSupport": {
                "image": true,
                "nativeFile": false,
                "textFileInline": true
              },
              "resolveMap": {
                "qwen-max": "qwen-max"
              },
              "models": {
                "qwen-max": {
                  "canonicalModelId": "qwen-max",
                  "displayName": "Qwen Max",
                  "capabilities": ["text", "file"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let support = await client.providerAttachmentSupport(providerKind: .qwen)
        #expect(support?.image == true)
        #expect(support?.nativeFile == false)
        #expect(support?.textFileInline == true)
    }

    @Test("ProviderKind attachmentSupport prefers the metadata snapshot")
    func providerKindAttachmentSupportPrefersMetadataSnapshot() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "qwen": {
              "defaultModelId": "qwen-max",
              "attachmentSupport": {
                "image": true,
                "nativeFile": true,
                "textFileInline": true
              },
              "resolveMap": {
                "qwen-max": "qwen-max"
              },
              "models": {
                "qwen-max": {
                  "canonicalModelId": "qwen-max",
                  "displayName": "Qwen Max",
                  "capabilities": ["text", "file"],
                  "profiles": {}
                }
              }
            }
          }
        }
        """)

        let support = ProviderKind.qwen.attachmentSupport
        #expect(support.image == true)
        #expect(support.nativeFile == true)
        #expect(support.textFileInline == true)

        await MetadataClient.shared.resetForTesting()

        // No metadata: official providers claim no attachment support.
        let fallback = ProviderKind.qwen.attachmentSupport
        #expect(fallback.image == false)
        #expect(fallback.video == false)
        #expect(fallback.nativeFile == false)
        #expect(fallback.textFileInline == false)
    }

    @Test("relayRuntimeConfig falls back to the built-in defaults when missing")
    func relayRuntimeConfigFallback() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {}
        }
        """)

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.version == "fallback")
        #expect(runtime.officialProviderWhitelist.contains("openAI"))
        #expect(runtime.officialProviderWhitelist.contains("anthropic"))
        #expect(runtime.officialProviderWhitelist.contains("gemini"))
        #expect(runtime.transportEnvelopes["openai_responses"]?.webSearch == true)
        #expect(runtime.transportEnvelopes["openai_chat_completions"]?.webSearch == false)
        #expect(runtime.transportEnvelopes["anthropic_messages"]?.imageGeneration == false)
        #expect(runtime.featureGatingPolicy.showActualModelIdHint == true)
        #expect(runtime.featureGatingPolicy.showSoftFailHint == true)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("relayRuntimeConfig passes through what the backend sends, falling back field by field when some fields are missing")
    func relayRuntimeConfigPartialOverride() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {},
          "relayRuntimeConfig": {
            "version": "2026-04-23-1",
            "officialProviderWhitelist": ["openAI", "anthropic"],
            "transportEnvelopes": {
              "openai_responses": {
                "webSearch": false
              }
            },
            "transportRules": {
              "openai_responses": {
                "defaultAuthMode": "query_key",
                "codexIdentityDefault": false
              }
            },
            "verificationPolicy": {
              "hardFailedExpiryDays": 14,
              "softFailedRetryAfterSeconds": 120,
              "verifiedCacheDays": 60
            },
            "featureGatingPolicy": {
              "showActualModelIdHint": false,
              "showSoftFailHint": true
            }
          }
        }
        """)

        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.version == "2026-04-23-1")
        #expect(runtime.officialProviderWhitelist == ["openAI", "anthropic"])
        #expect(runtime.transportEnvelopes["openai_responses"]?.webSearch == false)
        #expect(runtime.transportEnvelopes["openai_responses"]?.image == true)
        #expect(runtime.transportEnvelopes["openai_responses"]?.nativeFile == true)
        #expect(runtime.transportEnvelopes["openai_responses"]?.imageGeneration == true)
        #expect(runtime.transportRules["openai_responses"]?.defaultAuthMode == "query_key")
        #expect(runtime.transportRules["openai_responses"]?.codexIdentityDefault == false)
        #expect(runtime.transportRules["openai_responses"]?.imageRoute == "inline_responses_tool")
        // A transport that was not sent keeps the fallback defaults
        #expect(runtime.transportEnvelopes["anthropic_messages"]?.image == true)
        #expect(runtime.transportRules["anthropic_messages"]?.defaultAuthMode == "x_api_key")
        #expect(runtime.verificationPolicy.hardFailedExpiryDays == 14)
        #expect(runtime.featureGatingPolicy.showActualModelIdHint == false)
        #expect(runtime.featureGatingPolicy.showSoftFailHint == true)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("A valid delivered version -> the UA uses the delivered value; an invalid delivery or not loaded -> the UA uses the built-in fallback value")
    func relayRuntimeConfigDeliversCodexClientVersion() async throws {
        func load(version: String) async throws {
            await MetadataClient.shared.resetForTesting()
            let rule = String(
                decoding: try JSONSerialization.data(withJSONObject: ["codexClientVersion": version]), as: UTF8.self
            )
            try await MetadataClient.shared.loadForTesting(json: """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {},
              "relayRuntimeConfig": {
                "version": "2026-10-12-1",
                "transportRules": { "openai_responses": \(rule) }
              }
            }
            """)
        }
        let fallbackPrefix = "codex_cli_rs/\(RelayRuntimeSupport.codexCliVersion) "

        // Runtime config not loaded: the built-in rule carries no version.
        await MetadataClient.shared.resetForTesting()
        #expect(MetadataClient.shared.syncRelayRuntimeConfig().transportRules["openai_responses"]?.codexClientVersion == nil)
        #expect(RelayRuntimeSupport.codexCliUserAgent.hasPrefix(fallbackPrefix))

        try await load(version: "0.199.7")
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        #expect(runtime.transportRules["openai_responses"]?.codexClientVersion == "0.199.7")
        // When only this one field is delivered, the other fields still fall back field by field.
        #expect(runtime.transportRules["openai_responses"]?.codexIdentityDefault == true)
        #expect(RelayRuntimeSupport.codexCliUserAgent.hasPrefix("codex_cli_rs/0.199.7 (iOS "))
        #expect(
            RelayRuntimeSupport.codexIdentityHeaders(for: .openaiResponses)["User-Agent"]?
                .hasPrefix("codex_cli_rs/0.199.7 ") == true
        )

        for invalid in ["latest", "0.170.0-alpha.1", "0.170.0\nX-Injected: 1"] {
            try await load(version: invalid)
            let ua = RelayRuntimeSupport.codexCliUserAgent
            #expect(ua.hasPrefix(fallbackPrefix), "A delivered \(invalid.debugDescription) must not enter the request header, actual \(ua.debugDescription)")
            #expect(!ua.contains("\n"))
        }

        await MetadataClient.shared.resetForTesting()
    }

    @Test("syncResolveCatalogModelAcrossProvidersWithProvider hits across providers and returns matchedProviderKind")
    func resolveAcrossProvidersWithProviderKind() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-5.4",
              "resolveMap": { "gpt-5.4": "gpt-5.4" },
              "models": {
                "gpt-5.4": {
                  "canonicalModelId": "gpt-5.4",
                  "displayName": "GPT-5.4",
                  "capabilities": ["text", "image", "web", "reasoning"],
                  "profiles": { "reasoning": "oai_responses", "webSearch": "oai_web" }
                }
              }
            },
            "anthropic": {
              "defaultModelId": "claude-sonnet-4.5",
              "resolveMap": { "claude-sonnet-4.5": "claude-sonnet-4.5" },
              "models": {
                "claude-sonnet-4.5": {
                  "canonicalModelId": "claude-sonnet-4.5",
                  "displayName": "Claude Sonnet 4.5",
                  "capabilities": ["text", "image", "reasoning"],
                  "profiles": { "reasoning": "anthropic_reasoning" }
                }
              }
            }
          }
        }
        """)

        let gpt = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "gpt-5.4")
        #expect(gpt?.matchedProviderKind == .openAI)
        #expect(gpt?.canonicalModelId == "gpt-5.4")
        #expect(gpt?.metadata.displayName == "GPT-5.4")
        #expect(gpt?.source == .crossProvider)

        let claude = MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(
            modelID: "claude-sonnet-4.5",
            transportPriority: .anthropic
        )
        #expect(claude?.matchedProviderKind == .anthropic)
        #expect(claude?.source == .transportFirst)

        #expect(MetadataClient.shared.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: "my-custom-model") == nil)

        await MetadataClient.shared.resetForTesting()
    }

    private func makeLoadedClient() async throws -> MetadataClient {
        let client = MetadataClient()
        try await loadTestPayload(into: client)
        return client
    }

    private struct GenerationWriterFixture {
        let profile: GenerationProfileRef
        let identity: CapabilityEvidenceRequestIdentity
        let request: URLRequest
        let transport: String
    }

    /// Get the profile / candidate from the production MetadataClient decoder, then bind the current ETag through the production identity adapter.
    /// The test neither hand-builds a facade Resolution nor uses the lenient entry point without a final scope.
    /// The authorization source of generation is the runtime: `CapabilityRecipeRequestCompiler.generationTemplate`
    /// only lets it through when it gets the exact `generation` control and the recipe's `legacy_generation_template` has the
    /// same name as the profile's template, otherwise the whole group is injected with nothing (kill switch).
    /// So the writer fixture must carry a real runtime + control, and the transport must use the official `openai_chat`
    /// (that is what `openai.chat.generation.v1` declares in the registry; `openai_chat_completions`
    /// is the vocabulary of the generation template / relay transport, and the two are not interchangeable).
    private func makeGenerationWriterFixture() async throws -> GenerationWriterFixture {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "generation", recipeRef: "openai.chat.generation.v1")
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {
            "generation": {
              "version": 1,
              "parameters": {
                "temperature": {"valueSchema": "number", "conflictsWith": ["top_p"]},
                "top_p": {"valueSchema": "number", "conflictsWith": ["temperature"]},
                "json_schema": {"valueSchema": "json-schema", "conflictsWith": ["tools"]},
                "max_output_tokens": {"valueSchema": "integer", "range": {"min": 1, "max": 4096}}
              },
              "templates": {
                "openai_chat_completions": {
                  "transport": "openai_chat_completions",
                  "wire": {
                    "temperature": "temperature",
                    "top_p": "top_p",
                    "json_schema": "response_format",
                    "max_output_tokens": "max_tokens"
                  }
                }
              }
            }
          },
          "providers": {
            "openAI": {
              "resolveMap": {"writer-model": "writer-model"},
              "models": {
                "writer-model": {
                  "canonicalModelId": "writer-model",
                  "transport": "openai_chat",
                  "capabilityControls": \(controls),
                  "profiles": {
                    "generation": {
                      "template": "openai_chat_completions",
                      "revision": "writer-generation-v1",
                      "parameters": [
                        {"id": "temperature", "support": "supported", "source": "authoritative_metadata"},
                        {"id": "top_p", "support": "supported", "source": "authoritative_metadata"},
                        {"id": "json_schema", "support": "supported", "source": "authoritative_metadata"},
                        {"id": "max_output_tokens", "support": "supported", "source": "authoritative_metadata"}
                      ]
                    }
                  }
                }
              }
            }
          }
        }
        """, metadataETag: "writer-etag-v1")
        guard let resolved = MetadataClient.shared.syncResolveCatalogModel(
            modelID: "writer-model", providerKind: .openAI
        ), let profile = resolved.generationProfile,
           let transport = resolved.transport,
           let url = URL(string: "https://api.openai.test/v1/chat/completions") else {
            throw CocoaError(.coderInvalidValue)
        }
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        var model = TestFactories.makeModel(id: "writer-model")
        model.canonicalModelId = resolved.canonicalModelId
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: "writer-user",
            hasExplicitValue: true,
            metadataETag: "writer-etag-v1"
        )
        return .init(
            profile: profile,
            identity: identity,
            request: URLRequest(url: url),
            transport: transport
        )
    }

    private func loadTestPayload(into client: MetadataClient) async throws {
        let json = """
        {
          "version": 1,
          "updatedAt": "2026-03-25T00:00:00Z",
          "profiles": {
            "reasoning": {
              "oai_responses": {
                "levels": ["fast", "balanced", "deep"]
              },
              "anthropic_extended": {
                "levels": ["fast", "balanced", "deep", "max"]
              }
            }
          },
          "providers": {
            "openAI": {
              "displayName": "OpenAI",
              "defaultModelId": "gpt-4o",
              "resolveMap": {
                "gpt-4o": "gpt-4o",
                "gpt-4o-2024-08-06": "gpt-4o",
                "gpt-5.4-nano": "gpt-5.4-nano"
              },
              "models": {
                "gpt-4o": {
                  "canonicalModelId": "gpt-4o",
                  "displayName": "GPT-4o",
                  "contextLength": 128000,
                  "pricing": {
                    "promptPerMToken": 2.5,
                    "completionPerMToken": 10.0,
                    "cachedInputPerMToken": 1.25
                  },
                  "capabilities": ["text", "image", "file", "reasoning"],
                  "profiles": {
                    "reasoning": "oai_responses",
                    "webSearch": null,
                    "imageGen": null
                  },
                  "uiHints": {
                    "groupKey": "gpt-4o",
                    "groupName": "GPT-4o",
                    "rank": 130,
                    "recommended": true,
                    "badgeOrder": ["reasoning", "image", "file"]
                  }
                },
                "gpt-5.4-nano": {
                  "canonicalModelId": "gpt-5.4-nano",
                  "displayName": "GPT-5.4 nano",
                  "contextLength": 400000,
                  "pricing": {
                    "promptPerMToken": 0.2,
                    "completionPerMToken": 1.25,
                    "cachedInputPerMToken": 0.02
                  },
                  "capabilities": ["text", "image", "reasoning"],
                  "profiles": {
                    "reasoning": "oai_responses",
                    "webSearch": null,
                    "imageGen": null
                  },
                  "uiHints": {
                    "groupKey": "gpt-5",
                    "groupName": "GPT-5",
                    "rank": 166,
                    "recommended": false,
                    "badgeOrder": ["reasoning", "image"]
                  }
                }
              }
            },
            "anthropic": {
              "displayName": "Anthropic",
              "defaultModelId": "claude-sonnet-4",
              "resolveMap": {
                "claude-sonnet-4": "claude-sonnet-4",
                "claude-sonnet-4-20250514": "claude-sonnet-4"
              },
              "models": {
                "claude-sonnet-4": {
                  "canonicalModelId": "claude-sonnet-4",
                  "displayName": "Claude Sonnet 4",
                  "contextLength": 200000,
                  "pricing": {
                    "promptPerMToken": 3.0,
                    "completionPerMToken": 15.0
                  },
                  "capabilities": ["text", "image", "file", "reasoning"],
                  "profiles": {
                    "reasoning": "anthropic_extended",
                    "webSearch": null,
                    "imageGen": null
                  },
                  "uiHints": {
                    "groupKey": "claude-sonnet-4",
                    "groupName": "Claude Sonnet 4",
                    "rank": 150,
                    "recommended": true
                  }
                }
              }
            }
          }
        }
        """

        try await client.loadForTesting(json: json)
    }
}
