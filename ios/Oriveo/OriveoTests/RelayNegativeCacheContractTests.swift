import Foundation
import Testing
@testable import Oriveo

/// Local negative cache for the Relay rejection loop, plus the vision (image) entry point.
///
/// The fixture `shared/test-fixtures/relay/negative-cache.v1.json` drives it by caseId; the same cases have the same names on all platforms.
@Suite("Relay negative cache / vision entry (iOS)", .serialized)
struct RelayNegativeCacheContractTests {

    // MARK: - Fixture

    private func fixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/negative-cache.v1.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeCache() -> RelayNegativeCache {
        let suite = "relay-negative-cache-tests-\(UUID().uuidString)"
        return RelayNegativeCache(defaults: UserDefaults(suiteName: suite)!)
    }

    private func date(_ seconds: Any?) throws -> Date {
        Date(timeIntervalSince1970: try #require((seconds as? NSNumber)?.doubleValue))
    }

    private struct FixtureError: Error { let detail: String }

    private func string(_ value: Any?) throws -> String {
        guard let text = value as? String else { throw FixtureError(detail: "Missing string: \(String(describing: value))") }
        return text
    }

    private func transport(_ short: Any?, _ map: [String: String]) throws -> String {
        let key = try string(short)
        guard let full = map[key] else { throw FixtureError(detail: "Unknown protocol short name: \(key)") }
        return full
    }

    private func kind(_ raw: Any?) throws -> RelayNegativeCache.Kind {
        let key = try string(raw)
        guard let kind = RelayNegativeCache.Kind(rawValue: key) else { throw FixtureError(detail: "Unknown kind: \(key)") }
        return kind
    }

    // MARK: - RL2-NEGCACHE-01 Storage

    @Test("RL2-NEGCACHE-01 keyCases: a hit needs the same connection x model x protocol x kind, entries expire after 7 days, and other dimensions do not affect each other")
    func rl2NegCache01KeyCases() throws {
        let root = try loadFixture()
        let transports = try #require(root["transports"] as? [String: String])
        #expect((root["ttlSeconds"] as? NSNumber)?.doubleValue == RelayNegativeCache.ttl)
        let kinds = try #require(root["kinds"] as? [String])
        // Reasoning-tier rejections (`reasoningTier:<tier>`) are defined by reasoning-tier.v1.json; this fixture lists only the three capability kinds.
        #expect(Set(kinds).union(RelayReasoningTier.kinds.map(\.rawValue))
            == Set(RelayNegativeCache.Kind.allCases.map(\.rawValue)))
        #expect(Set(transports.values).isSubset(of: Set(RelayTransport.allCases.map(\.rawValue))))
        let cases = try #require(root["keyCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let record = try #require(item["record"] as? [String: Any])
            let query = try #require(item["query"] as? [String: Any])
            let cache = makeCache()
            cache.record(
                connectionID: try string(record["connectionId"]),
                modelID: try string(record["modelId"]),
                transport: try transport(record["transport"], transports),
                kind: try kind(record["kind"]),
                at: try date(record["at"])
            )
            let hit = cache.isRejected(
                connectionID: try string(query["connectionId"]),
                modelID: try string(query["modelId"]),
                transport: try transport(query["transport"], transports),
                kind: try kind(query["kind"]),
                now: try date(query["at"])
            )
            #expect(hit == (item["expectHit"] as? Bool), "\(caseID)")
        }
    }

    @Test("RL2-NEGCACHE-01 clearCases: a test write-back clears image + toolCall, a manual override clears that kind, and re-detection clears the whole connection")
    func rl2NegCache01ClearCases() throws {
        let root = try loadFixture()
        let transports = try #require(root["transports"] as? [String: String])
        let cases = try #require(root["clearCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let before = try #require(item["before"] as? [[String]])
            let after = try #require(item["after"] as? [[String]])
            let target = try #require(item["target"] as? [String: String])
            let cache = makeCache()
            for entry in before {
                cache.record(
                    connectionID: entry[0], modelID: entry[1],
                    transport: try transport(entry[2], transports),
                    kind: try kind(entry[3]),
                    at: recordedAt
                )
            }
            let connectionID = try #require(target["connectionId"])
            switch try #require(item["action"] as? String) {
            case "testedResult":
                cache.clear(
                    connectionID: connectionID, modelID: try string(target["modelId"]),
                    transport: try transport(target["transport"], transports),
                    kinds: [.image, .toolCall]
                )
            case "userOverride":
                cache.clear(
                    connectionID: connectionID, modelID: try string(target["modelId"]),
                    transport: try transport(target["transport"], transports),
                    kinds: [try kind(item["kind"])]
                )
            case "redetect":
                cache.clearConnection(connectionID)
            default:
                Issue.record("\(caseID): unknown action")
            }
            for entry in before {
                let hit = cache.isRejected(
                    connectionID: entry[0], modelID: entry[1],
                    transport: try transport(entry[2], transports),
                    kind: try kind(entry[3]),
                    now: now
                )
                #expect(hit == after.contains(entry), "\(caseID) \(entry)")
            }
        }
    }

    @Test("RL2-NEGCACHE-01 persistence: a new instance on the same UserDefaults reads it back, under the key relay_negative_cache.v1")
    func rl2NegCache01PersistsAcrossInstances() throws {
        let suite = "relay-negative-cache-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let transport = RelayTransport.openaiChatCompletions.rawValue
        RelayNegativeCache(defaults: defaults).record(
            connectionID: "c1", modelID: "m1", transport: transport, kind: .toolCall,
            at: Date(timeIntervalSince1970: 1_000)
        )
        #expect(defaults.object(forKey: RelayNegativeCache.storageKey) != nil)
        #expect(RelayNegativeCache.storageKey == "relay_negative_cache.v1")
        #expect(RelayNegativeCache(defaults: defaults).isRejected(
            connectionID: "c1", modelID: "m1", transport: transport, kind: .toolCall,
            now: Date(timeIntervalSince1970: 2_000)
        ))
    }

    @Test("RL2-NEGCACHE-01 same-key tool read: an unexpired toolCall negative entry yields false; a toolCall override beats both the negative entry and the declaration")
    func rl2NegCache01ToolCallVerdictReadsSameKey() throws {
        let cache = makeCache()
        var model = AIModel(
            id: "relay-tool-model", name: "relay-tool-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        model.toolCall = true
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])

        // No negative entry: follow the local declaration.
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model, negativeCache: cache).verdict == true)

        cache.record(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.openaiChatCompletions.rawValue, kind: .toolCall
        )
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model, negativeCache: cache).verdict == false)
        // Other protocols are unaffected.
        let responses = relayProvider(transport: .openaiResponses, models: [model], id: provider.id)
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: responses, model: model, negativeCache: cache).verdict == true)

        // An override is the highest-priority source.
        var overridden = model
        overridden.relayCapabilityOverrides = RelayCapabilityOverrides(toolCall: true, source: .tested)
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: overridden, negativeCache: cache).verdict == true)
        overridden.relayCapabilityOverrides = RelayCapabilityOverrides(toolCall: false, source: .user)
        overridden.engineDeclaration = EngineDeclaration(toolCall: true)
        var engine = provider
        engine.relayRequested?.engineProfile = "ollama"
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: engine, model: overridden, negativeCache: makeCache()).verdict == false)
    }

    // MARK: - RL2-NEGCACHE-03 vision entry (production criteria)

    private func relayProvider(
        transport: RelayTransport,
        models: [AIModel],
        id: UUID = UUID(),
        engineProfile: String? = nil
    ) -> Provider {
        Provider(
            id: id,
            kind: .relay,
            status: .connected,
            models: models,
            catalogModels: [],
            apiKey: "key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport, engineProfile: engineProfile)
        )
    }

    /// In the shared metadata fixture every envelope accepts images; the Chat Completions one is changed in memory to reject images,
    /// for cases that need `envelopeAllowsImage == false`.
    private func loadMetadataWithChatEnvelopeWithoutImage() async throws {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"))
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var runtime = try #require(root["relayRuntimeConfig"] as? [String: Any])
        var envelopes = try #require(runtime["transportEnvelopes"] as? [String: Any])
        var chat = try #require(envelopes["openai_chat_completions"] as? [String: Any])
        chat["image"] = false
        envelopes["openai_chat_completions"] = chat
        runtime["transportEnvelopes"] = envelopes
        root["relayRuntimeConfig"] = runtime
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: json)
    }

    /// Photo entry: ChatView's visible set feeds ChatComposerBar's image-entry check; both are production static functions.
    private func photoEntryVisible(
        provider: Provider,
        model: AIModel,
        cache: RelayNegativeCache
    ) -> Bool {
        let partitionID = "relay-negative-cache-tests"
        let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider, model: model, partitionID: partitionID
        ) ?? (provider.relayRequested == nil
            ? CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: partitionID, hasExplicitValue: false
            )
            : nil)
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: ["vision_input", "tool_call"]
        )
        let visibleKeys = ChatView.visibleCapabilityKeys(
            provider: provider, model: model, projection: projection, negativeCache: cache
        )
        return ChatComposerBar.supportsImageAttachment(
            provider: provider, model: model, visibleCapabilityKeys: visibleKeys
        )
    }

    @Test("RL2-NEGCACHE-03 visionEntryCases: Relay vision stays visible when unknown, is hidden by negative evidence or an image negative entry, and an override of true beats the negative entry")
    func rl2NegCache03VisionEntryCases() async throws {
        try await loadMetadataWithChatEnvelopeWithoutImage()
        let fixture = try loadFixture()
        let cases = try #require(fixture["visionEntryCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let caseID = try #require(item["caseId"] as? String)
            let cache = makeCache()
            // The model itself lacks .image: even with "no candidate" the entry must stay visible.
            var model = AIModel(
                id: "relay-vision-\(caseID)", name: caseID, capabilities: [.text],
                reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
            )
            let engineImage = item["engineDeclarationImage"] as? Bool
            if let engineImage { model.engineDeclaration = EngineDeclaration(image: engineImage) }
            if let override = item["override"] as? [String: Any] {
                model.relayCapabilityOverrides = RelayCapabilityOverrides(
                    image: try #require(override["value"] as? Bool),
                    source: try #require(RelayCapabilityOverrides.Source(rawValue: try string(override["source"])))
                )
            }
            let envelopeAllowsImage = try #require(item["envelopeAllowsImage"] as? Bool)
            let transport: RelayTransport = envelopeAllowsImage ? .openaiResponses : .openaiChatCompletions
            let provider: Provider
            switch try #require(item["form"] as? String) {
            case "relay":
                provider = relayProvider(
                    transport: transport, models: [model],
                    engineProfile: engineImage == nil ? nil : "ollama"
                )
            case "official":
                provider = Provider(
                    id: UUID(), kind: .openAI, status: .connected, models: [model], catalogModels: [],
                    apiKey: "key", apiKeyPreview: "...key"
                )
            default:
                Issue.record("\(caseID): unknown form")
                continue
            }
            if try #require(item["imageNegCached"] as? Bool) {
                cache.record(
                    connectionID: provider.id.uuidString, modelID: model.id,
                    transport: transport.rawValue, kind: .image
                )
            }
            let expected = try #require(item["expectVisible"] as? Bool)
            #expect(photoEntryVisible(provider: provider, model: model, cache: cache) == expected, "\(caseID)")
        }
    }

    @Test("RL2-NEGCACHE-03 connection auto with a model that has no protocol is not an incomplete identity: vision stays visible when unknown and is hidden after an image negative entry on the chat key")
    func rl2NegCache03AutoConnectionUsesEffectiveTransport() async throws {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"))
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
        let model = AIModel(
            id: "relay-vision-auto", name: "auto", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: ""
        )
        // `auto` resolves to Chat via effectiveTransport.
        let provider = relayProvider(transport: .auto, models: [model])
        let cache = makeCache()
        #expect(photoEntryVisible(provider: provider, model: model, cache: cache))
        cache.record(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.openaiChatCompletions.rawValue, kind: .image
        )
        #expect(!photoEntryVisible(provider: provider, model: model, cache: cache))
    }
}

