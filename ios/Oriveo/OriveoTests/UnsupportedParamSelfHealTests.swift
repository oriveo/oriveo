import Foundation
import Testing
@testable import Oriveo

private actor SelfHealRequestRecorder {
    private var requests: [URLRequest] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private let shouldBlock: Bool

    init(shouldBlock: Bool = false) {
        self.shouldBlock = shouldBlock
    }

    func send(_ request: URLRequest) async {
        requests.append(request)
        guard shouldBlock else { return }
        await withCheckedContinuation { continuation in
            blocked.append(continuation)
        }
    }

    func firstRequest() -> URLRequest? { requests.first }
    func count() -> Int { requests.count }
    func blockedCount() -> Int { blocked.count }

    func releaseAll() {
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private func waitForSelfHealRequest(
    _ recorder: SelfHealRequestRecorder,
    timeout: Duration = .seconds(1)
) async -> URLRequest? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let request = await recorder.firstRequest() { return request }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await recorder.firstRequest()
}

private func selfHealIdentity(
    providerKind: ProviderKind,
    modelID: String,
    transport: String
) -> CapabilityEvidenceRequestIdentity {
    CapabilityEvidenceRequestIdentity(query: .init(
        partitionID: "test-partition",
        connectionInstanceID: "test-connection",
        connectionGeneration: "test-connection-generation",
        credentialEpoch: "test-credential-epoch",
        providerKind: providerKind.rawValue,
        modelID: modelID,
        effectiveTransport: transport,
        endpointFingerprint: nil,
        metadataRevision: "test-metadata-etag",
        generationRevision: "test-generation-revision",
        now: 1_000,
        hasExplicitValue: true
    ))
}

private func scopedSelfHealIdentity(
    _ identity: CapabilityEvidenceRequestIdentity,
    from snapshot: ScriptedSelfHealProtocol.Snapshot
) throws -> CapabilityEvidenceRequestIdentity {
    let url = try #require(snapshot.urls.first ?? nil)
    return try #require(identity.resolvingFinalEndpoint(url))
}

private func productionSelfHealScope(
    providerKind: ProviderKind,
    modelID: String,
    relayTransport: RelayTransport? = nil,
    reasoningProfile: String? = nil,
    webSearchProfile: String? = nil
) -> (identity: CapabilityEvidenceRequestIdentity, options: ChatRequestOptions) {
    var persisted = TestFactories.makeModel(
        id: modelID,
        capabilities: [.text, .reasoning, .web],
        reasoningModeAvailable: true
    )
    if providerKind == .relay {
        persisted.reasoningProfile = reasoningProfile
        persisted.webSearchProfile = webSearchProfile
    }
    let model = providerKind == .relay
        ? persisted
        : MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            persisted,
            providerKind: providerKind
        )
    let provider = TestFactories.makeProvider(kind: providerKind, models: [model])
    var options = ChatRequestOptions()
    options.capabilityEvidenceModel = model
    return (
        CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: "self-heal-production-test",
            hasExplicitValue: true,
            effectiveTransport: relayTransport?.rawValue
        ),
        options
    )
}

@Suite("Unsupported-param self-heal • classifier", .serialized)
struct UnsupportedParamClassifierTests {

