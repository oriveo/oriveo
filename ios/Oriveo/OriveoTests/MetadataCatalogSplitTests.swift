import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Metadata mock routed by query: index / catalog:<kind> / lean / facts each have their own stub, and
/// every request's route and If-None-Match are recorded in order so tests can assert which catalogs
/// were fetched and that a matching revision costs no request.
private final class SplitMetadataMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    struct Request: Sendable, Equatable {
        let route: String
        let ifNoneMatch: String?
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]
    private static var recorded: [Request] = []

    static func reset() {
        lock.lock()
        stubs = [:]
        recorded = []
        lock.unlock()
    }

    static func stub(_ route: String, _ stub: Stub) {
        lock.lock()
        stubs[route] = stub
        lock.unlock()
    }

    static func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func clearRequests() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SplitMetadataMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func route(for url: URL) -> String {
        if url.path.hasSuffix("/model-facts") { return "facts" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let view = items.first { $0.name == "view" }?.value
        switch view {
        case "index": return "index"
        case "lean": return "lean"
        case "catalog": return "catalog:" + (items.first { $0.name == "provider" }?.value ?? "")
        default: return "other"
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = Self.route(for: request.url!)
        Self.lock.lock()
        let stub = Self.stubs[route] ?? Stub(statusCode: 404, headers: [:], data: Data())
        Self.recorded.append(Request(
            route: route,
            ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")
        ))
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.data.isEmpty {
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private final class CatalogDiagnosticRecorder: @unchecked Sendable {
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

/// Shared corpus generated directly from server output; clients must not hand-craft their own.
private func catalogCorpus() throws -> [String: Any] {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent(
            "shared/model-contracts/metadata_catalog_contract.v1.json"
        )
        if FileManager.default.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        folder.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jsonText(_ object: Any) throws -> String {
    try #require(String(data: try jsonData(object), encoding: .utf8))
}

private func ok(_ object: Any, etag: String? = nil, catalogRevision: String? = nil) throws -> SplitMetadataMockURLProtocol.Stub {
    var headers: [String: String] = [:]
    if let etag { headers["Etag"] = etag }
    if let catalogRevision { headers["X-Metadata-Catalog-Revision"] = catalogRevision }
    return .init(statusCode: 200, headers: headers, data: try jsonData(object))
}

private func status(_ code: Int) -> SplitMetadataMockURLProtocol.Stub {
    .init(statusCode: code, headers: [:], data: Data())
}

/// The `data` part of a `{code,data,message}` envelope.
private func dataObject(_ wrapped: Any?) throws -> [String: Any] {
    let wrapped = try #require(wrapped as? [String: Any])
    return try #require(wrapped["data"] as? [String: Any])
}

private func rewrapped(_ data: [String: Any]) -> [String: Any] {
    ["code": 0, "data": data, "message": "ok"]
}

private func indexData(_ corpus: [String: Any]) throws -> [String: Any] {
    try dataObject(corpus["indexResponse"])
}

private func leanEquivalentData(_ corpus: [String: Any]) throws -> [String: Any] {
    try dataObject(corpus["leanEquivalent"])
}

/// The data (ref form) of one provider catalog in the corpus.
private func catalogData(_ corpus: [String: Any], _ kind: String) throws -> [String: Any] {
    let catalogs = try #require(corpus["catalogResponses"] as? [String: Any])
    return try dataObject(catalogs[kind])
}

/// Model ids always come from the corpus: it holds real snapshot entries that change over time.
private func catalogModelIDs(_ corpus: [String: Any], _ kind: String) throws -> [String] {
    let models = try #require(try catalogData(corpus, kind)["models"] as? [String: Any])
    return models.keys.sorted()
}

/// Replaces one provider's catalogRevision in the index (an older last-good generation or a snapshot
/// rollover race).
private func index(_ index: [String: Any], revision: String, for kind: String) throws -> [String: Any] {
    var index = index
    var providers = try #require(index["providers"] as? [String: Any])
    var entry = try #require(providers[kind] as? [String: Any])
    entry["catalogRevision"] = revision
    providers[kind] = entry
    index["providers"] = providers
    return index
}

private func catalog(_ catalog: [String: Any], revision: String) -> [String: Any] {
    var catalog = catalog
    catalog["catalogRevision"] = revision
    return catalog
}

/// Comparable fingerprint produced by the production decoding path: model set, pricing, capabilities,
/// resolved generation parameters, capabilityControls, evidence and provider-level fields.
/// Dictionary-bearing structures (generation wire / constraints) compare via Equatable rather than
/// strings, because dictionary descriptions have no stable order.
private struct DecodedFingerprint: Equatable {
    var lines: [String] = []
    var generation: [String: GenerationProfileRef] = [:]
    var evidence: [String: [CapabilityEvidenceFacade.Candidate]] = [:]
}

private func decodedFingerprint(_ client: MetadataClient) -> DecodedFingerprint {
    var fingerprint = DecodedFingerprint()
    var lines: [String] = []
    for kind in [ProviderKind.openAI, .anthropic] {
        lines.append([
            "provider=\(kind.rawValue)",
            "name=\(client.syncProviderDisplayName(providerKind: kind) ?? "nil")",
            "default=\(client.providerDefaultModelID(providerKind: kind) ?? "nil")",
            "validation=\(String(describing: client.syncProviderValidation(providerKind: kind)))",
            "attachment=\(String(describing: client.syncProviderAttachmentSupport(providerKind: kind)))",
            "transport=\(String(describing: client.syncProviderTransport(providerKind: kind)))",
        ].joined(separator: " "))
        for modelID in client.providerModelIDs(providerKind: kind) {
            guard let model = client.resolveCatalogModel(modelID: modelID, providerKind: kind) else {
                lines.append("\(modelID)=nil")
                continue
            }
            let controls = (client.syncCapabilityRecipeRuntime(modelID: modelID, providerKind: kind).controls ?? [:])
                .sorted { $0.key < $1.key }
                .map { key, control in
                    "\(key):\(control.state)|\(control.recipeRef ?? "-")|\(control.reasonCode ?? "-")|\(control.sourceRefs ?? [])|\(control.availableIntents ?? [])|\(control.customControlRefs ?? [])"
                }
            fingerprint.generation["\(kind.rawValue)/\(modelID)"] = model.generationProfile
            fingerprint.evidence["\(kind.rawValue)/\(modelID)"] = model.capabilityEvidenceCandidates
            lines.append([
                "model=\(modelID)",
                "canonical=\(model.canonicalModelId)",
                "display=\(model.displayName ?? "nil")",
                "pricing=\(model.pricingStatus)/\(model.pricingUnit)/\(String(describing: model.promptPerToken))/\(String(describing: model.completionPerToken))",
                "caps=\(model.capabilities.map(\.rawValue))",
                "profiles=\(String(describing: model.profiles.reasoning))/\(String(describing: model.profiles.webSearch))/\(String(describing: model.profiles.imageGen))",
                "hints=\(String(describing: model.uiHints.groupKey))/\(String(describing: model.uiHints.rank))/\(model.uiHints.recommended)",
                "default=\(model.isDefault)",
                "transport=\(model.transport ?? "nil")",
                "toolCall=\(String(describing: model.toolCall))",
                "agentic=\(String(describing: model.libraryAgentic))",
                "contract=\(String(describing: model.capabilityContractVersion))",
                "controls=\(controls)",
                "owned=\(model.capabilityEvidenceOwnedKeys.sorted())",
                "evidencePresent=\(model.capabilityEvidenceViewPresent)/\(model.capabilityEvidenceViewMalformed)",
            ].joined(separator: " "))
        }
    }
    fingerprint.lines = lines
    return fingerprint
}

private func evidenceSignature(_ candidate: CapabilityEvidenceFacade.Candidate) -> String {
    "\(candidate.key)|\(candidate.support.rawValue)|\(candidate.source.rawValue)|\(candidate.grade.rawValue)|\(candidate.observedAt ?? -1)|\(candidate.expiresAt ?? -1)"
}

private func rawEvidenceSignature(_ raw: [String: Any]) -> String {
    let observed = (raw["observedAt"] as? NSNumber)?.int64Value ?? -1
    let expires = (raw["expiresAt"] as? NSNumber)?.int64Value ?? -1
    return "\(raw["key"] as? String ?? "")|\(raw["support"] as? String ?? "")|\(raw["source"] as? String ?? "")|\(raw["grade"] as? String ?? "")|\(observed)|\(expires)"
}

/// (modelID, candidate) pairs of one corpus catalog whose evidence candidate matches; no hard-coded ids.
private func corpusEvidence(
    _ corpus: [String: Any],
    kind: String,
    where predicate: ([String: Any]) -> Bool
) throws -> [(modelID: String, candidate: [String: Any])] {
    let raw = try catalogData(corpus, kind)
    let tables = try #require(raw["tables"] as? [String: Any])
    let evidence = tables["capabilityEvidence"] as? [String: [String: Any]] ?? [:]
    let models = try #require(raw["models"] as? [String: [String: Any]])
    var result: [(modelID: String, candidate: [String: Any])] = []
    for (modelID, entry) in models.sorted(by: { $0.key < $1.key }) {
        guard let ref = entry["capabilityEvidenceRef"] as? String,
              let candidates = evidence[ref]?["candidates"] as? [[String: Any]] else { continue }
        for candidate in candidates where predicate(candidate) {
            result.append((modelID, candidate))
        }
    }
    return result
}

@Suite("MetadataClient index + per-provider catalog", .serialized)
struct MetadataCatalogSplitTests {

    private func makeClient(recorder: CatalogDiagnosticRecorder? = nil) -> MetadataClient {
        MetadataClient(
            session: SplitMetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { error, tags in recorder?.record(error: error, tags: tags) }
        )
    }

    private func providers(_ kinds: [ProviderKind]) -> [Provider] {
        kinds.map { TestFactories.makeProvider(kind: $0, models: []) }
    }

    /// Standard server: index plus the openAI and anthropic catalogs.
    private func stubServer(_ corpus: [String: Any], indexETag: String = "index-etag-1") throws {
        SplitMetadataMockURLProtocol.reset()
        SplitMetadataMockURLProtocol.stub("index", try ok(rewrapped(try indexData(corpus)), etag: indexETag))
        let catalogs = try #require(corpus["catalogResponses"] as? [String: Any])
        for kind in ["openAI", "anthropic"] {
            let wrapped = try #require(catalogs[kind])
            let revision = try dataObject(wrapped)["catalogRevision"] as? String
            SplitMetadataMockURLProtocol.stub(
                "catalog:\(kind)",
                try ok(wrapped, etag: "catalog-etag-\(kind)", catalogRevision: revision)
            )
        }
    }

    @Test("index + catalogs expanded and decoded here equal leanEquivalent model by model")
    func splitExpansionDecodesEqualToLeanEquivalent() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()

        // Baseline: leanEquivalent through the existing lean decoding.
        await client.resetForTesting()
        try await client.loadForTesting(
            json: try jsonText(try leanEquivalentData(corpus)),
            metadataETag: "index-etag-1"
        )
        let leanFingerprint = decodedFingerprint(client)

        // Production path: request the index and both catalogs, expand, assemble, then the same lean decoding.
        await client.resetForTesting()
        try stubServer(corpus, indexETag: "index-etag-1")
        client.registerConfiguredProviders(providers([.openAI, .anthropic]))
        await client.forceRefresh()
        let splitFingerprint = decodedFingerprint(client)

        #expect(splitFingerprint == leanFingerprint)
        #expect(splitFingerprint.generation.count
            == (try catalogModelIDs(corpus, "openAI").count + catalogModelIDs(corpus, "anthropic").count))
        // Equality must not hold because both sides are empty: check every model against the corpus ref
        // tables, asserting on objects produced by the production expansion.
        var evidenceModels = 0
        for (kind, providerKind) in [("openAI", ProviderKind.openAI), ("anthropic", .anthropic)] {
            let raw = try catalogData(corpus, kind)
            let tables = try #require(raw["tables"] as? [String: Any])
            let parameterTables = try #require(tables["generationParameters"] as? [String: [Any]])
            let controlTables = try #require(tables["capabilityControls"] as? [String: [String: Any]])
            let profileTables = try #require(tables["profiles"] as? [String: [String: Any]])
            let evidenceTables = tables["capabilityEvidence"] as? [String: [String: Any]] ?? [:]
            let models = try #require(raw["models"] as? [String: [String: Any]])
            #expect(client.providerModelIDs(providerKind: providerKind) == models.keys.sorted())
            for (modelID, entry) in models {
                let resolved = try #require(client.resolveCatalogModel(modelID: modelID, providerKind: providerKind))
                let profilesRef = try #require(entry["profilesRef"] as? String)
                let profiles = try #require(profileTables[profilesRef])
                let parametersRef = try #require((profiles["generation"] as? [String: Any])?["parametersRef"] as? String)
                #expect(resolved.generationProfile?.parameters?.count == parameterTables[parametersRef]?.count)
                #expect(resolved.generationProfile?.parameters?.isEmpty == false)
                let controlsRef = try #require(entry["capabilityControlsRef"] as? String)
                let expectedControls = try #require(controlTables[controlsRef])
                let controls = client.syncCapabilityRecipeRuntime(modelID: modelID, providerKind: providerKind).controls
                #expect(Set(controls?.keys.map { $0 } ?? []) == Set(expectedControls.keys))
                for (key, value) in expectedControls {
                    #expect(controls?[key]?.state == (value as? [String: Any])?["state"] as? String)
                }
                if let ref = entry["capabilityEvidenceRef"] as? String {
                    let candidates = try #require(evidenceTables[ref]?["candidates"] as? [[String: Any]])
                    // Evidence expanded from the ref matches the corpus entry by entry (models.dev evidence is
                    // server_typed + declared and must pass).
                    #expect(resolved.capabilityEvidenceViewPresent)
                    #expect(!resolved.capabilityEvidenceCandidates.isEmpty)
                    #expect(resolved.capabilityEvidenceCandidates.map(evidenceSignature) == candidates.map(rawEvidenceSignature))
                    #expect(resolved.capabilityEvidenceCandidates.allSatisfy { $0.metadataRevision == "index-etag-1" })
                    evidenceModels += 1
                } else {
                    #expect(!resolved.capabilityEvidenceViewPresent)
                }
            }
        }
        #expect(evidenceModels > 0, "the corpus needs at least one model with evidence, otherwise evidence expansion is untested")
        #expect(client.syncMetadataETag() == "index-etag-1")
        #expect(!client.syncIsCatalogPending(providerKind: .openAI))
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .anthropic))
        await client.resetForTesting()
    }

    @Test("matching revision sends no catalog request; 304 touches timestamps without rewriting bodies; a fresh split cache serves cold start")
    func unchangedRevisionSkipsRequestsAndNotModifiedOnlyTouches() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI, .anthropic]))

        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests().map(\.route).sorted()
            == ["catalog:anthropic", "catalog:openAI", "index"])
        #expect(await client.splitBodyWriteCountSnapshotForTesting() == 3)
        let firstRows = try await client.splitCacheRowsForTesting()
        #expect(firstRows["catalog:openAI"]?.etag == "catalog-etag-openAI")
        #expect(firstRows["index"]?.etag == "index-etag-1")

        // Second pass: index 304 and catalog revisions equal the index, so no catalog request at all.
        try await client.ageSplitCacheForTesting(by: 1_000)
        let aged = try await client.splitCacheRowsForTesting()
        SplitMetadataMockURLProtocol.stub("index", status(304))
        SplitMetadataMockURLProtocol.clearRequests()
        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests()
            == [.init(route: "index", ifNoneMatch: "index-etag-1")])
        #expect(await client.splitBodyWriteCountSnapshotForTesting() == 3, "a 304 must not rewrite bodies")
        let touched = try await client.splitCacheRowsForTesting()
        #expect(try #require(touched["index"]?.updatedAt) > (try #require(aged["index"]?.updatedAt)))
        #expect(touched["catalog:openAI"]?.updatedAt == aged["catalog:openAI"]?.updatedAt)

        // Cold start of another instance: renders straight from the split cache and only sends one
        // conditional index request in the background.
        SplitMetadataMockURLProtocol.clearRequests()
        let coldClient = makeClient()
        coldClient.registerConfiguredProviders(providers([.openAI, .anthropic]))
        await coldClient.initialize()
        let anthropicModelID = try #require(try catalogModelIDs(corpus, "anthropic").first)
        #expect(coldClient.resolveCatalogModel(modelID: anthropicModelID, providerKind: .anthropic) != nil)
        await coldClient.waitForBackgroundWorkForTesting()
        #expect(SplitMetadataMockURLProtocol.requests()
            == [.init(route: "index", ifNoneMatch: "index-etag-1")])
        await client.resetForTesting()
    }

    @Test("pending is not a miss: an unloaded provider reports pending and fetches only that catalog; only a loaded catalog can miss")
    func pendingProviderFetchesOnlyThatCatalog() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI]))

        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests().map(\.route).sorted() == ["catalog:openAI", "index"])
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .openAI))
        #expect(!client.syncSnapshotConfirmedThisSession(providerKind: .anthropic))

        // Not found in the loaded openAI catalog is a real miss: not pending, and no request.
        SplitMetadataMockURLProtocol.clearRequests()
        #expect(client.resolveCatalogModel(modelID: "gpt-not-in-catalog", providerKind: .openAI) == nil)
        #expect(!client.syncIsCatalogPending(providerKind: .openAI))
        #expect(!client.syncIsCatalogPending(providerKind: .relay))

        // The anthropic catalog is not loaded: the resolver must not mark models manual or report zero
        // available models.
        let anthropicModelID = try #require(try catalogModelIDs(corpus, "anthropic").first)
        let indexProviders = try #require(try indexData(corpus)["providers"] as? [String: Any])
        let anthropicIndex = try #require(indexProviders["anthropic"] as? [String: Any])
        #expect(client.resolveCatalogModel(modelID: anthropicModelID, providerKind: .anthropic) == nil)
        #expect(
            client.syncProviderDisplayName(providerKind: .anthropic) == anthropicIndex["displayName"] as? String,
            "provider-level fields come from the index and are available before the catalog"
        )
        let enabled = TestFactories.makeModel(id: anthropicModelID, capabilities: [.text])
        let anthropic = TestFactories.makeProvider(kind: .anthropic, models: [enabled])
        let pendingCatalog = ProviderCatalogResolver.resolve(provider: anthropic, metadata: client)
        #expect(pendingCatalog.catalogPending)
        #expect(pendingCatalog.enabledModels.map(\.model.id) == [anthropicModelID])
        #expect(pendingCatalog.enabledModels.allSatisfy { !$0.isManual })

        // The triggered fetch targets anthropic only: no index refetch, openAI untouched.
        await client.waitForBackgroundWorkForTesting()
        #expect(SplitMetadataMockURLProtocol.requests() == [.init(route: "catalog:anthropic", ifNoneMatch: nil)])
        #expect(!client.syncIsCatalogPending(providerKind: .anthropic))
        #expect(client.resolveCatalogModel(modelID: anthropicModelID, providerKind: .anthropic) != nil)
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .anthropic))
        #expect(!ProviderCatalogResolver.resolve(provider: anthropic, metadata: client).catalogPending)
        await client.resetForTesting()
    }

    @Test("negative unresolvedRef: the whole catalog is rejected, last-good stays and a diagnostic is reported")
    func unresolvedRefRejectsWholeCatalogAndKeepsLastGood() async throws {
        let corpus = try catalogCorpus()
        let negative = try #require(corpus["negativeCases"] as? [String: Any])
        let unresolved = try #require((negative["unresolvedRef"] as? [String: Any])?["catalog"] as? [String: Any])
        let recorder = CatalogDiagnosticRecorder()
        let client = makeClient(recorder: recorder)
        await client.resetForTesting()

        // last-good: the previous openAI catalog (its revision differs from the index, so a new one is fetched).
        let indexObject = try indexData(corpus)
        let catalogs = try #require(corpus["catalogResponses"] as? [String: Any])
        let openAIData = try dataObject(catalogs["openAI"])
        try await client.loadSplitForTesting(
            indexJSON: try jsonText(try index(indexObject, revision: "sha256:last-good", for: "openAI")),
            indexETag: "index-etag-0",
            catalogJSONs: ["openAI": try jsonText(catalog(openAIData, revision: "sha256:last-good"))]
        )
        client.registerConfiguredProviders(providers([.openAI]))
        SplitMetadataMockURLProtocol.reset()
        SplitMetadataMockURLProtocol.stub("index", try ok(rewrapped(indexObject), etag: "index-etag-1"))
        SplitMetadataMockURLProtocol.stub("catalog:openAI", try ok(rewrapped(unresolved), etag: "catalog-etag-bad"))

        await client.forceRefresh()

        #expect(SplitMetadataMockURLProtocol.requests().map(\.route) == ["index", "catalog:openAI"])
        // Only some refs in the bad catalog are unresolved, yet none of it may be adopted: every model still
        // looks like last-good.
        let lastGoodControls = try #require((openAIData["tables"] as? [String: Any])?["capabilityControls"] as? [String: [String: Any]])
        let lastGoodModels = try #require(openAIData["models"] as? [String: [String: Any]])
        for (modelID, entry) in lastGoodModels {
            let lastGood = try #require(client.resolveCatalogModel(modelID: modelID, providerKind: .openAI))
            #expect(lastGood.generationProfile?.parameters?.isEmpty == false)
            let controlsRef = try #require(entry["capabilityControlsRef"] as? String)
            let expected = try #require(lastGoodControls[controlsRef])
            #expect(Set(client.syncCapabilityRecipeRuntime(modelID: modelID, providerKind: .openAI)
                .controls?.keys.map { $0 } ?? []) == Set(expected.keys))
        }
        #expect(!client.syncIsCatalogPending(providerKind: .openAI), "last-good is still there, so this is not pending")
        #expect(!client.syncSnapshotConfirmedThisSession(providerKind: .openAI), "last-good does not match the current index and is not confirmed")
        let diagnostics = recorder.snapshot()
        #expect(diagnostics.map(\.tags) == [["operation": "catalog_unresolved_ref", "provider": "openAI"]])
        #expect(try await client.splitCacheRowsForTesting()["catalog:openAI"] == nil, "a rejected catalog is never persisted")
        await client.resetForTesting()
    }

    @Test("negative revisionMismatch: refetch the index once, then keep last-good and report a diagnostic")
    func revisionMismatchRefetchesIndexOnceThenKeepsLastGood() async throws {
        let corpus = try catalogCorpus()
        let negative = try #require(corpus["negativeCases"] as? [String: Any])
        let mismatch = try #require(negative["revisionMismatch"] as? [String: Any])
        let staleRevision = try #require(mismatch["indexCatalogRevision"] as? String)
        let recorder = CatalogDiagnosticRecorder()
        let client = makeClient(recorder: recorder)
        await client.resetForTesting()

        let indexObject = try indexData(corpus)
        let catalogs = try #require(corpus["catalogResponses"] as? [String: Any])
        let openAIData = try dataObject(catalogs["openAI"])
        try await client.loadSplitForTesting(
            indexJSON: try jsonText(try index(indexObject, revision: "sha256:last-good", for: "openAI")),
            indexETag: "index-etag-0",
            catalogJSONs: ["openAI": try jsonText(catalog(openAIData, revision: "sha256:last-good"))]
        )
        client.registerConfiguredProviders(providers([.openAI]))
        SplitMetadataMockURLProtocol.reset()
        SplitMetadataMockURLProtocol.stub(
            "index",
            try ok(rewrapped(try index(indexObject, revision: staleRevision, for: "openAI")), etag: "index-etag-stale")
        )
        SplitMetadataMockURLProtocol.stub("catalog:openAI", try ok(try #require(catalogs["openAI"]), etag: "catalog-etag-openAI"))

        await client.forceRefresh()

        #expect(SplitMetadataMockURLProtocol.requests().map(\.route)
            == ["index", "catalog:openAI", "index", "catalog:openAI"])
        for modelID in try catalogModelIDs(corpus, "openAI") {
            #expect(client.resolveCatalogModel(modelID: modelID, providerKind: .openAI) != nil)
        }
        #expect(!client.syncSnapshotConfirmedThisSession(providerKind: .openAI))
        #expect(recorder.snapshot().map(\.tags) == [["operation": "catalog_revision_mismatch", "provider": "openAI"]])
        await client.resetForTesting()
    }

    @Test("404 is never an empty catalog: a listed provider answering 404 stays pending; unlisted providers are not requested")
    func notFoundIsNeverAnEmptyCatalog() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        SplitMetadataMockURLProtocol.stub("catalog:anthropic", status(404))
        client.registerConfiguredProviders(providers([.openAI, .anthropic, .deepseek]))

        await client.forceRefresh()

        let routes = SplitMetadataMockURLProtocol.requests().map(\.route)
        #expect(!routes.contains("catalog:deepseek"), "a provider missing from the index is not pending and is not requested")
        // Listed by the index yet 404 is treated as a snapshot rollover: refetch the index and retry once,
        // then stop.
        #expect(routes.filter { $0 == "catalog:anthropic" }.count == 2)
        #expect(routes.filter { $0 == "index" }.count == 2)
        #expect(!client.syncIsCatalogPending(providerKind: .deepseek))
        #expect(client.syncIsCatalogPending(providerKind: .anthropic), "a 404 must not count as a verified empty catalog")
        let anthropicModelID = try #require(try catalogModelIDs(corpus, "anthropic").first)
        let enabled = TestFactories.makeModel(id: anthropicModelID, capabilities: [.text])
        let resolved = ProviderCatalogResolver.resolve(
            provider: TestFactories.makeProvider(kind: .anthropic, models: [enabled]),
            metadata: client
        )
        #expect(resolved.catalogPending)
        #expect(resolved.enabledModels.map(\.model.id) == [anthropicModelID])
        await client.waitForBackgroundWorkForTesting()
        await client.resetForTesting()
    }

    @Test("an older server answering index with 400 falls back to lean, and later refreshes use conditional lean requests")
    func indexBadRequestFallsBackToLean() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        SplitMetadataMockURLProtocol.reset()
        SplitMetadataMockURLProtocol.stub("index", status(400))
        SplitMetadataMockURLProtocol.stub("lean", try ok(rewrapped(try leanEquivalentData(corpus)), etag: "lean-etag"))
        client.registerConfiguredProviders(providers([.openAI]))

        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests().map(\.route) == ["index", "lean"])
        #expect(client.syncMetadataETag() == "lean-etag")
        let anthropicModelID = try #require(try catalogModelIDs(corpus, "anthropic").first)
        #expect(client.resolveCatalogModel(modelID: anthropicModelID, providerKind: .anthropic) != nil)
        #expect(!client.syncIsCatalogPending(providerKind: .anthropic))
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .anthropic))

        SplitMetadataMockURLProtocol.clearRequests()
        SplitMetadataMockURLProtocol.stub("lean", status(304))
        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests() == [.init(route: "lean", ifNoneMatch: "lean-etag")])
        await client.resetForTesting()
    }

    @Test("the old single-row lean cache reads as a compatibility snapshot and migrates on the first split commit; an unreadable one is dropped")
    func legacyLeanCacheMigratesToSplit() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI]))

        var lean = try leanEquivalentData(corpus)
        lean["modelFacts"] = ["openAI/gpt-legacy": ["toolCall": true]]
        lean["modelFactsRevision"] = "sha256:facts-legacy"
        let leanJSON = try jsonText(lean)
        try await client.writePersistedCacheForTesting(
            payload: leanJSON, version: 1, contractVersion: 1, etag: "lean-etag"
        )
        await client.markPersistedCacheAsCurrentFormatForTesting()

        await client.initialize()
        await client.waitForBackgroundWorkForTesting()

        #expect(SplitMetadataMockURLProtocol.requests().map(\.route).sorted() == ["catalog:openAI", "index"])
        #expect(try await client.readPersistedCacheForTesting() == nil, "the old single-row cache is cleared on the first split commit")
        let rows = try await client.splitCacheRowsForTesting()
        #expect(Set(rows.keys) == ["index", "catalog:openAI", "modelFacts"])
        #expect(client.syncMetadataETag() == "index-etag-1")
        // Providers the old snapshot had but nobody needs are not kept as last-good: they are pending and
        // fetched on demand.
        #expect(client.syncIsCatalogPending(providerKind: .anthropic))
        #expect(client.syncModelFacts(providerKind: .openAI, modelID: "gpt-legacy")?.toolCall == true, "model facts migrate into split mode")
        await client.waitForBackgroundWorkForTesting()

        // An unreadable old cache is dropped and fetched cold without blocking startup.
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI]))
        try await client.writePersistedCacheForTesting(
            payload: "{not json", version: 1, contractVersion: 1, etag: "lean-etag"
        )
        await client.initialize()
        let openAIModelID = try #require(try catalogModelIDs(corpus, "openAI").first)
        #expect(client.resolveCatalogModel(modelID: openAIModelID, providerKind: .openAI) != nil)
        await client.resetForTesting()
    }

    @Test("models.dev tool_call evidence (server_typed + declared) takes effect through production decoding and the facade; observed is still dropped")
    func declaredServerTypedEvidenceReachesFacade() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI, .anthropic]))
        await client.forceRefresh()

        func declared(_ support: String) -> ([String: Any]) -> Bool {
            { $0["key"] as? String == "tool_call"
                && $0["source"] as? String == "server_typed"
                && $0["grade"] as? String == "declared"
                && $0["support"] as? String == support }
        }
        let cases: [(kind: String, providerKind: ProviderKind, support: CapabilityEvidenceFacade.Support, policy: CapabilityEvidenceFacade.RequestPolicy)] = [
            ("anthropic", .anthropic, .supported, .allow),
            ("openAI", .openAI, .unsupported, .omitUnsupported),
        ]
        for item in cases {
            let match = try #require(
                try corpusEvidence(corpus, kind: item.kind, where: declared(item.support.rawValue)).first,
                "the corpus should contain declared + \(item.support.rawValue) tool_call evidence for \(item.kind)"
            )
            let observedAt = try #require((match.candidate["observedAt"] as? NSNumber)?.int64Value)
            let expiresAt = try #require((match.candidate["expiresAt"] as? NSNumber)?.int64Value)
            let resolved = try #require(client.resolveCatalogModel(modelID: match.modelID, providerKind: item.providerKind))
            let transport = try #require(resolved.transport)
            // Pin the clock inside the evidence validity window: corpus evidence expires about a week after
            // capture, so reading the real clock would make this test fail by calendar date.
            let now = observedAt + (expiresAt - observedAt) / 2
            let resolution = CapabilityEvidenceFacade.resolve(
                key: "tool_call",
                query: CapabilityEvidenceFacade.Query(
                    partitionID: "partition",
                    connectionInstanceID: "connection",
                    connectionGeneration: "generation",
                    credentialEpoch: "credential",
                    providerKind: item.providerKind.rawValue,
                    modelID: match.modelID,
                    effectiveTransport: transport,
                    metadataRevision: client.syncMetadataETag(),
                    now: now,
                    hasExplicitValue: false
                ),
                candidates: resolved.capabilityEvidenceCandidates
            )
            #expect(resolution.support == item.support, "\(item.kind)/\(match.modelID)")
            #expect(resolution.source == .serverTyped)
            #expect(resolution.grade == .declared)
            #expect(resolution.requestPolicy == item.policy)
        }

        // Negative: server_typed + observed is not a public evidence shape; the namespace still records the
        // key as owned, but the candidate is dropped.
        let anthropicMatch = try #require(try corpusEvidence(corpus, kind: "anthropic", where: declared("supported")).first)
        var anthropic = try catalogData(corpus, "anthropic")
        var tables = try #require(anthropic["tables"] as? [String: Any])
        var evidence = try #require(tables["capabilityEvidence"] as? [String: [String: Any]])
        let models = try #require(anthropic["models"] as? [String: [String: Any]])
        let ref = try #require(models[anthropicMatch.modelID]?["capabilityEvidenceRef"] as? String)
        var namespace = try #require(evidence[ref])
        var candidates = try #require(namespace["candidates"] as? [[String: Any]])
        candidates = candidates.map { candidate in
            var candidate = candidate
            if candidate["key"] as? String == "tool_call" { candidate["grade"] = "observed" }
            return candidate
        }
        namespace["candidates"] = candidates
        evidence[ref] = namespace
        tables["capabilityEvidence"] = evidence
        anthropic["tables"] = tables
        await client.resetForTesting()
        try stubServer(corpus)
        SplitMetadataMockURLProtocol.stub("catalog:anthropic", try ok(rewrapped(anthropic), etag: "catalog-etag-observed"))
        client.registerConfiguredProviders(providers([.anthropic]))
        await client.forceRefresh()
        let observed = try #require(client.resolveCatalogModel(modelID: anthropicMatch.modelID, providerKind: .anthropic))
        #expect(observed.capabilityEvidenceOwnedKeys.contains("tool_call"))
        #expect(!observed.capabilityEvidenceCandidates.contains { $0.key == "tool_call" })
        await client.resetForTesting()
    }

    @Test("forceRefresh(providerKinds:) sends a conditional index request and fetches only the named catalog")
    func forceRefreshWithProviderKindsIsConditional() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()
        try stubServer(corpus)
        client.registerConfiguredProviders(providers([.openAI]))
        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests().map(\.route).sorted() == ["catalog:openAI", "index"])

        // A provider being added is not configured yet: naming it fetches its catalog, and the index
        // request carries the stored validator instead of bypassing it.
        SplitMetadataMockURLProtocol.stub("index", status(304))
        SplitMetadataMockURLProtocol.clearRequests()
        await client.forceRefresh(providerKinds: [.anthropic])
        #expect(SplitMetadataMockURLProtocol.requests() == [
            .init(route: "index", ifNoneMatch: "index-etag-1"),
            .init(route: "catalog:anthropic", ifNoneMatch: nil),
        ])
        #expect(!client.syncIsCatalogPending(providerKind: .anthropic))
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .anthropic))

        // Both catalogs now match the index: another forced refresh costs one index 304 and nothing else.
        SplitMetadataMockURLProtocol.clearRequests()
        await client.forceRefresh(providerKinds: [.anthropic])
        #expect(SplitMetadataMockURLProtocol.requests() == [.init(route: "index", ifNoneMatch: "index-etag-1")])
        await client.resetForTesting()
    }

    @Test("a relay needs only whitelisted official catalogs, and a relay lookup fetches only unloaded whitelisted ones")
    func relayUsesOnlyTheOfficialProviderWhitelist() async throws {
        let corpus = try catalogCorpus()
        let client = makeClient()
        await client.resetForTesting()

        // Narrow the whitelist to openAI so the anthropic catalog is outside the relay's scope.
        var indexObject = try indexData(corpus)
        var relayConfig = try #require(indexObject["relayRuntimeConfig"] as? [String: Any])
        relayConfig["officialProviderWhitelist"] = ["openAI"]
        indexObject["relayRuntimeConfig"] = relayConfig
        try stubServer(corpus)
        SplitMetadataMockURLProtocol.stub("index", try ok(rewrapped(indexObject), etag: "index-etag-relay"))
        client.registerConfiguredProviders(providers([.relay]))

        await client.forceRefresh()
        #expect(SplitMetadataMockURLProtocol.requests().map(\.route).sorted() == ["catalog:openAI", "index"])

        // A relay model that only exists in the anthropic catalog: not whitelisted, so it is not matched
        // and must not pull that catalog in.
        let anthropicModelID = try #require(try catalogModelIDs(corpus, "anthropic").first {
            !(try catalogModelIDs(corpus, "openAI")).contains($0)
        })
        SplitMetadataMockURLProtocol.clearRequests()
        #expect(client.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: anthropicModelID) == nil)
        await client.waitForBackgroundWorkForTesting()
        #expect(SplitMetadataMockURLProtocol.requests().isEmpty)

        // With the full whitelist, an unloaded whitelisted catalog is fetched on a relay miss, alone.
        await client.resetForTesting()
        try stubServer(corpus)
        SplitMetadataMockURLProtocol.stub("catalog:anthropic", status(500))
        client.registerConfiguredProviders(providers([.relay]))
        await client.forceRefresh()
        SplitMetadataMockURLProtocol.stub("catalog:anthropic", try ok(
            try #require((corpus["catalogResponses"] as? [String: Any])?["anthropic"]),
            etag: "catalog-etag-anthropic"
        ))
        SplitMetadataMockURLProtocol.clearRequests()
        #expect(client.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: anthropicModelID) == nil)
        await client.waitForBackgroundWorkForTesting()
        #expect(SplitMetadataMockURLProtocol.requests() == [.init(route: "catalog:anthropic", ifNoneMatch: nil)])
        let match = try #require(client.syncResolveCatalogModelAcrossProvidersWithProvider(modelID: anthropicModelID))
        #expect(match.matchedProviderKind == .anthropic)
        await client.resetForTesting()
    }

    @Test("GRDB v28 creates metadata_split_cache and an upgraded database keeps its metadata_cache row")
    func splitCacheMigrationPreservesLegacyRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-split-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oriveo.sqlite").path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let files = AttachmentFileStore(rootDirectory: directory.appendingPathComponent("Files", isDirectory: true))
        let migrator = DatabaseSchema.makeMigrator(attachmentFileStore: files)

        try migrator.migrate(pool, upTo: "v27_conversation_deletion_journal")
        try pool.write { db in
            #expect(try !db.tableExists("metadata_split_cache"))
            try db.execute(
                sql: "INSERT INTO metadata_cache (id, payload, version, contractVersion, etag, updatedAt) VALUES (1, ?, 1, 1, ?, 0)",
                arguments: [#"{"version":1,"view":"lean","providers":{}}"#, "lean-etag"]
            )
        }

        try migrator.migrate(pool)
        try pool.write { db in
            #expect(try db.tableExists("metadata_split_cache"))
            #expect(try String.fetchOne(db, sql: "SELECT etag FROM metadata_cache WHERE id = 1") == "lean-etag")
            try db.execute(
                sql: "INSERT INTO metadata_split_cache (key, payload, revision, etag, updatedAt) VALUES ('catalog:openAI', '{}', 'sha256:r', 'e', 1)"
            )
            #expect(try Int.fetchOne(db, sql: "SELECT contractVersion FROM metadata_split_cache WHERE key = 'catalog:openAI'") == 0)
        }
    }
}
