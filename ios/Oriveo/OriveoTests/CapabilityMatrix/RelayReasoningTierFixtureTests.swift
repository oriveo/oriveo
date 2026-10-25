import Foundation
import Testing
@testable import Oriveo

// Relay reasoning-tier fixture (shared/test-fixtures/relay/reasoning-tier.v1.json).
// Three sections run the production functions case by case; one more case resends within a send through the production `AppState.sendMessage` after a tier is rejected.

/// Replays upstream responses from a script and records every request body. Used by this file only.
private final class RelayTierScriptedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var script: [(status: Int, body: String)] = []
    nonisolated(unsafe) private static var _bodies: [[String: Any]] = []
    private static let lock = NSLock()

    static let responsesOK = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"ok"}

    event: response.completed
    data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}

    """

    static func reset(_ replies: [(Int, String)]) {
        lock.withLock {
            script = replies.map { ($0.0, $0.1) }
            _bodies = []
        }
    }

    static var bodies: [[String: Any]] { lock.withLock { _bodies } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayTierScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            buffer.deallocate()
            stream.close()
        }
        let next: (status: Int, body: String) = Self.lock.withLock {
            Self._bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            return Self.script.isEmpty ? (200, Self.responsesOK) : Self.script.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.invalid")!, statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": next.status == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Relay reasoning-tier fixture (RELAY-TIER)", .serialized, .sharedProcessState)
@MainActor
struct RelayReasoningTierFixtureTests {

    private static var retainedStates: [AppState] = []

    private static func repoFile(_ relative: String) throws -> Data {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return try Data(contentsOf: candidate) }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixture() throws -> [String: Any] {
        let data = try repoFile("shared/test-fixtures/relay/reasoning-tier.v1.json")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func cases(_ key: String) throws -> [[String: Any]] {
        try #require(try fixture()[key] as? [[String: Any]], "Fixture is missing \(key)")
    }

    private static func mode(_ raw: Any?) -> ReasoningMode? {
        (raw as? String).flatMap(ReasoningMode.init(rawValue:))
    }

    private static func modes(_ raw: Any?) -> [ReasoningMode] {
        ((raw as? [String]) ?? []).compactMap(ReasoningMode.init(rawValue:))
    }

    @Test("RELAY-TIER-effort: effortCases case by case (openai_style_four / three_without_max / none_and_max_dedupe / minimal_is_ignored / empty_is_no_tiers)")
    func RELAY_TIER_effort_cases() throws {
        let all = try Self.cases("effortCases")
        #expect(all.count == 5)
        for item in all {
            let caseId = item["caseId"] as? String ?? "?"
            let efforts = item["efforts"] as? [String] ?? []
            let expected = Self.modes(item["expect"])
            #expect(RelayReasoningTier.tiers(efforts: efforts) == expected, "RELAY-TIER-effort-\(caseId)")
        }
    }

    @Test("RELAY-TIER-classify: classifyCases case by case (9 cases, including 404 / 5xx / 401 / after output / no tier sent)")
    func RELAY_TIER_classify_cases() throws {
        let all = try Self.cases("classifyCases")
        #expect(all.count == 9)
        for item in all {
            let caseId = item["caseId"] as? String ?? "?"
            let got = RelayReasoningTier.classify(
                status: item["status"] as? Int ?? 0,
                body: item["body"] as? String ?? "",
                sentTier: Self.mode(item["sentTier"]),
                outputStarted: item["outputStarted"] as? Bool ?? false
            )
            #expect(got == Self.mode(item["expect"]), "RELAY-TIER-classify-\(caseId)")
        }
    }

    @Test("RELAY-TIER-fallback: fallbackCases case by case (step down first, then up, all rejected sends no reasoning, automatic passes through)")
    func RELAY_TIER_fallback_cases() throws {
        let all = try Self.cases("fallbackCases")
        #expect(all.count == 6)
        for item in all {
            let caseId = item["caseId"] as? String ?? "?"
            let selected = try #require(Self.mode(item["selected"]), "RELAY-TIER-fallback-\(caseId)")
            let got = RelayReasoningTier.fallback(
                available: Self.modes(item["available"]),
                rejected: Set(Self.modes(item["rejected"])),
                selected: selected
            )
            #expect(got == Self.mode(item["expect"]), "RELAY-TIER-fallback-\(caseId)")
        }
    }

    @Test("RELAY-TIER-family: with no official catalog match, the cached by-model family supplies the model-facts tiers; nothing cached -> empty")
    func RELAY_TIER_family_by_model() async throws {
        let document: [String: Any] = [
            "version": 1, "providers": [String: Any](),
            "modelFacts": ["deepseek/deepseek-reasoner-x": ["reasoningEfforts": ["low", "high"]]],
            "modelFactsRevision": "rev-tier",
        ]
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        )
        var model = AIModel(
            id: "vendor/deepseek-reasoner-x", name: "x", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .reachable
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "k", apiKeyPreview: "...k", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let before = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
        #expect(before.intents.isEmpty, "The by-model table has not been fetched: no request, no tiers")

        await MetadataClient.shared.setRelayByModelForTesting(Data(#"""
        {"code":0,"data":{"revision":"r","byModel":{"deepseek-reasoner-x":{"family":"deepseek","providerKind":"deepseek","facts":{}}}}}
        """#.utf8))
        let after = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
        #expect(after.intents == ["automatic", "low", "deep"], "\(after)")
        #expect(after.state == .autoAvailable)
    }

    // MARK: - In-send tier fallback

    @Test("RELAY-TIER-in-send-retry: Responses selects max and upstream answers 400 (first classify case) -> the second request body of the same send has reasoning.effort at the deep tier, and max is recorded in the negative cache")
    func RELAY_TIER_in_send_retry() async throws {
        let first = try #require(try Self.cases("classifyCases").first)
        let rejectionBody = try #require(first["body"] as? String)

        let metadata = try #require(
            try JSONSerialization.jsonObject(with: Self.repoFile("shared/test-fixtures/relay/metadata-fixture.json")) as? [String: Any]
        )
        var document = metadata
        document["modelFacts"] = ["openAI/gpt-5.4": ["reasoningEfforts": ["low", "medium", "high", "xhigh"]]]
        document["modelFactsRevision"] = "rev-tier"
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
        )

        var model = AIModel(
            id: "gpt-5.4", name: "gpt-5.4", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .reachable
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiResponses)
        )
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayTierScriptedProtocol.reset([(400, rejectionBody), (200, RelayTierScriptedProtocol.responsesOK)])

        let state = AppState(
            seedDemoData: false, sessionUID: "relay-tier-\(UUID().uuidString)",
            providerSession: RelayTierScriptedProtocol.session()
        )
        Self.retainedStates.append(state)
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: model.id)
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        var selection = ChatCapabilitySelection()
        selection.reasoningMode = .max
        _ = await state.sendMessage("think hard", in: conversation.id, capabilitySelection: selection)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant, message.state == .failed || message.state == .delivered { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let bodies = RelayTierScriptedProtocol.bodies
        #expect(bodies.count == 2, "After the rejection the same send resends once")
        let firstEffort = (bodies.first?["reasoning"] as? [String: Any])?["effort"] as? String
        #expect(firstEffort == "xhigh", "Precondition: the first send used the max tier: \(bodies.first ?? [:])")
        let secondEffort = (bodies.dropFirst().first?["reasoning"] as? [String: Any])?["effort"] as? String
        #expect(secondEffort == "high", "The resend lands on the deep tier: \(bodies.dropFirst().first ?? [:])")
        #expect(RelayNegativeCache.shared.isRejected(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.openaiResponses.rawValue, kind: .reasoningTierMax
        ))
        #expect(state.conversation(for: conversation.id)?.messages.last?.state == .delivered)
    }
}