    @Test("Exact Runtime Identity Deduplicates Producer Side Effects")
    func exactRuntimeIdentityDeduplicatesProducerSideEffects() async throws {
        UnsupportedParamCache.shared.resetForTesting()

        let identity = try #require(selfHealIdentity(
            providerKind: .openAI, modelID: "gpt-5", transport: "openai_responses"
        ).resolvingFinalEndpoint(URL(string: "https://api.openai.com/v1/responses")!))
        #expect(UnsupportedParamSelfHealReporter.markDropped(
            providerKind: .openAI, modelID: "gpt-5", param: "temperature",
            endpointFingerprint: identity.query.endpointFingerprint, identity: identity
        ))

        #expect(!UnsupportedParamSelfHealReporter.markDropped(
            providerKind: .openAI, modelID: "gpt-5", param: "temperature",
            endpointFingerprint: identity.query.endpointFingerprint, identity: identity
        ))
    }

    @Test("Xai Pattern")
    func xaiPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400,
            detail: "Model grok-4.20-0309-non-reasoning does not support parameter reasoningEffort."
        ) == "reasoning_effort")
    }

    @Test("Open AIUnsupported Parameter Pattern")
    func openAIUnsupportedParameterPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400,
            detail: "Unsupported parameter: 'temperature' is not supported with this model."
        ) == "temperature")
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400,
            detail: "Unsupported parameter: 'reasoning.summary' is not supported with this model."
        ) == "reasoning.summary")
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400,
            detail: "Unsupported value: 'xhigh' is not supported with this model."
        ) == nil)
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400,
            detail: "unsupported parameters are ignored"
        ) == nil)
    }

    @Test("Open AIPattern")
    func openAIPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "Unrecognized request argument supplied: foo_bar"
        ) == "foo_bar")
    }

    @Test("Generic Pattern")
    func genericPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "unknown parameter: enable_thinking"
        ) == "enable_thinking")
    }

    @Test("Anthropic Unexpected Pattern")
    func anthropicUnexpectedPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: #"{"error":{"message":"unexpected field: thinking"}}"#
        ) == "thinking")
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "unexpected parameter: reasoning"
        ) == "reasoning")
    }

    @Test("Gemini Pattern")
    func geminiPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "Invalid JSON payload received. Unknown name \"thinkingConfig\": Cannot find field."
        ) == "thinking_config")
    }

    @Test("Dotted Path Pattern")
    func dottedPathPattern() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "unknown parameter: generationConfig.thinkingConfig"
        ) == "generation_config.thinking_config")
    }

    @Test("Non Bad Request Ignored")
    func nonBadRequestIgnored() {
        let detail = "does not support parameter reasoningEffort"
        #expect(UnsupportedParamClassifier.parameterName(status: 500, detail: detail) == nil)
        #expect(UnsupportedParamClassifier.parameterName(status: 429, detail: detail) == nil)
        #expect(UnsupportedParamClassifier.parameterName(status: 403, detail: detail) == nil)
    }

    @Test("No Match Returns Nil")
    func noMatchReturnsNil() {
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "Each message must have at least one content element"
        ) == nil)
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: nil) == nil)
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: "") == nil)
    }

    @Test("Normalize")
    func normalize() {
        #expect(UnsupportedParamClassifier.normalize("reasoningEffort") == "reasoning_effort")
        #expect(UnsupportedParamClassifier.normalize("reasoning_effort") == "reasoning_effort")
        #expect(UnsupportedParamClassifier.normalize("serviceTier") == "service_tier")
    }

    @Test("Request Body Strip Unsupported Params")
    func requestBodyStripUnsupportedParams() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "reasoning_effort": "high",
            "reasoning": ["effort": "high", "summary": "auto"],
            "generationConfig": ["thinkingConfig": ["includeThoughts": true], "temperature": 0.7],
        ])

        let body = try #require(UnsupportedParamJSON.strippedBody(
            original, dropping: ["reasoning_effort", "generation_config.thinking_config"]
        ))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning_effort"] == nil)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] == nil)
        #expect(reasoning["summary"] as? String == "auto")
        let generationConfig = try #require(json["generationConfig"] as? [String: Any])
        #expect(generationConfig["thinkingConfig"] == nil)
        #expect(generationConfig["temperature"] as? Double == 0.7)
    }

    @Test("Object Strip Unsupported Params Prunes Empty Objects")
    func objectStripUnsupportedParamsPrunesEmptyObjects() throws {
        let stripped = try #require(UnsupportedParamJSON.strippedObject([
            "reasoning": ["effort": "high"],
            "temperature": 0.7,
        ], dropping: ["reasoning_effort"], pruneEmptyObjects: true))

        #expect(stripped["reasoning"] == nil)
        #expect(stripped["temperature"] as? Double == 0.7)
    }

    @Test("Object Strip Preserves Schema Properties")
    func objectStripPreservesSchemaProperties() throws {
        let stripped = try #require(UnsupportedParamJSON.strippedObject([
            "temperature": 0.7,
            "tools": [[
                "type": "function",
                "function": [
                    "name": "search",
                    "parameters": [
                        "type": "object",
                        "properties": ["temperature": ["type": "number"]],
                    ],
                ],
            ]],
        ], dropping: ["temperature"]))
        #expect(stripped["temperature"] == nil)
        let tools = try #require(stripped["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["temperature"] != nil)
    }

    @Test("Cache Canonicalizes Param Names")
    func cacheCanonicalizesParamNames() throws {
        UnsupportedParamCache.shared.resetForTesting()
        let identity = try #require(selfHealIdentity(
            providerKind: .grok, modelID: "grok-4.20", transport: "openai_chat"
        ).resolvingFinalEndpoint(URL(string: "https://api.x.ai/v1/chat/completions")!))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .grok,
            modelID: "grok-4.20",
            param: "reasoningEffort",
            endpointFingerprint: identity.query.endpointFingerprint,
            identity: identity
        ))
        #expect(UnsupportedParamCache.shared.isUnsupported(
            providerKind: .grok,
            modelID: "grok-4.20",
            param: "reasoning_effort",
            endpointFingerprint: identity.query.endpointFingerprint,
            identity: identity
        ))
        #expect(!UnsupportedParamCache.shared.markUnsupported(
            providerKind: .grok,
            modelID: "grok-4.20",
            param: "reasoning_effort",
            endpointFingerprint: identity.query.endpointFingerprint,
            identity: identity
        ))
        #expect(UnsupportedParamCache.shared.droppedParams(
            providerKind: .grok,
            modelID: "grok-4.20",
            endpointFingerprint: identity.query.endpointFingerprint,
            identity: identity
        ) == ["reasoning_effort"])
    }

    @Test("Relay Cache Is Endpoint Scoped")
    func relayCacheIsEndpointScoped() throws {
        UnsupportedParamCache.shared.resetForTesting()
        let first = try #require(selfHealIdentity(
            providerKind: .relay, modelID: "same-model", transport: "openai_chat"
        ).resolvingFinalEndpoint(URL(string: "https://relay.example/v1/chat/completions")!))
        let second = try #require(selfHealIdentity(
            providerKind: .relay, modelID: "same-model", transport: "openai_chat"
        ).resolvingFinalEndpoint(URL(string: "https://relay.example/v1/other")!))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .relay,
            modelID: "same-model",
            param: "temperature",
            endpointFingerprint: first.query.endpointFingerprint,
            identity: first
        ))
        #expect(UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay,
            modelID: "same-model",
            param: "temperature",
            endpointFingerprint: first.query.endpointFingerprint,
            identity: first
        ))
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay,
            modelID: "same-model",
            param: "temperature",
            endpointFingerprint: second.query.endpointFingerprint,
            identity: second
        ))
    }

    @Test("Cache Key Escapes Field Separators")
    func cacheKeyEscapesFieldSeparators() throws {
        UnsupportedParamCache.shared.resetForTesting()
        //   A: …|same-model|openai_chat|x|…   (modelID="same-model|openai_chat", transport="x")
        //   B: …|same-model|openai_chat|x|…   (modelID="same-model", transport="openai_chat|x")
        let url = URL(string: "https://relay.example/v1/chat/completions")!
        let first = try #require(selfHealIdentity(
            providerKind: .relay, modelID: "same-model|openai_chat", transport: "x"
        ).resolvingFinalEndpoint(url))
        let second = try #require(selfHealIdentity(
            providerKind: .relay, modelID: "same-model", transport: "openai_chat|x"
        ).resolvingFinalEndpoint(url))
        #expect(UnsupportedParamCache.shared.markUnsupported(
            providerKind: .relay,
            modelID: "same-model|openai_chat",
            param: "temperature",
            endpointFingerprint: first.query.endpointFingerprint,
            identity: first
        ))
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .relay,
            modelID: "same-model",
            param: "temperature",
            endpointFingerprint: second.query.endpointFingerprint,
            identity: second
        ))
        #expect(UnsupportedParamCache.shared.droppedParams(
            providerKind: .relay,
            modelID: "same-model",
            endpointFingerprint: second.query.endpointFingerprint,
            identity: second
        ).isEmpty, "hasPrefix scanning must not apply params stripped on connection A to connection B")
    }

    @Test("Base Raw Rejection Never Strips Or Retries")
    func baseRawRejectionNeverStripsOrRetries() async throws {
        ScriptedSelfHealProtocol.reset()
        UnsupportedParamCache.shared.resetForTesting()
        ScriptedSelfHealProtocol.script = [
            .json(status: 400, body: #"{"error":{"message":"unknown parameter: tools"}}"#),
            .json(status: 200, body: #"{"ok":true}"#),
        ]

        let initialIdentity = selfHealIdentity(
            providerKind: .grok, modelID: "grok-4.20", transport: "openai_responses"
        )
        let service = BaseAPIService(session: makeScriptedSession())
        do {
            _ = try await CapabilityEvidenceRequestContext.$current.withValue(initialIdentity) {
                try await service.performRawWithUnsupportedParamSelfHeal(
                    providerKind: .grok,
                    modelID: "grok-4.20"
                ) { dropped in
                    #expect(dropped.isEmpty)
                    var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!)
                    request.httpMethod = "POST"
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": "grok-4.20",
                        "tools": [["type": "web_search"]],
                        "reasoning": ["summary": "auto"],
                    ])
                    return request
                }
            }
            Issue.record("400 must surface without a second attempt")
        } catch {
            #expect(error is ProviderServiceError)
        }

        let bodies = ScriptedSelfHealProtocol.snapshot().bodies
        #expect(bodies.count == 1)
        let first = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(first["tools"] != nil)
        #expect((first["reasoning"] as? [String: Any])?["summary"] as? String == "auto")
        let identity = try scopedSelfHealIdentity(initialIdentity, from: ScriptedSelfHealProtocol.snapshot())
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .grok, modelID: "grok-4.20", param: "tools",
            endpointFingerprint: identity.query.endpointFingerprint, identity: identity
        ))
    }

    @Test("Failed Raw Request Does Not Poison Cache")
    func failedRawRequestDoesNotPoisonCache() async {
        ScriptedSelfHealProtocol.reset()
        UnsupportedParamCache.shared.resetForTesting()
        ScriptedSelfHealProtocol.script = [
            .json(status: 400, body: #"{"error":{"message":"unknown parameter: temperature"}}"#),
            .json(status: 400, body: #"{"error":{"message":"request remains invalid"}}"#),
        ]

        let service = BaseAPIService(session: makeScriptedSession())
        do {
            _ = try await service.performRawWithUnsupportedParamSelfHeal(
                providerKind: .grok,
                modelID: "grok-failed-retry"
            ) { _ in
                var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "grok-failed-retry",
                    "temperature": 0.7,
                ])
                return request
            }
            Issue.record("The second 400 must keep the upstream failure")
        } catch {
            #expect(ScriptedSelfHealProtocol.snapshot().bodies.count == 1)
            #expect(!UnsupportedParamCache.shared.isUnsupported(
                providerKind: .grok,
                modelID: "grok-failed-retry",
                param: "temperature"
            ))
        }
    }

    @Test("Compatibility Stream Wrapper Never Retries")
    func compatibilityStreamWrapperNeverRetries() async {
        nonisolated(unsafe) var attempts = 0
        let stream: AsyncThrowingStream<String, Error> = UnsupportedParamSelfHeal.wrapStream(
            providerKind: .openAI,
            modelID: "gpt-fixture"
        ) { dropped in
            attempts += 1
            #expect(dropped.isEmpty)
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderServiceError.upstream(
                    statusCode: 400, detail: "fixture"
                ))
            }
        }
        do {
            for try await _ in stream {}
            Issue.record("400 must surface")
        } catch {
            #expect(attempts == 1)
        }
    }


    @Test("Delivered Pattern Hits Via Metadata Wiring")
    func deliveredPatternHitsViaMetadataWiring() async throws {
        await MetadataClient.shared.resetForTesting()

        let novelDetail = #"{"error":"Argument reasoning_effort is not permitted for this model"}"#
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: novelDetail) == nil)

        try await MetadataClient.shared.loadForTesting(json: Self.metadataJSON(selfHealPatterns: #"""
        [{"pattern":"Argument (reasoning_effort) is not permitted","flags":"i"}]
        """#))
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: novelDetail) == "reasoning_effort")

        await MetadataClient.shared.resetForTesting()
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: novelDetail) == nil)
    }

    @Test("Delivered Pattern Defensive Skip")
    func deliveredPatternDefensiveSkip() {
        defer { UnsupportedParamClassifier.setRuntimePatterns([]) }
        UnsupportedParamClassifier.setRuntimePatterns([
            SelfHealPatternDefinition(pattern: "(", flags: "i"),
            SelfHealPatternDefinition(pattern: "", flags: nil),
            SelfHealPatternDefinition(pattern: String(repeating: "a", count: 201), flags: nil),
            SelfHealPatternDefinition(pattern: #"blocked field (\w+)"#, flags: "i"),
        ])

        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: "blocked field temperature") == "temperature")
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: "does not support parameter foo") == "foo")
    }

    /// `Your organization must be verified to generate reasoning summaries`,
    @Test("Delivered Fixed Param Without Capture Group")
    func deliveredFixedParamWithoutCaptureGroup() {
        defer { UnsupportedParamClassifier.setRuntimePatterns([]) }
        let detail = #"{"error":{"message":"Your organization must be verified to generate reasoning summaries"}}"#
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: detail) == nil)

        UnsupportedParamClassifier.setRuntimePatterns([
            SelfHealPatternDefinition(
                pattern: "must be verified to generate reasoning summaries",
                flags: "i",
                param: "reasoning.summary"
            ),
        ])
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: detail) == "reasoning.summary")
        #expect(UnsupportedParamClassifier.parameterName(status: 500, detail: detail) == nil)
    }

    @Test("Capture Group Wins Over Fixed Param")
    func captureGroupWinsOverFixedParam() {
        defer { UnsupportedParamClassifier.setRuntimePatterns([]) }
        UnsupportedParamClassifier.setRuntimePatterns([
            SelfHealPatternDefinition(
                pattern: #"blocked field (\w+)"#,
                flags: "i",
                param: "reasoning.summary"
            ),
        ])
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "blocked field temperature") == "temperature")
    }

    @Test("Malformed Fixed Param Is Dropped")
    func malformedFixedParamIsDropped() {
        defer { UnsupportedParamClassifier.setRuntimePatterns([]) }
        UnsupportedParamClassifier.setRuntimePatterns([
            SelfHealPatternDefinition(pattern: "must be verified", flags: "i", param: "reasoning summary"),
            SelfHealPatternDefinition(pattern: "quota exhausted", flags: "i", param: String(repeating: "a", count: 65)),
        ])
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: "must be verified") == nil)
        #expect(UnsupportedParamClassifier.parameterName(status: 400, detail: "quota exhausted") == nil)
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "does not support parameter foo") == "foo")
    }

    @Test("Fixed Param Strips Nested Summary")
    func fixedParamStripsNestedSummary() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "o4-mini",
            "reasoning": ["effort": "medium", "summary": "auto"],
        ])
        let stripped = try #require(UnsupportedParamJSON.strippedBody(body, dropping: ["reasoning.summary"]))
        let decoded = try #require(try JSONSerialization.jsonObject(with: stripped) as? [String: Any])
        let reasoning = try #require(decoded["reasoning"] as? [String: Any])
        #expect(reasoning["summary"] == nil)
        #expect(reasoning["effort"] as? String == "medium")
    }

    @Test("No Delivery Matches Baseline")
    func noDeliveryMatchesBaseline() {
        UnsupportedParamClassifier.setRuntimePatterns([])
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "does not support parameter reasoningEffort") == "reasoning_effort")
        #expect(UnsupportedParamClassifier.parameterName(
            status: 400, detail: "Argument reasoning_effort is not permitted") == nil)
    }

    private static func metadataJSON(selfHealPatterns: String) -> String {
        """
        {
          "version": 1,
          "providers": {},
          "runtimeConfig": { "selfHealPatterns": \(selfHealPatterns) }
        }
        """
    }

    private func makeScriptedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedSelfHealProtocol.self]
        return URLSession(configuration: config)
    }
}


@Suite("Unsupported-param self-heal • Grok production single-attempt", .serialized)
struct GrokSelfHealTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedSelfHealProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeMessage() -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .grok,
            providerName: ProviderKind.grok.displayName, modelName: "grok-fixture", state: .delivered
        )
    }

    @Test("Grok production stream surfaces 400 after one original request and learns no broad cache")
    func rejectionNeverStripsOrRetries() async throws {
        ScriptedSelfHealProtocol.reset()
        UnsupportedParamCache.shared.resetForTesting()
        defer {
            ScriptedSelfHealProtocol.reset()
            UnsupportedParamCache.shared.resetForTesting()
        }
        ScriptedSelfHealProtocol.script = [
            .json(status: 400, body: #"{"error":{"message":"unknown parameter: reasoning_effort"}}"#),
            .sse(status: 200, body: "data: [DONE]\n\n"),
        ]

        var thrown: Error?
        do {
            for try await _ in GrokService(session: makeSession()).sendMessageStream(
                apiKey: "fixture-key", modelID: "grok-fixture", messages: [makeMessage()],
                reasoningMode: .deep
            ) {}
        } catch {
            thrown = error
        }

        let snapshot = ScriptedSelfHealProtocol.snapshot()
        #expect(snapshot.bodies.count == 1)
        #expect(thrown != nil)
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .grok, modelID: "grok-fixture", param: "reasoning_effort"
        ))
    }

    @Test("Grok production success stream remains one request")
    func successStreamPassesThrough() async throws {
        ScriptedSelfHealProtocol.reset()
        ScriptedSelfHealProtocol.script = [
            .sse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n"),
        ]
        var text = ""
        for try await event in GrokService(session: makeSession()).sendMessageStream(
            apiKey: "fixture-key", modelID: "grok-fixture", messages: [makeMessage()]
        ) {
            if case .delta(let value) = event { text += value }
        }
        #expect(ScriptedSelfHealProtocol.snapshot().bodies.count == 1)
        #expect(text == "hello")
    }
}

@Suite("Unsupported-param self-heal • official production single-attempt", .serialized)
struct OfficialAndRelaySelfHealCoverageTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedSelfHealProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("BaseAPI official raw request preserves original body and sends once")
    func officialBaseRawPreservesBodyAndSurfacesError() async throws {
        ScriptedSelfHealProtocol.reset()
        UnsupportedParamCache.shared.resetForTesting()
        ScriptedSelfHealProtocol.script = [
            .json(status: 400, body: #"{"error":{"message":"unknown parameter: reasoning"}}"#),
            .json(status: 200, body: #"{"ok":true}"#),
        ]
        let service = BaseAPIService(session: makeSession())
        do {
            _ = try await service.performRawWithUnsupportedParamSelfHeal(
                providerKind: .openAI, modelID: "gpt-fixture"
            ) { dropped in
                #expect(dropped.isEmpty)
                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "gpt-fixture", "reasoning": ["effort": "high"],
                ])
                return request
            }
            Issue.record("400 must surface")
        } catch {
            #expect(error is ProviderServiceError)
        }
        let bodies = ScriptedSelfHealProtocol.snapshot().bodies
        #expect(bodies.count == 1)
        let body = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .openAI, modelID: "gpt-fixture", param: "reasoning"
        ))
    }

    @Test("OpenAI production stream does not turn an unstructured 400 into retry or negative evidence")
    func openAIStreamUnstructured400StaysSingleAttempt() async throws {
        ScriptedSelfHealProtocol.reset()
        UnsupportedParamCache.shared.resetForTesting()
        ScriptedSelfHealProtocol.script = [
            .json(status: 400, body: #"{"error":{"message":"unknown parameter: tools"}}"#),
            .sse(status: 200, body: "data: [DONE]\n\n"),
        ]
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello", providerKind: .openAI,
            providerName: ProviderKind.openAI.displayName, modelName: "gpt-fixture", state: .delivered
        )
        var thrown: Error?
        do {
            for try await _ in OpenAIService(session: makeSession()).sendMessageStream(
                apiKey: "fixture-key", modelID: "gpt-fixture", messages: [message],
                reasoningMode: .deep, webSearchEnabled: true,
                supportsImageGeneration: false, requestOptions: .init()
            ) {}
        } catch {
            thrown = error
        }
        #expect(ScriptedSelfHealProtocol.snapshot().bodies.count == 1)
        #expect(thrown != nil)
        #expect(!UnsupportedParamCache.shared.isUnsupported(
            providerKind: .openAI, modelID: "gpt-fixture", param: "tools"
        ))
    }
}
@Suite("Unsupported-param self-heal • OpenAI-compatible reasoning gate", .serialized)
struct OpenAICompatibleReasoningGateTests {
    private let cases: [(ProviderKind, String)] = [
        (.groq, "groq-test-model"),
        (.together, "together-test-model"),
        (.fireworks, "fireworks-test-model"),
    ]

    @Test("No Reasoning Profile Skips Reasoning Effort")
    func noReasoningProfileSkipsReasoningEffort() async throws {
        for (kind, modelID) in cases {
            ScriptedSelfHealProtocol.reset()
            UnsupportedParamCache.shared.resetForTesting()
            try await loadMetadata(kind: kind, modelID: modelID, reasoningProfile: nil)
            ScriptedSelfHealProtocol.script = [
                .sse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n"),
            ]

            let scope = productionSelfHealScope(providerKind: kind, modelID: modelID)
            try await CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
                try await drain(streamFor(
                    kind: kind,
                    session: makeMockSession(),
                    modelID: modelID,
                    reasoningMode: .deep,
                    requestOptions: scope.options
                ))
            }

            let body = try requestBody(at: 0)
            #expect(body["reasoning_effort"] == nil)
        }
    }

    @Test("Legacy Reasoning Profile Cannot Revive Automatic Field")
    func legacyReasoningProfileCannotReviveAutomaticField() async throws {
        for (kind, modelID) in cases {
            ScriptedSelfHealProtocol.reset()
            UnsupportedParamCache.shared.resetForTesting()
            try await loadMetadata(kind: kind, modelID: modelID, reasoningProfile: "oai_chat")
            ScriptedSelfHealProtocol.script = [
                .sse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n"),
            ]

            let scope = productionSelfHealScope(providerKind: kind, modelID: modelID)
            try await CapabilityEvidenceRequestContext.$current.withValue(scope.identity) {
                try await drain(streamFor(
                    kind: kind,
                    session: makeMockSession(),
                    modelID: modelID,
                    reasoningMode: .deep,
                    requestOptions: scope.options
                ))
            }

            let body = try requestBody(at: 0)
            #expect(body["reasoning_effort"] == nil)
        }
    }

    private func loadMetadata(kind: ProviderKind, modelID: String, reasoningProfile: String?) async throws {
        await MetadataClient.shared.resetForTesting()
        let profileJson = reasoningProfile.map { #","profiles":{"reasoning":"\#($0)"}"# } ?? ""
        let providerKey = metadataProviderKey(for: kind)
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-07-03T00:00:00Z",
          "profiles": {
            "reasoning": {
              "oai_chat": {
                "transport": "chat_completions",
                "levels": ["deep"],
                "params": {
                  "deep": { "reasoning_effort": "high" }
                }
              }
            },
            "webSearch": {},
            "imageGen": {}
          },
          "providers": {
            "\(providerKey)": {
              "displayName": "\(kind.displayName)",
              "defaultModelId": "\(modelID)",
              "resolveMap": {
                "\(modelID)": "\(modelID)"
              },
              "models": {
                "\(modelID)": {
                  "canonicalModelId": "\(modelID)",
                  "displayName": "\(modelID)",
                  "capabilities": ["text", "reasoning"],
                  "transport": "openai_chat"\(profileJson)
                }
              }
            }
          }
        }
        """, metadataETag: "\(kind.rawValue)-reasoning-gate-etag")
    }

    private func metadataProviderKey(for kind: ProviderKind) -> String {
        switch kind {
        case .together: return "togetherAI"
        case .fireworks: return "fireworksAI"
        default: return kind.rawValue
        }
    }

    private func streamFor(
        kind: ProviderKind,
        session: URLSession,
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            text: "hello",
            providerKind: kind,
            providerName: kind.displayName,
            modelName: modelID,
            state: .delivered
        )
        switch kind {
        case .groq:
            return GroqService(session: session).sendMessageStream(
                apiKey: "test-key",
                modelID: modelID,
                messages: [message],
                reasoningMode: reasoningMode,
                requestOptions: requestOptions
            )
        case .together:
            return TogetherService(session: session).sendMessageStream(
                apiKey: "test-key",
                modelID: modelID,
                messages: [message],
                reasoningMode: reasoningMode,
                requestOptions: requestOptions
            )
        case .fireworks:
            return FireworksService(session: session).sendMessageStream(
                apiKey: "test-key",
                modelID: modelID,
                messages: [message],
                reasoningMode: reasoningMode,
                requestOptions: requestOptions
            )
        default:
            Issue.record("Unsupported provider in gate test: \(kind.rawValue)")
            return AsyncThrowingStream { $0.finish() }
        }
    }

    private func drain(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws {
        for try await _ in stream {}
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedSelfHealProtocol.self]
        return URLSession(configuration: config)
    }

    private func requestBody(at index: Int) throws -> [String: Any] {
        let snap = ScriptedSelfHealProtocol.snapshot()
        let body = try #require(snap.bodies.indices.contains(index) ? snap.bodies[index] : nil)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}


private final class ScriptedSelfHealProtocol: URLProtocol, @unchecked Sendable {
    enum ScriptedResponse {
        case json(status: Int, body: String)
        case sse(status: Int, body: String)
    }

    struct Snapshot {
        let bodies: [Data]
        let urls: [URL?]
    }

    nonisolated(unsafe) static var script: [ScriptedResponse] = []
    nonisolated(unsafe) private static var _bodies: [Data] = []
    nonisolated(unsafe) private static var _urls: [URL?] = []
    nonisolated(unsafe) private static var _index: Int = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        script = []; _bodies = []; _urls = []; _index = 0
    }

    static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bodies: _bodies, urls: _urls)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = request
        var bodyData: Data?
        if let stream = captured.httpBodyStream {
            stream.open()
            var acc = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                acc.append(buf, count: n)
            }
            stream.close()
            bodyData = acc
        } else if let body = captured.httpBody {
            bodyData = body
        }

        let response: ScriptedResponse = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            if let b = bodyData { Self._bodies.append(b) }
            Self._urls.append(captured.url)
            let idx = Self._index
            Self._index += 1
            if idx < Self.script.count { return Self.script[idx] }
            return .sse(status: 200, body: "data: [DONE]\n\n")
        }()

        let (status, contentType, body): (Int, String, String) = {
            switch response {
            case .json(let s, let b): return (s, "application/json", b)
            case .sse(let s, let b): return (s, "text/event-stream", b)
            }
        }()
        let httpResp = HTTPURLResponse(
            url: captured.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.data(using: .utf8) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
