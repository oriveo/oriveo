import Foundation
import Testing
@testable import Oriveo

private final class ModelFactsMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    private static let lock = NSLock()
    private static var stub = Stub(statusCode: 304, headers: [:], data: Data())

    static func configure(_ value: Stub) {
        lock.lock()
        stub = value
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelFactsMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responseStub = Self.stub
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

@Suite("Model picker intent index key", .serialized)
struct ModelPickerIntentIndexKeyTests {

    /// Model facts merged or withdrawn while the picker is open: the intent index used by the chip
    /// filter must be invalidated, and once rebuilt it must match the per-row badges.
    @Test("merging and withdrawing model facts advances the capability signal and invalidates the picker intent index (304 does not)")
    func modelFactsChangesInvalidatePickerIntentIndex() async throws {
        let response = try JSONSerialization.data(
            withJSONObject: try #require(try Self.metadataLeanFixture()["modelFactsResponse"])
        )
        let client = MetadataClient(
            session: ModelFactsMockURLProtocol.session(),
            allowsNetworkRequestsInTests: true
        )
        await client.resetForTesting()
        try await client.loadForTesting(
            json: #"{"version":2,"view":"lean","providers":{}}"#,
            metadataETag: "metadata-etag"
        )

        // Reasoning levels on a subscription connection come only from model facts, so a new facts
        // table means new badges.
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
        #expect(before.index[rowKey]?.contains(.reasoning) == false, "Reasoning must not light up without a facts table")

        ModelFactsMockURLProtocol.configure(.init(
            statusCode: 200, headers: ["Etag": "facts-etag-1"], data: response
        ))
        await client.refreshModelFacts()
        let merged = await snapshot()
        #expect(merged.key.revision != before.key.revision, "Merging model facts must advance the capability evidence signal")
        #expect(merged.key != before.key)
        #expect(merged.live.contains(.reasoning), "After the merge the row badge should show reasoning, or this test cannot see the divergence")
        #expect(merged.index[rowKey] == merged.live)
        #expect(before.index[rowKey] != merged.live, "The old index really disagrees with the new badges, so an unchanged key would keep using it")

        ModelFactsMockURLProtocol.configure(.init(statusCode: 304, headers: [:], data: Data()))
        await client.refreshModelFacts()
        let notModified = await snapshot()
        #expect(notModified.key == merged.key, "A 304 changes nothing and must not rebuild the index")

        ModelFactsMockURLProtocol.configure(.init(statusCode: 404, headers: [:], data: Data()))
        await client.refreshModelFacts()
        let withdrawn = await snapshot()
        #expect(withdrawn.key.revision != merged.key.revision, "Withdrawing model facts must advance the signal as well")
        #expect(withdrawn.key != merged.key)
        #expect(withdrawn.index[rowKey] == withdrawn.live)
        #expect(withdrawn.live.contains(.reasoning) == false)
        await client.resetForTesting()
    }

    private static func metadataLeanFixture() throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent("shared/model-contracts/metadata_lean_contract.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
