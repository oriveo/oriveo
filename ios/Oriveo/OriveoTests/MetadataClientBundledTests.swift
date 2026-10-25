import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Metadata mock routed by query; routes without a stub always return 500.
private final class BundledMetadataMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]

    static func reset() {
        lock.lock()
        stubs = [:]
        lock.unlock()
    }

    static func stub(_ route: String, _ stub: Stub) {
        lock.lock()
        stubs[route] = stub
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BundledMetadataMockURLProtocol.self]
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
        let stub = Self.stubs[route] ?? Stub(statusCode: 500, headers: [:], data: Data())
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

/// Provider keys of the 15 built-in providers in the backend metadata.
private let officialMetadataKinds: Set<String> = [
    "anthropic", "deepseek", "fireworksAI", "gemini", "grok", "groq", "miniMax", "mistral",
    "moonshot", "openAI", "openRouter", "qwen", "siliconFlow", "togetherAI", "zhipu",
]

private func repoFile(_ relativePath: String) throws -> URL {
    var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        folder.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func bundledResource(_ name: String, _ ext: String) throws -> URL {
    try #require(
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "BundledMetadata")
    )
}

private func bundledSnapshotBody() throws -> [String: Any] {
    let compressed = try Data(contentsOf: try bundledResource("bundled-metadata.v2.json", "gz"))
    let data = try GzipData.gunzip(compressed)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func ok(_ object: Any, etag: String) throws -> BundledMetadataMockURLProtocol.Stub {
    .init(statusCode: 200, headers: ["Etag": etag], data: try jsonData(object))
}

@Suite("MetadataClient bundled snapshot", .serialized, .sharedProcessState)
struct MetadataClientBundledTests {

    private func makeClient(schema: Int) -> MetadataClient {
        MetadataClient(
            session: BundledMetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, _ in },
            requestedMetadataSchema: schema
        )
    }

    @Test("Bundled snapshot is byte-identical to the shared model-contracts file of the same name")
    func bundledSnapshotMatchesSharedContract() throws {
        let bundled = try Data(contentsOf: try bundledResource("bundled-metadata.v2.json", "gz"))
        let shared = try Data(contentsOf: try repoFile("shared/model-contracts/bundled-metadata.v2.json.gz"))
        #expect(!bundled.isEmpty)
        #expect(bundled == shared)
    }

    @Test("Decompressed bundled snapshot contains the 15 built-in providers and has 0 fullOrIndex validation errors")
    func bundledSnapshotValidatesAgainstSchema() throws {
        let body = try bundledSnapshotBody()
        let providers = try #require(body["providers"] as? [String: Any])
        #expect(officialMetadataKinds.isSubset(of: Set(providers.keys)))
        #expect(body["metadataSchema"] as? Int == 2)
        #expect(body["metadataRevision"] as? Int == 0)
        let schema = try Data(contentsOf: try bundledResource("metadata_payload.v2.schema", "json"))
        let validator = try MetadataPayloadSchemaValidator(schemaData: schema)
        #expect(validator.validate(body, def: "fullOrIndex").isEmpty)
    }

    @Test("No cache + transport failure + schema 2 request: adopts the bundled snapshot without persisting to GRDB; a later online success replaces it")
    func coldStartFallsBackToBundledSnapshotThenOnlineReplaces() async throws {
        let body = try bundledSnapshotBody()
        let providers = try #require(body["providers"] as? [String: [String: Any]])
        let bundledDeepseekModels = try #require(providers["deepseek"]?["models"] as? [String: Any]).keys.sorted()
        #expect(!bundledDeepseekModels.isEmpty)

        let client = makeClient(schema: 2)
        await client.resetForTesting()
        BundledMetadataMockURLProtocol.reset()

        await client.initialize()
        #expect(await client.servingBundledSnapshotForTesting())
        // Assertions come from the snapshot decoded by production code: the deepseek model set matches the bundled file.
        // A non-shared instance only writes its own state, so read it from the actor side.
        #expect(await client.instanceProviderModelIDsForTesting(providerKind: .deepseek) == bundledDeepseekModels)
        #expect(await client.providerAttachmentSupport(providerKind: .openAI) != nil)
        #expect(client.syncMetadataETag() == nil)
        #expect(!client.syncSnapshotConfirmedThisSession(providerKind: .openAI))
        #expect(await client.grdbPersistCountSnapshotForTesting() == 0)
        #expect(await client.splitBodyWriteCountSnapshotForTesting() == 0)
        #expect(try await client.splitCacheRowsForTesting().isEmpty)

        // Transport recovers: the online index + catalogs replace the bundled snapshot, and providers only present in it do not linger.
        let corpus = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try repoFile("shared/model-contracts/metadata_catalog_contract.v1.json"))
        ) as? [String: Any]
        let corpusObject = try #require(corpus)
        BundledMetadataMockURLProtocol.stub("index", try ok(try #require(corpusObject["indexResponse"]), etag: "index-etag-1"))
        let catalogs = try #require(corpusObject["catalogResponses"] as? [String: [String: Any]])
        for kind in ["openAI", "anthropic"] {
            BundledMetadataMockURLProtocol.stub("catalog:\(kind)", try ok(try #require(catalogs[kind]), etag: "catalog-etag-\(kind)"))
        }
        client.registerConfiguredProviders([.openAI, .anthropic].map { TestFactories.makeProvider(kind: $0, models: []) })
        await client.forceRefresh()

        let openAIModels = try #require(
            (catalogs["openAI"]?["data"] as? [String: Any])?["models"] as? [String: Any]
        ).keys.sorted()
        #expect(!(await client.servingBundledSnapshotForTesting()))
        #expect(client.providerModelIDs(providerKind: .openAI) == openAIModels)
        #expect(client.providerModelIDs(providerKind: .deepseek).isEmpty)
        #expect(client.syncMetadataETag() == "index-etag-1")
        #expect(client.syncSnapshotConfirmedThisSession(providerKind: .openAI))
        await client.resetForTesting()
    }

    @Test("Non-shared instance adopts the bundled snapshot: it resolves models locally and MetadataClient.shared is not written")
    func nonSharedInstanceAdoptsBundledSnapshotWithoutWritingShared() async throws {
        let body = try bundledSnapshotBody()
        let providers = try #require(body["providers"] as? [String: [String: Any]])
        let bundledDeepseekModels = try #require(providers["deepseek"]?["models"] as? [String: Any]).keys.sorted()
        #expect(!bundledDeepseekModels.isEmpty)

        let client = makeClient(schema: 2)
        #expect(client !== MetadataClient.shared)
        await client.resetForTesting()
        BundledMetadataMockURLProtocol.reset()

        await client.initialize()
        #expect(await client.servingBundledSnapshotForTesting())
        #expect(await client.instanceProviderModelIDsForTesting(providerKind: .deepseek) == bundledDeepseekModels)
        #expect(await client.providerAttachmentSupport(providerKind: .openAI) != nil)
        // The bundled snapshot was not installed into the shared snapshot.
        #expect(MetadataClient.shared.providerModelIDs(providerKind: .deepseek) != bundledDeepseekModels)
        #expect(MetadataClient.shared.syncProviderAttachmentSupport(providerKind: .openAI) == nil)
        await client.resetForTesting()
    }

    @Test("Schema 1 request: the bundled snapshot is not used when there is no cache and transport fails")
    func schemaOneNeverUsesBundledSnapshot() async throws {
        let client = makeClient(schema: 1)
        await client.resetForTesting()
        BundledMetadataMockURLProtocol.reset()

        await client.initialize()
        #expect(!(await client.servingBundledSnapshotForTesting()))
        #expect(client.providerModelIDs(providerKind: .deepseek).isEmpty)
        #expect(client.syncProviderAttachmentSupport(providerKind: .openAI) == nil)
        await client.resetForTesting()
    }

    @Test("Without metadata every ProviderKind reports all four attachment flags as false (the fallback table is gone; entry gating lives in the facade)")
    func officialKindsClaimNoAttachmentsWithoutMetadata() async {
        await MetadataClient.shared.resetForTesting()
        for kind in ProviderKind.allCases {
            let support = kind.attachmentSupport
            #expect(!support.image, "\(kind.rawValue)")
            #expect(!support.video, "\(kind.rawValue)")
            #expect(!support.nativeFile, "\(kind.rawValue)")
            #expect(!support.textFileInline, "\(kind.rawValue)")
        }
        #expect(ProviderKind.allCases.count == 16)
    }

    @Test("One bad model in the bundled snapshot: only that entry is dropped (its alias is pruned too), the rest stay usable")
    func bundledSnapshotDropsOnlyBadModel() throws {
        var body = try bundledSnapshotBody()
        var providers = try #require(body["providers"] as? [String: Any])
        var deepseek = try #require(providers["deepseek"] as? [String: Any])
        var models = try #require(deepseek["models"] as? [String: Any])
        let original = models.keys.sorted()
        models["m-bad"] = ["displayName": "x", "supportsTemperature": "yes"]
        deepseek["models"] = models
        var resolveMap = deepseek["resolveMap"] as? [String: Any] ?? [:]
        resolveMap["alias-bad"] = "m-bad"
        deepseek["resolveMap"] = resolveMap
        providers["deepseek"] = deepseek
        body["providers"] = providers
        let schema = try Data(contentsOf: try bundledResource("metadata_payload.v2.schema", "json"))

        let outcome = try #require(MetadataClient.bundledSnapshotModelIDsForTesting(try jsonData(body), schemaData: schema))
        #expect(outcome["deepseek"] == original)
        #expect(officialMetadataKinds.isSubset(of: Set(outcome.keys)))
        let pristine = try #require(MetadataClient.bundledSnapshotModelIDsForTesting(
            try jsonData(try bundledSnapshotBody()), schemaData: schema
        ))
        #expect(outcome == pristine)
    }
}