// MARK: - Write side

/// Fake upstream for the production send chain: replays a script in order and records each request's URL and body.
private final class RelayNegCacheScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(status: Int, body: String)
        case sse(body: String)
        case html(body: String)
    }

    nonisolated(unsafe) static var script: [Reply] = []
    nonisolated(unsafe) private static var _urls: [URL] = []
    nonisolated(unsafe) private static var _bodies: [Data] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        script = replies
        _urls = []
        _bodies = []
    }

    static var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    static var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayNegCacheScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            buffer.deallocate()
            stream.close()
        }
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let reply: Reply = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self._urls.append(url)
            Self._bodies.append(body)
            let index = Self._urls.count - 1
            return index < Self.script.count ? Self.script[index] : .json(status: 500, body: #"{"error":{"message":"unscripted"}}"#)
        }()
        let status: Int
        let contentType: String
        let data: Data
        switch reply {
        case let .json(code, text):
            status = code; contentType = "application/json"; data = Data(text.utf8)
        case let .sse(text):
            status = 200; contentType = "text/event-stream"; data = Data(text.utf8)
        case let .html(text):
            status = 200; contentType = "text/html; charset=utf-8"; data = Data(text.utf8)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private enum RelayNegCacheSend {
    static var retainedStates: [AppState] = []

    static let chatOK = """
    data: {"choices":[{"delta":{"content":"ok"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    static func imageAttachment() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png",
            base64Data: RelayCapabilityTest.imagePNGBase64
        )
    }

    /// Sends one message through production `AppState.sendMessage` and waits until the assistant message reaches a terminal state.
    static func send(
        provider: Provider,
        modelID: String,
        attachments: [Oriveo.Attachment] = []
    ) async throws -> (state: AppState, message: ChatMessage) {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-negcache-\(UUID().uuidString)",
            providerSession: RelayNegCacheScriptedProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(
            providerID: provider.id, providerKind: .relay, modelID: modelID
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("Describe it", attachments: attachments, in: conversation.id)

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant,
               message.state == .failed || message.state == .delivered {
                try await Task.sleep(nanoseconds: 300_000_000)
                return (state, state.conversation(for: conversation.id)?.messages.last ?? message)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CancellationError()
    }
}

extension RelayNegativeCacheContractTests {

    private func capabilityTestFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/capability-test.v1.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plainModel(_ id: String, transport: RelayTransport? = nil, source: RelayTransportSource? = nil) -> AIModel {
        var model = AIModel(
            id: id, name: id, capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = transport
        model.relayTransportSource = source
        return model
    }

    private func loadSharedMetadata() async throws {
        let data = try Data(contentsOf: fixtureURL("shared/test-fixtures/relay/metadata-fixture.json"))
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
    }

    private func anyEntry(_ cache: RelayNegativeCache, connection: UUID, modelID: String) -> Bool {
        RelayTransport.allCases.contains { transport in
            RelayNegativeCache.Kind.allCases.contains { kind in
                cache.isRejected(
                    connectionID: connection.uuidString, modelID: modelID,
                    transport: transport.rawValue, kind: kind
                )
            }
        }
    }

    // MARK: RL2-NEGCACHE-01 write signals and same-key tools

    @Test("RL2-NEGCACHE-01 signal: driven by capability-test classifyCases; only rejected writes image")
    @MainActor
    func rl2NegCache01ClassifyCasesDriveWrites() throws {
        let cases = try #require(try capabilityTestFixture()["classifyCases"] as? [[String: Any]])
        #expect(cases.count == 26)
        for item in cases {
            let caseID = try string(item["caseId"])
            let cache = makeCache()
            let model = plainModel("relay-signal")
            let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
            let rejection = RelayPreOutputRejection(
                status: try #require(item["status"] as? Int),
                contentType: try string(item["contentType"]),
                body: Data(try string(item["body"]).utf8)
            )
            let written = RelayRejectionRecording.recordImageRejection(
                provider: provider, model: model,
                transport: .openaiChatCompletions, rejection: rejection, negativeCache: cache
            )
            let expected = try string(item["expect"]) == "rejected"
            #expect(written == expected, "\(caseID)")
            #expect(cache.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayTransport.openaiChatCompletions.rawValue, kind: .image
            ) == expected, "\(caseID)")
        }
    }

    @Test("RL2-NEGCACHE-01 connection auto, model without a protocol: the toolCall negative entry is read under effectiveTransport (Chat)")
    func rl2NegCache01AutoConnectionReadsEffectiveTransport() {
        let cache = makeCache()
        var model = plainModel("relay-auto-tool")
        model.toolCall = true
        let provider = relayProvider(transport: .auto, models: [model])
        cache.record(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.openaiChatCompletions.rawValue, kind: .toolCall
        )
        #expect(ToolCallCapabilityPolicy.catalogVerdict(provider: provider, model: model, negativeCache: cache).verdict == false)
    }

    @Test("RL2-NEGCACHE-01 key clearing: a capability-test write-back clears image + toolCall for the model's current protocol, and deleting the connection clears the whole connection")
    @MainActor
    func rl2NegCache01ProductionClearPaths() async throws {
        let model = plainModel("relay-clear", transport: .openaiChatCompletions, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-negcache-clear-\(UUID().uuidString)",
            providerSession: RelayNegCacheScriptedProtocol.session()
        )
        RelayNegCacheSend.retainedStates.append(state)
        state.providers = [provider]
        let cache = RelayNegativeCache.shared
        defer { cache.clearConnection(provider.id.uuidString) }
        let chat = RelayTransport.openaiChatCompletions.rawValue
        let connection = provider.id.uuidString
        for kind in RelayNegativeCache.Kind.allCases {
            cache.record(connectionID: connection, modelID: model.id, transport: chat, kind: kind)
        }
        cache.record(connectionID: connection, modelID: model.id, transport: RelayTransport.openaiResponses.rawValue, kind: .image)

        let accepted = RelayCapabilityTest.Response(
            status: 200, contentType: "application/json",
            body: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        )
        let result = await state.providerManager.runRelayCapabilityTest(
            providerID: provider.id, modelID: model.id, send: { _, _ in accepted }
        )
        #expect(result?.outcome == .completed)
        #expect(!cache.isRejected(connectionID: connection, modelID: model.id, transport: chat, kind: .image))
        #expect(!cache.isRejected(connectionID: connection, modelID: model.id, transport: chat, kind: .toolCall))
        #expect(cache.isRejected(connectionID: connection, modelID: model.id, transport: chat, kind: .file))
        #expect(cache.isRejected(
            connectionID: connection, modelID: model.id,
            transport: RelayTransport.openaiResponses.rawValue, kind: .image
        ))

        #expect(state.providerManager.removeProvider(provider.id))
        #expect(!anyEntry(cache, connection: provider.id, modelID: model.id))
    }

    // MARK: RL2-NEGCACHE-02 error frame after output

    @Test("RL2-NEGCACHE-02 error frame after output: the message fails, the text is kept, nothing is resent, and storage gets no new entry")
    @MainActor
    func rl2NegCache02ErrorFrameAfterOutput() async throws {
        try await loadSharedMetadata()
        let model = plainModel("relay-error-frame")
        let provider = relayProvider(transport: .openaiResponses, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.sse(body: """
        event: response.output_text.delta
        data: {"delta":"partial answer"}

        event: response.failed
        data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}

        data: [DONE]

        """)])

        let (_, message) = try await RelayNegCacheSend.send(
            provider: provider, modelID: model.id, attachments: [RelayNegCacheSend.imageAttachment()]
        )
        #expect(message.state == .failed)
        #expect(message.text.contains("partial answer"))
        #expect(RelayNegCacheScriptedProtocol.urls.count == 1, "no resend after output")
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id))
        #expect(message.recoveryPrimaryAction == nil)
    }

    // MARK: RL2-NEGCACHE-03 image send rejected

    @Test("RL2-NEGCACHE-03 Relay vision unknown, image sent -> 400: the image is still sent, image is recorded, the entry is hidden, and a hint card with Switch Model appears")
    @MainActor
    func rl2NegCache03ImageRejectedEndToEnd() async throws {
        try await loadSharedMetadata()
        // Exercise both outbound paths once: Chat goes through finalChatIntent's vision outbound gate, Responses through its own builder.
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses] {
            let model = plainModel("relay-vision-unknown")
            let provider = relayProvider(transport: transport, models: [model])
            defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
            #expect(photoEntryVisible(provider: provider, model: model, cache: .shared), "\(transport): precondition: stays visible when unknown")
            RelayNegCacheScriptedProtocol.reset([
                .json(status: 400, body: #"{"error":{"message":"image input is not supported for this model"}}"#),
            ])

            let (_, message) = try await RelayNegCacheSend.send(
                provider: provider, modelID: model.id, attachments: [RelayNegCacheSend.imageAttachment()]
            )
            // The image is still sent: the assertion reads the production request body (JSON escapes `/` as `\/`).
            let body = String(decoding: try #require(RelayNegCacheScriptedProtocol.bodies.first), as: UTF8.self)
                .replacingOccurrences(of: "\\/", with: "/")
            #expect(body.contains(RelayCapabilityTest.imagePNGBase64), "\(transport): \(body.prefix(600))")
            #expect(RelayNegCacheScriptedProtocol.urls.count == 1, "\(transport): the image gets no text fallback and is not resent automatically")

            #expect(message.state == .failed)
            #expect(RelayNegativeCache.shared.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: transport.rawValue, kind: .image
            ), "\(transport)")
            #expect(!photoEntryVisible(provider: provider, model: model, cache: .shared), "\(transport)")

            // Hint card: the failed message carries the existing recovery card, its body uses a string-table key, and the primary action reuses Switch Model.
            let action = recoveryPrimaryAction(for: message)
            #expect(action == relayImageUnsupportedRecoveryAction)
            let layout = resolveMessageRecoveryCardActionLayout(
                for: .failed, shouldOfferModelSwitch: false, recoveryPrimaryAction: action
            )
            #expect(layout.primary == .switchModel)
            #expect(localizedMessageRecoveryActionTitle(layout.primary) == L10n.tr("Switch Model"))
            #expect(localizedMessageRecoveryBody(for: .failed, localPrimaryAction: action)
                == L10n.tr("This model doesn't support images. Switch to another model to send them.", table: .chat))
        }
    }

    @Test("RL2-NEGCACHE-03 a rejection is not recorded as image when vision is already overridden to supported")
    @MainActor
    func rl2NegCache03DeclaredSupportDoesNotRecord() async throws {
        try await loadSharedMetadata()
        var model = plainModel("relay-vision-tested")
        model.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, source: .tested)
        let provider = relayProvider(transport: .openaiResponses, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.json(status: 400, body: #"{"error":{"message":"bad request"}}"#)])

        let (_, message) = try await RelayNegCacheSend.send(
            provider: provider, modelID: model.id, attachments: [RelayNegCacheSend.imageAttachment()]
        )
        #expect(message.state == .failed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id))
        #expect(message.recoveryPrimaryAction == nil)
    }

    // MARK: RL2-NEGCACHE-04 protocol-level fallback

    @Test("RL2-NEGCACHE-04 protocolFallbackCases: a pure function picks the next protocol")
    func rl2NegCache04ProtocolFallbackCases() throws {
        let root = try loadFixture()
        let transports = try #require(root["transports"] as? [String: String])
        let cases = try #require(root["protocolFallbackCases"] as? [[String: Any]])
        #expect(cases.count == 18)
        // The criteria constants equal the fixture's protocolFallbackRules item by item.
        let rules = try #require(root["protocolFallbackRules"] as? [String: Any])
        #expect(RelayProtocolFallback.statuses == Set(try #require(rules["statuses"] as? [Int])))
        #expect(RelayProtocolFallback.phraseStatuses == Set(try #require(rules["phraseStatuses"] as? [Int])))
        #expect(RelayProtocolFallback.phrases == rules["phrases"] as? [String])
        #expect(RelayProtocolFallback.htmlSuccessIsRouteRejection == rules["htmlSuccessIsRouteRejection"] as? Bool)
        var executed: [String] = []
        func relay(_ short: Any?) throws -> RelayTransport {
            try #require(RelayTransport(rawValue: try transport(short, transports)))
        }
        for item in cases {
            let caseID = try string(item["caseId"])
            let source: RelayTransportSource? = try (item["source"] as? String).map {
                try #require(RelayTransportSource(rawValue: $0))
            }
            let candidates = try #require(item["candidates"] as? [String]).map { try relay($0) }
            let next = RelayProtocolFallback.next(
                current: try relay(item["current"]),
                source: source,
                candidates: candidates,
                // A case without `body` is treated as an empty body, and one without `contentType` as application/json.
                rejection: RelayPreOutputRejection(
                    status: try #require(item["status"] as? Int),
                    contentType: item["contentType"] as? String ?? "application/json",
                    body: Data((item["body"] as? String ?? "").utf8)
                ),
                outputStarted: try #require(item["outputStarted"] as? Bool),
                alreadySwitched: try #require(item["alreadySwitched"] as? Bool)
            )
            let expected: RelayTransport? = item["expectNext"] is NSNull || item["expectNext"] == nil
                ? nil : try relay(item["expectNext"])
            #expect(next == expected, "\(caseID)")
            executed.append(caseID)
        }
        for added in [
            "status_405_tries_next_candidate",
            "status_403_with_route_phrase_tries_next_candidate",
            "status_403_without_route_phrase_does_not_switch",
            "status_401_does_not_switch",
            "status_429_does_not_switch",
            "html_page_with_200_tries_next_candidate",
            "status_403_with_escaped_route_phrase_tries_next_candidate",
            "status_403_client_gate_does_not_switch",
        ] {
            #expect(executed.contains(added), "\(added) was not executed")
        }
        // Phrases are case-insensitive.
        let phrase = try #require(RelayProtocolFallback.phrases.first)
        func rejection(_ status: Int, _ body: String, _ contentType: String = "application/json") -> RelayPreOutputRejection {
            RelayPreOutputRejection(status: status, contentType: contentType, body: Data(body.utf8))
        }
        #expect(RelayProtocolFallback.isRouteRejection(rejection(403, phrase.uppercased())))
        #expect(!RelayProtocolFallback.isRouteRejection(rejection(401, phrase)))
        // A 200 web page counts if either the content type or the body identifies it (same detection as RelaySuccessResponsePolicy); a normal 2xx does not.
        #expect(RelayProtocolFallback.isRouteRejection(rejection(200, "", "text/html")))
        #expect(RelayProtocolFallback.isRouteRejection(rejection(200, "\n<!DOCTYPE html><html></html>")))
        #expect(!RelayProtocolFallback.isRouteRejection(rejection(200, #"{"id":"ok"}"#)))
        #expect(!RelayProtocolFallback.isRouteRejection(rejection(200, "data: {}", "text/event-stream")))
        // A 200 web page is not a capability rejection: it never enters the negative-cache decision.
        #expect(!RelayRejectionRecording.isRejected(rejection(200, "<html></html>", "text/html")))
    }

    // MARK: RL2-CLIGATE official CLI gate

    private func clientGateFixture() throws -> (rules: [String: Any], cases: [[String: Any]]) {
        let root = try loadFixture()
        return (
            try #require(root["clientGateRules"] as? [String: Any]),
            try #require(root["clientGateCases"] as? [[String: Any]])
        )
    }

    private func runClientGate(_ caseID: String) throws {
        let item = try #require(try clientGateFixture().cases.first { $0["caseId"] as? String == caseID }, "fixture is missing clientGateCases/\(caseID)")
        let status = try #require(item["status"] as? Int)
        let body = try string(item["body"])
        let expected = try string(item["expect"]) == "client_gated"
        #expect(RelayClientGate.isClientGated(status: status, body: Data(body.utf8)) == expected, "\(caseID)")
        // A gate 403 is not a route-level rejection: the protocol is not switched.
        #expect(!RelayProtocolFallback.isRouteRejection(
            RelayPreOutputRejection(status: status, contentType: "application/json", body: Data(body.utf8))
        ) || !expected, "\(caseID)")
    }

    @Test("RL2-CLIGATE-packyapi_official_claude_cli_403") func cliGate01() throws { try runClientGate("packyapi_official_claude_cli_403") }
    @Test("RL2-CLIGATE-sub2api_claude_code_only_group_403") func cliGate02() throws { try runClientGate("sub2api_claude_code_only_group_403") }
    @Test("RL2-CLIGATE-chinese_standard_claude_code_client_403") func cliGate03() throws { try runClientGate("chinese_standard_claude_code_client_403") }
    @Test("RL2-CLIGATE-uppercase_phrase_403") func cliGate04() throws { try runClientGate("uppercase_phrase_403") }
    @Test("RL2-CLIGATE-same_phrase_on_401_is_none") func cliGate05() throws { try runClientGate("same_phrase_on_401_is_none") }
    @Test("RL2-CLIGATE-codex_identity_403_is_none") func cliGate06() throws { try runClientGate("codex_identity_403_is_none") }
    @Test("RL2-CLIGATE-token_model_forbidden_403_is_none") func cliGate07() throws { try runClientGate("token_model_forbidden_403_is_none") }
    @Test("RL2-CLIGATE-messages_dispatch_403_is_none") func cliGate08() throws { try runClientGate("messages_dispatch_403_is_none") }

    @Test("RL2-CLIGATE the criteria constants equal the fixture's clientGateRules item by item, and every caseId has a same-named case")
    func cliGateRulesMatchFixture() throws {
        let fixture = try clientGateFixture()
        #expect(RelayClientGate.statuses == Set(try #require(fixture.rules["statuses"] as? [Int])))
        #expect(RelayClientGate.phrases == fixture.rules["phrases"] as? [String])
        let ids = fixture.cases.compactMap { $0["caseId"] as? String }
        #expect(ids == [
            "packyapi_official_claude_cli_403",
            "sub2api_claude_code_only_group_403",
            "chinese_standard_claude_code_client_403",
            "uppercase_phrase_403",
            "same_phrase_on_401_is_none",
            "codex_identity_403_is_none",
            "token_model_forbidden_403_is_none",
            "messages_dispatch_403_is_none",
        ])
    }

    @Test("RL2-NEGCACHE-04 production send: a 200 web page before output -> switching to a candidate protocol succeeds -> the model protocol is written as observed and no negative entry is recorded")
    @MainActor
    func rl2NegCache04ProductionSwitchesOnHTMLSuccessPage() async throws {
        await MetadataClient.shared.resetForTesting()
        let model = plainModel("relay-html-model", transport: .openaiResponses, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([
            .html(body: "<!doctype html><html><head><title>Relay</title></head><body><div id=\"root\"></div></body></html>"),
            .sse(body: RelayNegCacheSend.chatOK),
        ])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 2)
        #expect(urls.first?.path.hasSuffix("/responses") == true, "\(urls)")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiChatCompletions)
        #expect(stored.relayTransportSource == .observed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id), "protocol fallback records no negative entry")
    }

    /// Take the fixture's 403 body containing the registered phrase and re-encode it with a JSON encoder: Foundation writes `/` as `\/` by default,
    /// which is exactly the escaped form an upstream produces when it echoes the body as JSON text (the shared fixture is left untouched).
    private func escapedSlashRoutePhraseBody() throws -> (plain: String, escaped: String) {
        let cases = try #require(try loadFixture()["protocolFallbackCases"] as? [[String: Any]])
        let plain = try string(
            cases.first { $0["caseId"] as? String == "status_403_with_route_phrase_tries_next_candidate" }?["body"]
        )
        let object = try JSONSerialization.jsonObject(with: Data(plain.utf8))
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(escaped.contains(#"\/v1\/messages"#), "Precondition: the encoder escaped the slash, actual: \(escaped)")
        #expect(!escaped.contains("/v1/messages"))
        return (plain, escaped)
    }

    @Test("RL2-NEGCACHE-04 403 registered phrase: a body that writes the slash as \\/ is still a route-level rejection; a 403 without the phrase is not, and the status code is not relaxed")
    func rl2NegCache04RoutePhraseMatchesEscapedSlashes() throws {
        let body = try escapedSlashRoutePhraseBody()
        func rejection(_ status: Int, _ text: String) -> RelayPreOutputRejection {
            RelayPreOutputRejection(status: status, contentType: "application/json", body: Data(text.utf8))
        }
        #expect(RelayProtocolFallback.isRouteRejection(rejection(403, body.plain)))
        #expect(RelayProtocolFallback.isRouteRejection(rejection(403, body.escaped)))
        #expect(RelayProtocolFallback.isRouteRejection(rejection(403, body.escaped.uppercased())))
        #expect(RelayProtocolFallback.next(
            current: .anthropicMessages, source: nil,
            candidates: [.anthropicMessages, .openaiChatCompletions],
            rejection: rejection(403, body.escaped), outputStarted: false, alreadySwitched: false
        ) == .openaiChatCompletions)
        // Probing uses the same criterion when switching candidates.
        #expect(RelayModelProbe.classify(rejection(403, body.escaped)) == .routeRejected)

        // The status code is not relaxed: the same escaped body with another non-route status does not count.
        for status in [400, 401, 422, 429, 500] {
            #expect(!RelayProtocolFallback.isRouteRejection(rejection(status, body.escaped)), "\(status)")
        }
        // A 403 without the registered phrase is still a key / account problem: neither the original fixture text nor a body with only escaped slashes and no phrase counts.
        let cases = try #require(try loadFixture()["protocolFallbackCases"] as? [[String: Any]])
        let denied = try string(
            cases.first { $0["caseId"] as? String == "status_403_without_route_phrase_does_not_switch" }?["body"]
        )
        #expect(!RelayProtocolFallback.isRouteRejection(rejection(403, denied)))
        #expect(!RelayProtocolFallback.isRouteRejection(
            rejection(403, #"{"error":{"message":"token has no access to \/v1\/messages"}}"#)
        ))
        // Only one spelling of the phrase is registered; the fixture rules are unchanged.
        #expect(RelayProtocolFallback.phrases == ["does not allow /v1/messages dispatch"])
    }

    @Test("RL2-NEGCACHE-04 production send: slashes of the registered phrase are escaped in a 403 body -> switching to a candidate protocol still succeeds and no negative entry is recorded")
    @MainActor
    func rl2NegCache04ProductionSwitchesOnEscapedSlashRoutePhrase() async throws {
        await MetadataClient.shared.resetForTesting()
        let model = plainModel("relay-escaped-slash-model", transport: .openaiResponses, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let escaped = try escapedSlashRoutePhraseBody().escaped
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 403, body: escaped),
            .sse(body: RelayNegCacheSend.chatOK),
        ])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 2)
        #expect(urls.first?.path.hasSuffix("/responses") == true, "\(urls)")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiChatCompletions)
        #expect(stored.relayTransportSource == .observed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id), "protocol fallback records no negative entry")
    }

    @Test("RL2-NEGCACHE-04 production send: a streaming 200 whose Content-Type is not html but whose body is a web page -> judged a route-level rejection before output and switched to a candidate protocol")
    @MainActor
    func rl2NegCache04ProductionSwitchesOnHTMLBodyBehindEventStreamType() async throws {
        await MetadataClient.shared.resetForTesting()
        let model = plainModel("relay-html-stream-model", transport: .openaiResponses, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        // `.sse` replies with text/event-stream: the headers do not reveal a web page, only the first body line does.
        RelayNegCacheScriptedProtocol.reset([
            .sse(body: "\n<!DOCTYPE html>\n<html lang=\"en\"><head><title>Relay</title></head><body><div id=\"root\"></div></body></html>\n"),
            .sse(body: RelayNegCacheSend.chatOK),
        ])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 2)
        #expect(urls.first?.path.hasSuffix("/responses") == true, "\(urls)")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiChatCompletions)
        #expect(stored.relayTransportSource == .observed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id), "protocol fallback records no negative entry")
    }

    @Test("RL2-NEGCACHE-04 production send: the user picked the connection protocol and the model follows it -> a 404 does not switch protocol")
    @MainActor
    func rl2NegCache04ProductionUserChosenConnectionNeverSwitches() async throws {
        await MetadataClient.shared.resetForTesting()
        let model = plainModel("relay-follow-model", transport: nil, source: nil)
        let provider = relayProvider(transport: .openaiResponses, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])
        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .failed)
        #expect(RelayNegCacheScriptedProtocol.urls.count == 1)
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == nil)
        #expect(stored.relayTransportSource == nil)
    }

    @Test("RL2-NEGCACHE-04 production send 404 -> switching to a candidate protocol succeeds -> the model protocol is written as observed")
    @MainActor
    func rl2NegCache04ProductionSwitchesOnceAndWritesObserved() async throws {
        await MetadataClient.shared.resetForTesting()
        let model = plainModel("relay-fallback-model", transport: .openaiResponses, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 2)
        #expect(urls.first?.path.hasSuffix("/responses") == true, "\(urls)")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiChatCompletions)
        #expect(stored.relayTransportSource == .observed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id), "protocol fallback records no negative entry")
    }

    private static let messagesOK = """
    event: message_start
    data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}

    event: message_delta
    data: {"type":"message_delta","usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    /// The family table has only a claude entry (equivalent to this session having fetched the by-model table).
    private func loadClaudeFamily(_ modelID: String) async throws {
        try await loadSharedMetadata()
        await MetadataClient.shared.setRelayByModelForTesting(Data("""
        {"code":0,"data":{"revision":"r","byModel":{"\(modelID)":{"family":"anthropic","providerKind":"anthropic","facts":{}}}}}
        """.utf8))
    }

    @Test("RL2-FIRSTSEND-01 first send of an unverified Claude-family model (connection auto): goes through Messages with max_tokens in the body, and records observed on success")
    @MainActor
    func rl2FirstSendUnverifiedClaudeUsesMessages() async throws {
        let modelID = "claude-first-send-x"
        try await loadClaudeFamily(modelID)
        let model = plainModel(modelID, transport: nil, source: nil)
        let provider = relayProvider(transport: .auto, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.sse(body: Self.messagesOK)])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 1, "\(urls)")
        #expect(urls.first?.path.hasSuffix("/messages") == true, "the first send must not use Chat: \(urls)")
        let body = try #require(RelayNegCacheScriptedProtocol.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["max_tokens"] as? NSNumber).map { $0.intValue > 0 } == true, "\(json)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .anthropicMessages)
        #expect(stored.relayTransportSource == .observed)
    }

    @Test("RL2-FIRSTSEND-02 the first Messages send of an unverified Claude-family model gets a 404 -> switching to the next candidate, Chat, succeeds and records observed Chat")
    @MainActor
    func rl2FirstSendMessagesRouteRejectedFallsBackToChat() async throws {
        let modelID = "claude-first-send-y"
        try await loadClaudeFamily(modelID)
        let model = plainModel(modelID, transport: nil, source: nil)
        let provider = relayProvider(transport: .auto, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 2, "\(urls)")
        #expect(urls.first?.path.hasSuffix("/messages") == true, "\(urls)")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiChatCompletions)
        #expect(stored.relayTransportSource == .observed)
    }

    @Test("RL2-FIRSTSEND-03 unknown family (not in the table): the first send still uses Chat and success does not write a model protocol")
    @MainActor
    func rl2FirstSendUnknownFamilyStaysOnChat() async throws {
        try await loadClaudeFamily("some-other-model")
        let model = plainModel("relay-unknown-family", transport: nil, source: nil)
        let provider = relayProvider(transport: .auto, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.sse(body: RelayNegCacheSend.chatOK)])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        #expect(RelayNegCacheScriptedProtocol.urls.first?.path.hasSuffix("/chat/completions") == true)
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == nil)
        #expect(stored.relayTransportSource == nil)
    }

    @Test("RL2-FIRSTSEND-04 the first send of an unverified OpenAI-family model still uses Chat: only a Messages first item rewrites the first send (no fallback when Responses gets a 400)")
    @MainActor
    func rl2FirstSendOpenAIFamilyStaysOnChat() async throws {
        let modelID = "gpt-first-send-z"
        try await loadSharedMetadata()
        await MetadataClient.shared.setRelayByModelForTesting(Data("""
        {"code":0,"data":{"revision":"r","byModel":{"\(modelID)":{"family":"openai","providerKind":"openai","facts":{}}}}}
        """.utf8))
        let model = plainModel(modelID, transport: nil, source: nil)
        let provider = relayProvider(transport: .auto, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.sse(body: RelayNegCacheSend.chatOK)])

        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 1, "\(urls)")
        #expect(urls.first?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == nil)
    }

    @Test("RL2-FIRSTSEND-05 RelayFirstSendTransport pure function: Messages is chosen only for relay, non-local, a model without a protocol, not following a user-selected connection, not image generation, and a Messages first candidate")
    func rl2FirstSendResolveTable() {
        struct Row {
            let name: String
            let connection: RelayTransport
            let model: AIModel
            var engineProfile: String? = nil
            let family: String?
            var types: [String]? = nil
            /// nil means equal to effectiveTransport.
            let expected: RelayTransport?
        }
        let plain = plainModel("first-send-plain")
        let ownAuto = plainModel("first-send-own-auto", transport: .auto, source: .observed)
        let ownChat = plainModel("first-send-own-chat", transport: .openaiChatCompletions, source: .reachable)
        var imageGen = plainModel("first-send-image-gen")
        imageGen.capabilities = [.text, .imageGen]
        let rows: [Row] = [
            Row(name: "Claude family, connection auto", connection: .auto, model: plain, family: "anthropic", expected: .anthropicMessages),
            Row(name: "a model protocol of auto also counts as no protocol", connection: .auto, model: ownAuto, family: "anthropic", expected: .anthropicMessages),
            Row(name: "endpoint types with anthropic first beats the family", connection: .auto, model: plain, family: "openai",
                types: ["anthropic", "openai"], expected: .anthropicMessages),
            Row(name: "endpoint types with openai first", connection: .auto, model: plain, family: "anthropic",
                types: ["openai", "anthropic"], expected: .openaiChatCompletions),
            Row(name: "OpenAI family is not rewritten to Responses", connection: .auto, model: plain, family: "openai", expected: .openaiChatCompletions),
            Row(name: "unknown family", connection: .auto, model: plain, family: nil, expected: .openaiChatCompletions),
            Row(name: "model has its own protocol", connection: .auto, model: ownChat, family: "anthropic", expected: nil),
            Row(name: "user-selected connection protocol, model follows", connection: .openaiResponses, model: plain, family: "anthropic", expected: .openaiResponses),
            Row(name: "local engine", connection: .auto, model: plain, engineProfile: "ollama", family: "anthropic", expected: nil),
            Row(name: "image-generation model", connection: .auto, model: imageGen, family: "anthropic", expected: .openaiChatCompletions),
        ]
        for row in rows {
            let provider = relayProvider(transport: row.connection, models: [row.model], engineProfile: row.engineProfile)
            let effective = RelayEndpointResolver.effectiveTransport(provider: provider, model: row.model)
            let got = RelayFirstSendTransport.resolve(
                provider: provider, model: row.model, family: row.family, supportedEndpointTypes: row.types
            )
            #expect(got == (row.expected ?? effective), "\(row.name)")
            if row.expected != .anthropicMessages {
                #expect(got == effective, "\(row.name): without rewriting, matches effectiveTransport")
            }
        }
    }

    @Test("RL2-FIRSTSEND-06 production send: an image send on the first Messages send of an unverified Claude-family model is rejected -> the image negative entry is recorded under Messages, and the vision entry and the advanced page read it under the same protocol")
    @MainActor
    func rl2FirstSendImageRejectionReadsSameKey() async throws {
        let modelID = "claude-first-send-image"
        try await loadClaudeFamily(modelID)
        let model = plainModel(modelID)
        let provider = relayProvider(transport: .auto, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == .anthropicMessages)
        #expect(photoEntryVisible(provider: provider, model: model, cache: .shared), "Precondition: vision stays visible when unknown")
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 400, body: #"{"error":{"message":"image input is not supported for this model"}}"#),
        ])

        let (state, message) = try await RelayNegCacheSend.send(
            provider: provider, modelID: model.id, attachments: [RelayNegCacheSend.imageAttachment()]
        )
        #expect(message.state == .failed)
        let urls = RelayNegCacheScriptedProtocol.urls
        #expect(urls.count == 1, "\(urls)")
        #expect(urls.first?.path.hasSuffix("/messages") == true, "the first send goes through Messages: \(urls)")
        #expect(RelayNegativeCache.shared.isRejected(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: RelayTransport.anthropicMessages.rawValue, kind: .image
        ), "write key = protocol actually used for the first send")

        // A rejection does not record observed: the model still has no protocol, so the next first send is again Messages and the read side must look up the same key.
        let storedProvider = try #require(state.provider(for: provider.id))
        let stored = try #require(storedProvider.models.first { $0.id == model.id })
        #expect(stored.relayTransport == nil)
        #expect(!photoEntryVisible(provider: storedProvider, model: stored, cache: .shared), "the vision entry is hidden by the negative entry")
        let board = RelayModelAdvancedBoard.make(
            provider: storedProvider, model: stored, partitionID: "relay-negative-cache-tests"
        )
        let imageRow = try #require(board.capabilityRows.first { $0.capability == .image })
        #expect(imageRow.source == .detected, "the advanced page's vision row reads the same negative entry")
    }

    @Test("RL2-NEGCACHE-04 production send: a 404 from a user-sourced protocol does not switch; after one switch a second 404 reports the second error and does not switch again")
    @MainActor
    func rl2NegCache04ProductionUserSourceAndOnlyOnce() async throws {
        await MetadataClient.shared.resetForTesting()
        let userModel = plainModel("relay-user-model", transport: .openaiResponses, source: .user)
        let userProvider = relayProvider(transport: .openaiChatCompletions, models: [userModel])
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])
        let (userState, userMessage) = try await RelayNegCacheSend.send(provider: userProvider, modelID: userModel.id)
        #expect(userMessage.state == .failed)
        #expect(RelayNegCacheScriptedProtocol.urls.count == 1)
        let userStored = try #require(userState.provider(for: userProvider.id)?.models.first { $0.id == userModel.id })
        #expect(userStored.relayTransport == .openaiResponses)
        #expect(userStored.relayTransportSource == .user)

        let model = plainModel("relay-once-model", transport: .openaiResponses, source: .reachable)
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"FIRST-404"}}"#),
            .json(status: 404, body: #"{"error":{"message":"SECOND-404"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])
        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id)
        #expect(message.state == .failed)
        #expect(RelayNegCacheScriptedProtocol.urls.count == 2, "a message switches at most once")
        let shown = (message.errorDetail ?? "") + message.text
        #expect(shown.contains("SECOND-404"), "\(shown)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiResponses)
        #expect(stored.relayTransportSource == .reachable)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id))
    }

    private func pdfModel(_ id: String) -> AIModel {
        var model = AIModel(
            id: id, name: id, capabilities: [.text, .file],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "",
            nativeFileMimes: ["application/pdf"], pdfNativeDefault: true
        )
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .reachable
        return model
    }

    @Test("RL2-NEGCACHE-04 on a protocol switch the request body is rebuilt for the new protocol: Responses + native PDF 404 -> Chat sends the text fallback without the native block")
    @MainActor
    func rl2NegCache04SwitchRebuildsNativeFileDelivery() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-pdf-model")
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let pdf = Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "report.pdf", mimeType: "application/pdf",
            base64Data: Data("EXTRACTED-PDF-BODY".utf8).base64EncodedString(),
            extractedSizeBytes: 5_000, originalBase64Data: "JVBERi0xLjQ="
        )
        // The first native-block send gets a 404 -> the inner layer falls back to text under the original protocol and still gets a 404 -> the outer layer switches to Chat.
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .json(status: 404, body: #"{"error":{"message":"not found"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])
        let (_, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id, attachments: [pdf])
        #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
        let urls = RelayNegCacheScriptedProtocol.urls
        let bodies = RelayNegCacheScriptedProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }
        #expect(urls.count == 3, "\(urls)")
        #expect(bodies.first?.contains("JVBERi0xLjQ=") == true, "Precondition: the first send is a native PDF block")
        #expect(urls.last?.path.hasSuffix("/chat/completions") == true, "\(urls)")
        let switched = try #require(bodies.last)
        #expect(!switched.contains("JVBERi0xLjQ="), "after switching to Chat the PDF must not be sent as a native block")
        #expect(switched.contains("EXTRACTED-PDF-BODY"), "\(switched.prefix(600))")
    }

    @Test("RL2-NEGCACHE-04 every file is a scan with no extractable text and the new protocol does not accept native files: the protocol is not switched and the original error is reported")
    @MainActor
    func rl2NegCache04ScannedOnlyDoesNotSwitch() async throws {
        try await loadSharedMetadata()
        let model = pdfModel("relay-scan-model")
        let provider = relayProvider(transport: .openaiChatCompletions, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        let scan = Oriveo.Attachment(
            id: UUID(), kind: .file, fileName: "scan.pdf", mimeType: "application/pdf",
            extractedSizeBytes: 5_000, extractionErrorCode: "scanned_pdf", originalBase64Data: "JVBERi0xLjQ="
        )
        RelayNegCacheScriptedProtocol.reset([
            .json(status: 404, body: #"{"error":{"message":"ORIGINAL-404"}}"#),
            .sse(body: RelayNegCacheSend.chatOK),
        ])
        let (state, message) = try await RelayNegCacheSend.send(provider: provider, modelID: model.id, attachments: [scan])
        #expect(message.state == .failed)
        #expect(RelayNegCacheScriptedProtocol.urls.count == 1, "\(RelayNegCacheScriptedProtocol.urls)")
        let stored = try #require(state.provider(for: provider.id)?.models.first { $0.id == model.id })
        #expect(stored.relayTransport == .openaiResponses)
    }

    @Test("RL2-NEGCACHE-03 imageRecordCases: image is recorded only for a rejected result where the request carried an image, there is no positive vision evidence, no output has started and the protocol was not switched")
    @MainActor
    func rl2NegCache03ImageRecordCases() throws {
        let cases = try #require(try loadFixture()["imageRecordCases"] as? [[String: Any]])
        #expect(cases.count == 7)
        let rejected = RelayPreOutputRejection(status: 400, contentType: "application/json", body: Data(#"{"error":{"message":"x"}}"#.utf8))
        let undetermined = RelayPreOutputRejection(status: 503, contentType: "application/json", body: Data())
        for item in cases {
            let caseID = try string(item["caseId"])
            let cache = makeCache()
            var model = plainModel("relay-image-record")
            if try #require(item["modelDeclaresImage"] as? Bool) { model.capabilities.append(.image) }
            let engineImage = item["engineDeclarationImage"] as? Bool
            if let engineImage { model.engineDeclaration = EngineDeclaration(image: engineImage) }
            if let override = item["override"] as? [String: Any] {
                model.relayCapabilityOverrides = RelayCapabilityOverrides(
                    image: try #require(override["value"] as? Bool),
                    source: try #require(RelayCapabilityOverrides.Source(rawValue: try string(override["source"])))
                )
            }
            let provider = relayProvider(
                transport: .openaiChatCompletions, models: [model],
                engineProfile: engineImage == nil ? nil : "ollama"
            )
            let written = RelayRejectionRecording.recordImageRejection(
                provider: provider, model: model, transport: .openaiChatCompletions,
                rejection: try #require(item["rejected"] as? Bool) ? rejected : undetermined,
                outputStarted: try #require(item["outputStarted"] as? Bool),
                protocolSwitched: try #require(item["protocolSwitched"] as? Bool),
                negativeCache: cache
            )
            let expected = try #require(item["expectRecord"] as? Bool)
            #expect(written == expected, "\(caseID)")
            #expect(cache.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayTransport.openaiChatCompletions.rawValue, kind: .image
            ) == expected, "\(caseID)")
        }
    }

    @Test("RL2-NEGCACHE-03 production path: when the model's capabilities include image (inherited / declared) a rejected image send does not record image and shows no hint card")
    @MainActor
    func rl2NegCache03DeclaredCapabilityDoesNotRecordInProduction() async throws {
        try await loadSharedMetadata()
        var model = plainModel("relay-vision-declared")
        model.capabilities = [.text, .image]
        let provider = relayProvider(transport: .openaiResponses, models: [model])
        defer { RelayNegativeCache.shared.clearConnection(provider.id.uuidString) }
        RelayNegCacheScriptedProtocol.reset([.json(status: 400, body: #"{"error":{"message":"bad request"}}"#)])
        let (_, message) = try await RelayNegCacheSend.send(
            provider: provider, modelID: model.id, attachments: [RelayNegCacheSend.imageAttachment()]
        )
        #expect(message.state == .failed)
        #expect(!anyEntry(.shared, connection: provider.id, modelID: model.id))
        #expect(message.recoveryPrimaryAction == nil)
    }
}
