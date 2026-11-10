import Foundation
import Testing
@testable import Oriveo

/// Routes metadata requests by query (index / catalog:<kind> / lean / facts); unknown routes get 404.
private final class ImageProfileMetadataMockURLProtocol: URLProtocol, @unchecked Sendable {
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
        configuration.protocolClasses = [ImageProfileMetadataMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func route(for url: URL) -> String {
        if url.path.hasSuffix("/model-facts") { return "facts" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch items.first(where: { $0.name == "view" })?.value {
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

private func repoFile(_ components: [String]) throws -> URL {
    var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while true {
        let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    throw CocoaError(.fileNoSuchFile)
}

/// Shared corpus generated from Server output; no end builds its own.
private func catalogCorpus() throws -> [String: Any] {
    let url = try repoFile(["shared", "model-contracts", "metadata_catalog_contract.v1.json"])
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jsonText(_ object: Any) throws -> String {
    try #require(String(data: try jsonData(object), encoding: .utf8))
}

private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return NSDictionary(dictionary: ["v": lhs]).isEqual(NSDictionary(dictionary: ["v": rhs]))
}

/// The `data` part of a `{code,data,message}` envelope.
private func dataObject(_ wrapped: Any?) throws -> [String: Any] {
    let wrapped = try #require(wrapped as? [String: Any])
    return try #require(wrapped["data"] as? [String: Any])
}

private func rewrapped(_ data: [String: Any]) -> [String: Any] {
    ["code": 0, "data": data, "message": "ok"]
}

private func ok(_ data: [String: Any], etag: String) throws -> ImageProfileMetadataMockURLProtocol.Stub {
    var headers = ["Etag": etag]
    if let revision = data["catalogRevision"] as? String { headers["X-Metadata-Catalog-Revision"] = revision }
    return .init(statusCode: 200, headers: headers, data: try jsonData(rewrapped(data)))
}

private func schema3Section(_ corpus: [String: Any]) throws -> [String: Any] {
    try #require(corpus["schema3"] as? [String: Any])
}

private func schema3Index(_ corpus: [String: Any]) throws -> [String: Any] {
    try dataObject(try schema3Section(corpus)["indexResponse"])
}

private func schema3OpenRouterCatalog(_ corpus: [String: Any]) throws -> [String: Any] {
    let catalogs = try #require(try schema3Section(corpus)["catalogResponses"] as? [String: Any])
    return try dataObject(catalogs["openRouter"])
}

private func indexImageProfiles(_ corpus: [String: Any]) throws -> [String: Any] {
    let profiles = try #require(try schema3Index(corpus)["profiles"] as? [String: Any])
    return try #require(profiles["image"] as? [String: Any])
}

/// Metadata decode of imageProfile / imageProfileOverride / profiles.image / imageModels across the
/// lean, split and persisted paths, then the metadata -> slice adapter feeding the resolver.
@Suite("ImageProfileMetadataDecodeTests", .serialized, .sharedProcessState)
struct ImageProfileMetadataDecodeTests {
    private func makeClient() -> MetadataClient {
        MetadataClient(
            session: ImageProfileMetadataMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true,
            errorReporter: { _, _ in }
        )
    }

    private func openRouterProviders() -> [Provider] {
        [TestFactories.makeProvider(kind: .openRouter, models: [])]
    }

    private func stubSplitServer(index: [String: Any], openRouter: [String: Any]) throws {
        ImageProfileMetadataMockURLProtocol.reset()
        ImageProfileMetadataMockURLProtocol.stub("index", try ok(index, etag: "index-etag-1"))
        ImageProfileMetadataMockURLProtocol.stub("catalog:openRouter", try ok(openRouter, etag: "catalog-etag-openRouter"))
    }

    @Test("schema 3 index + openRouter catalog through the split path resolve imageModels; cold start keeps them")
    func splitSnapshotResolvesCatalogImageModels() async throws {
        let corpus = try catalogCorpus()
        let index = try schema3Index(corpus)
        let openRouter = try schema3OpenRouterCatalog(corpus)
        let imageModels = try #require(openRouter["imageModels"] as? [String: [String: Any]])
        #expect(imageModels["openai/gpt-image-2"]?["imageProfile"] as? String == "openrouter_gpt_images")
        let tableCount = try indexImageProfiles(corpus).count
        #expect(tableCount > 0)

        let client = makeClient()
        await client.resetForTesting()
        try stubSplitServer(index: index, openRouter: openRouter)
        client.registerConfiguredProviders(openRouterProviders())
        await client.forceRefresh()

        let slice = try #require(client.imageProfileSlice())
        #expect(slice.profiles?.image?.count == tableCount)
        let gptImage = ImageProfileResolver.resolve(slice, providerKind: "openRouter", modelId: "openai/gpt-image-2")
        #expect(gptImage.reason == nil)
        #expect(gptImage.profileRef == "openrouter_gpt_images")
        #expect(gptImage.profile?.route == .openrouterImages)
        for (modelID, entry) in imageModels {
            let resolved = ImageProfileResolver.resolve(slice, providerKind: "openRouter", modelId: modelID)
            #expect(resolved.profileRef == entry["imageProfile"] as? String, "\(modelID)")
        }

        // Cold start from the split cache rows only: the network now answers 404 for everything.
        ImageProfileMetadataMockURLProtocol.reset()
        let coldClient = makeClient()
        coldClient.registerConfiguredProviders(openRouterProviders())
        await coldClient.initialize()
        await coldClient.waitForBackgroundWorkForTesting()
        let coldSlice = try #require(coldClient.imageProfileSlice())
        #expect(coldSlice.profiles?.image?.count == tableCount)
        let cold = ImageProfileResolver.resolve(coldSlice, providerKind: "openRouter", modelId: "openai/gpt-image-2")
        #expect(cold.profileRef == "openrouter_gpt_images")
        #expect(cold.profile?.route == .openrouterImages)
        await client.resetForTesting()
    }

    @Test("imageProfile injected through catalog modelDefaults resolves for every catalog model")
    func modelDefaultsImageProfileResolvesEveryModel() async throws {
        let corpus = try catalogCorpus()
        var openRouter = try schema3OpenRouterCatalog(corpus)
        var defaults = openRouter["modelDefaults"] as? [String: Any] ?? [:]
        defaults["imageProfile"] = "openrouter_gpt_images"
        openRouter["modelDefaults"] = defaults
        let modelIDs = try #require(openRouter["models"] as? [String: Any]).keys.sorted()
        #expect(!modelIDs.isEmpty)

        let client = makeClient()
        await client.resetForTesting()
        try stubSplitServer(index: try schema3Index(corpus), openRouter: openRouter)
        client.registerConfiguredProviders(openRouterProviders())
        await client.forceRefresh()

        #expect(client.providerModelIDs(providerKind: .openRouter) == modelIDs)
        let slice = try #require(client.imageProfileSlice())
        for modelID in modelIDs {
            let resolved = ImageProfileResolver.resolve(slice, providerKind: "openRouter", modelId: modelID)
            #expect(resolved.reason == nil, "\(modelID)")
            #expect(resolved.profileRef == "openrouter_gpt_images", "\(modelID)")
        }
        await client.resetForTesting()
    }

    @Test("lean model imageProfile + imageProfileOverride decode and merge through the adapter")
    func leanModelOverrideMerges() async throws {
        let corpus = try catalogCorpus()
        let table = try indexImageProfiles(corpus)
        let base = try #require(table["openai_gpt_image"] as? [String: Any])
        #expect(base["maxNPerCall"] as? Int != 3)

        var lean = try dataObject(corpus["leanEquivalent"])
        var profiles = lean["profiles"] as? [String: Any] ?? [:]
        profiles["image"] = table
        lean["profiles"] = profiles
        var providers = try #require(lean["providers"] as? [String: Any])
        var openAI = try #require(providers["openAI"] as? [String: Any])
        var models = try #require(openAI["models"] as? [String: Any])
        let modelID = try #require(models.keys.sorted().first)
        var model = try #require(models[modelID] as? [String: Any])
        model["imageProfile"] = "openai_gpt_image"
        model["imageProfileOverride"] = ["maxNPerCall": 3]
        models[modelID] = model
        openAI["models"] = models
        providers["openAI"] = openAI
        lean["providers"] = providers

        let client = makeClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: try jsonText(lean))
        let slice = try #require(client.imageProfileSlice())
        #expect(slice.profiles?.image?.count == table.count)
        let resolved = ImageProfileResolver.resolve(slice, providerKind: "openAI", modelId: modelID)
        #expect(resolved.reason == nil)
        #expect(resolved.profileRef == "openai_gpt_image")
        #expect(resolved.profile?.maxNPerCall == 3)
        #expect(resolved.appliedOverride.map { Array($0.keys) } == ["maxNPerCall"])
        await client.resetForTesting()
    }

    @Test("sanitized persisted lean snapshot keeps provider imageModels and they still resolve")
    func sanitizedPersistKeepsImageModels() async throws {
        let corpus = try catalogCorpus()
        var lean = try dataObject(corpus["leanEquivalent"])
        var profiles = lean["profiles"] as? [String: Any] ?? [:]
        profiles["image"] = try indexImageProfiles(corpus)
        lean["profiles"] = profiles
        let imageModels: [String: Any] = [
            "image-only-model": [
                "displayName": "Image Only",
                "imageProfile": "openai_gpt_image",
                "imageProfileOverride": ["maxNPerCall": 2],
            ],
        ]
        var providers = try #require(lean["providers"] as? [String: Any])
        var openAI = try #require(providers["openAI"] as? [String: Any])
        openAI["imageModels"] = imageModels
        providers["openAI"] = openAI
        lean["providers"] = providers

        let client = makeClient()
        await client.resetForTesting()
        let persisted = try await client.persistSanitizedCacheForTesting(json: try jsonText(lean), etag: "lean-etag-1")
        let payload = try #require(persisted.grdbPayload)
        let stored = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let storedOpenAI = (stored["providers"] as? [String: Any])?["openAI"] as? [String: Any]
        #expect(jsonEqual(storedOpenAI?["imageModels"], imageModels))

        try await client.loadForTesting(json: payload)
        let slice = try #require(client.imageProfileSlice())
        let resolved = ImageProfileResolver.resolve(slice, providerKind: "openAI", modelId: "image-only-model")
        #expect(resolved.reason == nil)
        #expect(resolved.profileRef == "openai_gpt_image")
        #expect(resolved.profile?.maxNPerCall == 2)
        #expect(slice.providers?["openAI"]?.imageModels?["image-only-model"]?.displayName == "Image Only")
        await client.resetForTesting()
    }

    @Test("malformed image fields never break decoding of the snapshot, other models or providers")
    func malformedImageFieldsStayIsolated() async throws {
        let corpus = try catalogCorpus()
        var lean = try dataObject(corpus["leanEquivalent"])
        var profiles = lean["profiles"] as? [String: Any] ?? [:]
        profiles["image"] = ["not", "an", "object"]
        lean["profiles"] = profiles
        var providers = try #require(lean["providers"] as? [String: Any])
        var expectedModelIDs: [String: [String]] = [:]
        for (kind, raw) in providers {
            let models = try #require((raw as? [String: Any])?["models"] as? [String: Any])
            expectedModelIDs[kind] = models.keys.sorted()
        }
        var openAI = try #require(providers["openAI"] as? [String: Any])
        var models = try #require(openAI["models"] as? [String: Any])
        let modelID = try #require(models.keys.sorted().first)
        var model = try #require(models[modelID] as? [String: Any])
        model["imageProfile"] = ["ref": "openai_gpt_image"]
        models[modelID] = model
        openAI["models"] = models
        openAI["imageModels"] = [
            "entry-not-object": "not-an-object",
            "image-only-model": ["displayName": "Image Only", "imageProfile": "openai_gpt_image"],
        ]
        providers["openAI"] = openAI
        lean["providers"] = providers

        let client = makeClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: try jsonText(lean))
        for (kind, modelIDs) in expectedModelIDs {
            let providerKind = try #require(ProviderKind(rawValue: kind), "\(kind)")
            #expect(client.providerModelIDs(providerKind: providerKind) == modelIDs, "\(kind)")
        }

        let slice = try #require(client.imageProfileSlice())
        #expect(slice.profiles?.image == nil)
        for (kind, modelIDs) in expectedModelIDs {
            #expect(slice.providers?[kind]?.models?.keys.sorted() == modelIDs, "\(kind)")
        }
        let objectRef = ImageProfileResolver.resolve(slice, providerKind: "openAI", modelId: modelID)
        #expect(objectRef.reason == .noImageProfile)
        let stringEntry = ImageProfileResolver.resolve(slice, providerKind: "openAI", modelId: "entry-not-object")
        #expect(stringEntry.reason == .noImageProfile)
        #expect(slice.providers?["openAI"]?.imageModels?["image-only-model"]?.displayName == "Image Only")
        let imageOnly = ImageProfileResolver.resolve(slice, providerKind: "openAI", modelId: "image-only-model")
        #expect(imageOnly.reason == .danglingProfile)
        await client.resetForTesting()
    }
}
