import Foundation
import Testing
@testable import Oriveo

/// Fake server: records every request and answers through a handler. `hang` never sends response headers; `drip` sends 200 SSE headers and then one comment line every 100 ms.
private final class RelayCapabilityFakeServer: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, contentType: String, body: Data)
        case network
        case hang
        case drip
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest, Data?) -> Reply)?
    nonisolated(unsafe) private static var requests: [(URLRequest, Data?)] = []
    private var dripTimer: Timer?

    static func install(_ value: @escaping (URLRequest, Data?) -> Reply) {
        lock.withLock {
            handler = value
            requests = []
        }
    }

    static func captured() -> [(URLRequest, Data?)] {
        lock.withLock { requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayCapabilityFakeServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let reply: Reply = Self.lock.withLock {
            Self.requests.append((request, body))
            return Self.handler?(request, body) ?? .http(status: 404, contentType: "application/json", body: Data())
        }
        switch reply {
        case .network:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .hang:
            break
        case .drip:
            client?.urlProtocol(self, didReceive: response(200, "text/event-stream"), cacheStoragePolicy: .notAllowed)
            // The timer lives on the loading thread's run loop so the client callbacks stay on the same thread.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: Data(": ping\n\n".utf8))
            }
            RunLoop.current.add(timer, forMode: .common)
            dripTimer = timer
        case let .http(status, contentType, data):
            client?.urlProtocol(self, didReceive: response(status, contentType), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        dripTimer?.invalidate()
        dripTimer = nil
    }

    private func response(_ status: Int, _ contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4_096)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Accumulates values across closures inside a test.
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// RL2-PROBE-06: user-initiated "Test capabilities", driven by the caseId entries of `shared/test-fixtures/relay/capability-test.v1.json`.
/// Scenarios run the production `ProviderManager.runRelayCapabilityTest` -> production chat builders -> production `relayBytes` against the fake server,
/// and override assertions use the model after the production write-back has gone through a Codable round trip.
@Suite("RL2-PROBE-06 · Relay capability test", .serialized)
@MainActor
struct RelayCapabilityTestTests {
    /// Short deadline used by the hang / drip scenarios (fixture $comment: for example 300 ms).
    private static let shortDeadline: Duration = .milliseconds(400)

    // MARK: - Fixtures

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/capability-test.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
    }

    private static func parsed(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    /// Replaces `{{model}}` in a template.
    private static func substituted(_ template: Any, model: String) throws -> Any {
        let text = try #require(String(data: json(template), encoding: .utf8))
            .replacingOccurrences(of: "{{model}}", with: model)
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// Fixture subset matching: objects match key by key as a subset, arrays must have equal length and match item by item as subsets, scalars must be equal.
    private static func subsetMatches(_ expected: Any, _ actual: Any?) -> Bool {
        if let object = expected as? [String: Any] {
            guard let actualObject = actual as? [String: Any] else { return false }
            return object.allSatisfy { key, value in subsetMatches(value, actualObject[key]) }
        }
        if let array = expected as? [Any] {
            guard let actualArray = actual as? [Any], actualArray.count == array.count else { return false }
            return zip(array, actualArray).allSatisfy { subsetMatches($0, $1) }
        }
        guard let actual else { return false }
        return (expected as? NSObject)?.isEqual(actual) ?? false
    }

    private static func overrides(_ raw: Any?) throws -> RelayCapabilityOverrides? {
        guard let raw, let dict = raw as? [String: Any], !dict.isEmpty else { return nil }
        return try JSONDecoder().decode(RelayCapabilityOverrides.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private static func builtinMarkers(_ fixture: [String: Any]) throws -> (image: String, tool: String) {
        let builtins = try #require(fixture["builtins"] as? [String: Any])
        let image = try #require(builtins["imagePNGBase64"] as? String)
        let tool = try #require((builtins["tool"] as? [String: Any])?["name"] as? String)
        return (image, tool)
    }

    private static func contains(_ body: String, _ needle: String) -> Bool {
        body.contains(needle) || body.contains(needle.replacingOccurrences(of: "/", with: "\\/"))
    }

    /// Classifies a test request by its body: tool name present = tool, built-in image present = image, anything else = text.
    private static func kind(of body: Data?, markers: (image: String, tool: String)) -> String {
        let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if text.contains(markers.tool) { return "tool" }
        if contains(text, markers.image) { return "image" }
        return "text"
    }

    private static func reply(_ fixture: [String: Any], kind responseKind: String, short: String) throws -> RelayCapabilityFakeServer.Reply {
        let responses = try #require(fixture["responses"] as? [String: Any])
        let spec = try #require(responses[responseKind] as? [String: Any], "\(responseKind)")
        if spec["network"] as? Bool == true { return .network }
        if spec["hang"] as? Bool == true { return .hang }
        if spec["drip"] as? Bool == true { return .drip }
        let status = try #require(spec["status"] as? Int)
        let contentType = try #require(spec["contentType"] as? String)
        let rawBody: Any
        if let byTransport = spec["bodyByTransport"] as? [String: Any] {
            rawBody = try #require(byTransport[short])
        } else {
            rawBody = try #require(spec["body"])
        }
        let body = (rawBody as? String).map { Data($0.utf8) } ?? json(rawBody)
        return .http(status: status, contentType: contentType, body: body)
    }

    private static var retainedStates: [AppState] = []

    private static func makeState() -> AppState {
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-capability-test-\(UUID().uuidString)",
            providerSession: RelayCapabilityFakeServer.session()
        )
        retainedStates.append(state)
        return state
    }

    private static func relayProvider(transport: RelayTransport, model: AIModel) -> Provider {
        Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [model],
            apiKey: "sk-test",
            apiKeyPreview: "...test",
            baseURLText: "https://relay.example.com",
            relayRequested: RelayRequestedConfig(transport: transport, authMode: .auto, securityMode: .remoteHTTPS)
        )
    }

    private static let ok = RelayCapabilityTest.Response(
        status: 200, contentType: "text/event-stream",
        body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
    )

    // MARK: - T1 verdicts

    @Test("RL2-PROBE-06 classifyCases: (status, contentType, whole body) -> verdict + reason")
    func rl2Probe06Classify() throws {
        let fixture = try Self.fixture()
        let cases = try #require(fixture["classifyCases"] as? [[String: Any]])
        #expect(cases.count == 26)
        for testCase in cases {
            let caseId = testCase["caseId"] as? String ?? "<no id>"
            let judgement = RelayCapabilityTest.judge(
                status: try #require(testCase["status"] as? Int),
                contentType: try #require(testCase["contentType"] as? String),
                body: Data(try #require(testCase["body"] as? String).utf8)
            )
            #expect(judgement.verdict.rawValue == testCase["expect"] as? String, "\(caseId)")
            #expect(judgement.reason.rawValue == testCase["reason"] as? String, "\(caseId)")
        }
    }

    // MARK: - T3 scenarios

    /// Runs one fixture scenario: production executor -> production chat builders -> production `relayBytes` against the fake server; asserts request shape, verdicts and write-back item by item.
    @discardableResult
    private static func runScenario(_ scenario: [String: Any], fixture: [String: Any]) async throws -> RelayCapabilityTest.Result {
        let transports = try #require(fixture["transports"] as? [String: String])
        let shapes = try #require(fixture["requestShapes"] as? [String: Any])
        let mustContain = try #require(fixture["mustContain"] as? [String: [String]])
        let mustNotContain = try #require(fixture["mustNotContain"] as? [String: [String]])
        let markers = try builtinMarkers(fixture)

        let caseId = scenario["caseId"] as? String ?? "<no id>"
        let short = try #require(scenario["transport"] as? String)
        let transport = try #require(RelayTransport(rawValue: transports[short] ?? ""))
        let modelID = try #require(scenario["model"] as? String)
        let responseTable = try #require(scenario["responses"] as? [String: String])
        let expect = try #require(scenario["expect"] as? [String: Any])

        var replies: [String: RelayCapabilityFakeServer.Reply] = [:]
        for (kind, responseKind) in responseTable {
            replies[kind] = try reply(fixture, kind: responseKind, short: short)
        }
        RelayCapabilityFakeServer.install { _, body in
            replies[kind(of: body, markers: markers)] ?? .http(status: 404, contentType: "application/json", body: Data())
        }

        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        model.relayCapabilityOverrides = try overrides(scenario["existingOverrides"])
        let state = makeState()
        var provider = relayProvider(transport: transport, model: model)
        for (field, value) in scenario["connection"] as? [String: Any] ?? [:] {
            switch field {
            case "disableResponseStorage": provider.relayRequested?.disableResponseStorage = value as? Bool
            default: Issue.record("\(caseId): unknown connection field \(field)")
            }
        }
        state.providers = [provider]

        let result = try #require(
            await state.providerManager.runRelayCapabilityTest(
                providerID: provider.id, modelID: modelID, deadline: shortDeadline
            ),
            "\(caseId)"
        )

        // Requests actually sent (production request objects): kind, order, path, query and body shape all match the fixture.
        let sent = RelayCapabilityFakeServer.captured()
        #expect(sent.map { kind(of: $0.1, markers: markers) } == expect["requests"] as? [String], "\(caseId)")
        if let total = expect["totalHttpRequests"] as? Int {
            #expect(sent.count == total, "\(caseId)")
        }
        let shape = try #require(shapes[short] as? [String: Any])
        let expectedPath = try #require(shape["path"] as? String).replacingOccurrences(of: "{{model}}", with: modelID)
        let bodyExtra = expect["bodyExtra"] as? [String: Any] ?? [:]
        for (request, body) in sent {
            let kind = kind(of: body, markers: markers)
            #expect(request.httpMethod == "POST", "\(caseId) \(kind)")
            #expect(request.url?.host == "relay.example.com", "\(caseId) \(kind)")
            #expect(request.url?.path == expectedPath, "\(caseId) \(kind)")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for (name, value) in shape["query"] as? [String: String] ?? [:] {
                #expect(queryItems.contains { $0.name == name && $0.value == value }, "\(caseId) \(kind) query \(name)")
            }
            let parsedBody = parsed(body)
            #expect(subsetMatches(try substituted(shape["bodySubset"] ?? [:], model: modelID), parsedBody), "\(caseId) \(kind) bodySubset")
            if let byKind = (shape["bodySubsetByKind"] as? [String: Any])?[kind] {
                #expect(subsetMatches(try substituted(byKind, model: modelID), parsedBody), "\(caseId) \(kind) bodySubsetByKind")
            }
            #expect(subsetMatches(bodyExtra, parsedBody), "\(caseId) \(kind) bodyExtra")
            let text = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            for needle in mustContain[kind] ?? [] {
                let value = needle == "{{png}}" ? markers.image : needle
                #expect(contains(text, value), "\(caseId) \(kind) mustContain \(needle)")
            }
            for needle in mustNotContain[kind] ?? [] {
                let value = needle == "{{png}}" ? markers.image : needle
                #expect(!contains(text, value), "\(caseId) \(kind) mustNotContain \(needle)")
            }
        }

        #expect(result.outcome.rawValue == expect["outcome"] as? String, "\(caseId)")
        #expect(result.stopReason == nil, "\(caseId)")
        let expectedItems = expect["items"] as? [String: String] ?? [:]
        #expect(
            Dictionary(uniqueKeysWithValues: result.items.map { ($0.key.rawValue, $0.value.rawValue) }) == expectedItems,
            "\(caseId)"
        )
        for (key, reason) in expect["reasons"] as? [String: String] ?? [:] {
            let overrideKey = try #require(RelayCapabilityOverrides.Key(rawValue: key))
            #expect(result.itemResults[overrideKey]?.reason.rawValue == reason, "\(caseId) reason \(key)")
        }
        if let text = expect["text"] as? [String: String] {
            #expect(result.text?.verdict.rawValue == text["verdict"], "\(caseId) text")
            #expect(result.text?.reason.rawValue == text["reason"], "\(caseId) text reason")
        }

        let current = try #require(state.provider(for: provider.id))
        let stored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(current))
        let expectedOverrides = try overrides(expect["overrides"])
        #expect(stored.models.first { $0.id == modelID }?.relayCapabilityOverrides == expectedOverrides, "\(caseId)")
        #expect(
            stored.catalogModels.first { $0.id == modelID }?.relayCapabilityOverrides == expectedOverrides,
            "\(caseId) catalog"
        )
        return result
    }

    private static func scenario(_ caseId: String, in fixture: [String: Any]) throws -> [String: Any] {
        let scenarios = try #require(fixture["scenarios"] as? [[String: Any]])
        return try #require(scenarios.first { $0["caseId"] as? String == caseId }, "\(caseId)")
    }

    @Test("RL2-PROBE-06 scenarios: one streaming request per item, chat builder -> relayBytes -> verdict -> write-back through a Codable round trip")
    func rl2Probe06Scenarios() async throws {
        let fixture = try Self.fixture()
        let scenarios = try #require(fixture["scenarios"] as? [[String: Any]])
        #expect(scenarios.count == 22)
        for scenario in scenarios {
            try await Self.runScenario(scenario, fixture: fixture)
        }
    }

    // MARK: - RD4-DEADLINE

    @Test("RD4-DEADLINE-01 total deadline: production value = the fixture's 30 seconds; no response headers -> timeout, and the text failure stops later items")
    func rd4Deadline01() async throws {
        let fixture = try Self.fixture()
        let deadline = try #require(fixture["deadline"] as? [String: Any])
        #expect(RelayCapabilityTest.perItemSeconds == deadline["perItemSeconds"] as? Int)
        #expect(RelayCapabilityTest.perItemSeconds == 30)
        #expect(RelayCapabilityTest.perItemDeadline == .seconds(30))
        let result = try await Self.runScenario(Self.scenario("text_hang_times_out_and_stops", in: fixture), fixture: fixture)
        #expect(result.text?.reason == .timeout)
    }

    @Test("RD4-DEADLINE-02 the total deadline is not an idle timeout: a stream that keeps dripping comment lines is also cut at the deadline -> timeout, later items still run")
    func rd4Deadline02() async throws {
        let fixture = try Self.fixture()
        let result = try await Self.runScenario(Self.scenario("image_drip_is_cut_by_total_deadline", in: fixture), fixture: fixture)
        let image = try #require(result.itemResults[.image])
        #expect(image.reason == .timeout)
        #expect(image.elapsedMs < 3_000, "cut near the injected short deadline, not after the dripping stops")
    }

    // MARK: - RD4-PATH

    @Test("RD4-PATH-01 same path: the text request equals the chat builder output for the same input (URL / all headers / body); the model is bound to the second key")
    func rd4Path01() async throws {
        RelayCapabilityFakeServer.install { _, _ in .http(status: 404, contentType: "application/json", body: Data("{}".utf8)) }
        for transport in [RelayTransport.openaiChatCompletions, .openaiResponses, .anthropicMessages, .geminiGenerateContent] {
            var model = TestFactories.makeModel(id: "path-model", capabilities: [.text], isDefault: true)
            model.relayKeyID = "k-second"
            let state = Self.makeState()
            var provider = Self.relayProvider(transport: transport, model: model)
            provider.relayKeys = [
                RelayKey(id: "initial", name: "Primary"),
                RelayKey(id: "k-second", name: "Second", apiKey: "sk-second"),
            ]
            state.providers = [provider]
            let sent = Box<[URLRequest]>([])
            let session = RelayCapabilityFakeServer.session()
            _ = await state.providerManager.runRelayCapabilityTest(providerID: provider.id, modelID: model.id) { _, request in
                sent.value.append(request)
                return try await RelayCapabilityTest.perform(request, session: session)
            }
            let actual = try #require(sent.value.first, "\(transport)")

            // The same synthetic message and options, calling this platform's chat builder directly.
            guard case let .byProtocol(route) = ProviderServiceRouter.route(provider: provider, model: model) else {
                Issue.record("\(transport) is not dispatched by protocol")
                continue
            }
            // Same as a normal chat send (ChatManager): evidence model, connection id, task-local identity.
            var options = ChatRequestOptions()
            options.relayRequested = route.requested
            options.capabilityEvidenceModel = AttachmentTransportResolver.evidenceModel(provider: provider, model: model)
            options.attachmentConnectionID = provider.id
            let messages = [RelayCapabilityTest.message(for: .text, modelID: model.id)]
            let services = state.providerManager.services
            let identity = CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: state.sessionPartitionUID, hasExplicitValue: false
            )
            let expected: URLRequest = try CapabilityEvidenceRequestContext.$current.withValue(identity) { switch transport {
            case .openaiResponses:
                try services.openAI.buildRelayResponsesRequest(
                    modelID: model.id, messages: messages, apiKey: "sk-second", baseURL: route.baseURL, stream: true,
                    reasoningMode: .automatic, requestOptions: options, relayRequested: route.requested, maxOutputTokens: 16
                )
            case .anthropicMessages:
                try services.anthropic.buildRelayMessagesRequest(
                    modelID: model.id, messages: messages, apiKey: "sk-second", baseURL: route.baseURL, stream: true,
                    reasoningMode: .automatic, requestOptions: options, relayRequested: route.requested, maxOutputTokens: 16
                )
            case .geminiGenerateContent:
                try services.gemini.buildRelayGenerateContentRequest(
                    modelID: model.id, messages: messages, apiKey: "sk-second", baseURL: route.baseURL, stream: true,
                    reasoningMode: .automatic, supportsImageGen: false,
                    requestOptions: options, relayRequested: route.requested, maxOutputTokens: 16
                )
            default:
                try services.openAI.buildChatCompletionsRequest(
                    modelID: model.id, messages: messages, apiKey: "sk-second", stream: true, baseURL: route.baseURL,
                    reasoningMode: .automatic, requestOptions: options, relayRequested: route.requested, validationMaxTokens: 16
                )
            } }
            #expect(actual.url == expected.url, "\(transport)")
            #expect(actual.httpMethod == expected.httpMethod, "\(transport)")
            // The `session_id` in Responses headers is a fresh UUID on every build (chat does the same), so only presence is compared.
            var actualHeaders = actual.allHTTPHeaderFields ?? [:]
            var expectedHeaders = expected.allHTTPHeaderFields ?? [:]
            #expect((actualHeaders.removeValue(forKey: "session_id") == nil) == (expectedHeaders.removeValue(forKey: "session_id") == nil), "\(transport)")
            #expect(actualHeaders == expectedHeaders, "\(transport)")
            #expect(NSDictionary(dictionary: Self.parsed(actual.httpBody) ?? [:]) == NSDictionary(dictionary: Self.parsed(expected.httpBody) ?? [:]), "\(transport)")
            let credentials = (actual.allHTTPHeaderFields ?? [:]).values.joined(separator: " ") + (actual.url?.absoluteString ?? "")
            #expect(credentials.contains("sk-second"), "\(transport) auth uses the second key")
            #expect(!credentials.contains("sk-test"), "\(transport) is not the primary key")
        }
    }

    @Test("RD4-PATH-02 sent once: a Messages text 404 produces exactly 1 HTTP request over the whole run, with no protocol fallback")
    func rd4Path02() async throws {
        let fixture = try Self.fixture()
        try await Self.runScenario(Self.scenario("text_404_sends_one_request_without_protocol_fallback", in: fixture), fixture: fixture)
        #expect(RelayCapabilityFakeServer.captured().count == 1)
    }

    @Test("RD4-PATH-03 the four chat builders are unchanged when the new parameters are not passed: no tools / output cap keeps the default (Responses 16384 + image_generation, Messages 8192, Gemini without maxOutputTokens)")
    func rd4BuildersUnchangedWithoutNewParameters() throws {
        let state = Self.makeState()
        let services = state.providerManager.services
        let messages = [RelayCapabilityTest.message(for: .text, modelID: "m")]
        let base = "https://relay.example.com"
        let chat = Self.parsed(try services.openAI.buildChatCompletionsRequest(
            modelID: "m", messages: messages, apiKey: "sk", stream: true, baseURL: base, reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        ).httpBody)
        #expect(chat?["tools"] == nil)
        #expect(chat?["max_tokens"] == nil)
        // keepImageAttachments not passed: the evidence gate still strips images (no evidence model = not let through).
        let chatImage = try services.openAI.buildChatCompletionsRequest(
            modelID: "m", messages: [RelayCapabilityTest.message(for: .image, modelID: "m")], apiKey: "sk", stream: true,
            baseURL: base, reasoningMode: .automatic, relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        ).httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!Self.contains(chatImage, RelayCapabilityTest.imagePNGBase64))
        let responses = Self.parsed(try services.openAI.buildRelayResponsesRequest(
            modelID: "m", messages: messages, apiKey: "sk", baseURL: base, stream: true, reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .openaiResponses)
        ).httpBody)
        #expect(responses?["max_output_tokens"] as? Int == 16384)
        #expect((responses?["tools"] as? [[String: Any]])?.compactMap { $0["type"] as? String } == ["image_generation"])
        let messagesBody = Self.parsed(try services.anthropic.buildRelayMessagesRequest(
            modelID: "m", messages: messages, apiKey: "sk", baseURL: base, stream: true, reasoningMode: .automatic,
            relayRequested: RelayRequestedConfig(transport: .anthropicMessages)
        ).httpBody)
        #expect(messagesBody?["max_tokens"] as? Int == 8192)
        #expect(messagesBody?["tools"] == nil)
        let gemini = Self.parsed(try services.gemini.buildRelayGenerateContentRequest(
            modelID: "m", messages: messages, apiKey: "sk", baseURL: base, stream: true, reasoningMode: .automatic,
            supportsImageGen: false,
            relayRequested: RelayRequestedConfig(transport: .geminiGenerateContent)
        ).httpBody)
        #expect(NSDictionary(dictionary: gemini?["generationConfig"] as? [String: Any] ?? [:]) == ["responseModalities": ["TEXT"]])
        #expect(gemini?["tools"] == nil)
    }

    // MARK: - RD4-STOP

    /// Injected send: changes the connection / model, or cancels, when a given item is sent. Returns the result and the items actually sent.
    private static func runWithMutation(
        at trigger: RelayCapabilityTest.Kind,
        _ mutate: @escaping (AppState, UUID) -> Void
    ) async throws -> (RelayCapabilityTest.Result?, [RelayCapabilityTest.Kind], AppState, UUID) {
        let model = TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)
        let state = makeState()
        let provider = relayProvider(transport: .openaiChatCompletions, model: model)
        state.providers = [provider]
        let sent = Box<[RelayCapabilityTest.Kind]>([])
        // Image / tool items count as accepted only when the response carries evidence; each item answers with the fixture's image_ok / tool_ok.
        let replies = try evidenceResponses(short: "chat")
        let result = await state.providerManager.runRelayCapabilityTest(providerID: provider.id, modelID: model.id) { kind, _ in
            sent.value.append(kind)
            if kind == trigger { mutate(state, provider.id) }
            return replies[kind] ?? ok
        }
        return (result, sent.value, state, provider.id)
    }

    /// Successful response with evidence from the fixture: text -> ok, image -> image_ok, tool -> tool_ok.
    private static func evidenceResponses(short: String) throws -> [RelayCapabilityTest.Kind: RelayCapabilityTest.Response] {
        let fixture = try fixture()
        var responses: [RelayCapabilityTest.Kind: RelayCapabilityTest.Response] = [:]
        for (kind, name) in [(RelayCapabilityTest.Kind.text, "ok"), (.image, "image_ok"), (.tool, "tool_ok")] {
            guard case let .http(status, contentType, body) = try reply(fixture, kind: name, short: short) else {
                Issue.record("\(name) is not an HTTP response")
                continue
            }
            responses[kind] = RelayCapabilityTest.Response(status: status, contentType: contentType, body: body)
        }
        return responses
    }

    private static func assertNothingWritten(_ state: AppState, _ providerID: UUID) throws {
        let current = try #require(state.provider(for: providerID))
        #expect(current.models.first?.relayCapabilityOverrides == nil)
        #expect(current.catalogModels.first?.relayCapabilityOverrides == nil)
    }

    @Test("RD4-STOP-01 cancel: stops at stopped / cancelled, completed text is kept, nothing more is sent or written")
    func rd4Stop01Cancelled() async throws {
        let model = TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)
        let state = Self.makeState()
        let provider = Self.relayProvider(transport: .openaiChatCompletions, model: model)
        state.providers = [provider]
        let sent = Box<[RelayCapabilityTest.Kind]>([])
        let handle = Box<Task<RelayCapabilityTest.Result?, Never>?>(nil)
        let task = Task { @MainActor in
            await state.providerManager.runRelayCapabilityTest(providerID: provider.id, modelID: model.id) { kind, _ in
                sent.value.append(kind)
                // The user taps Cancel while the image request is in flight.
                if kind == .image { handle.value?.cancel() }
                return Self.ok
            }
        }
        handle.value = task
        let result = try #require(await task.value)
        #expect(sent.value == [.text, .image])
        #expect(result.outcome == .stopped)
        #expect(result.stopReason == .cancelled)
        #expect(result.text?.verdict == .accepted)
        #expect(result.itemResults.isEmpty)
        #expect(!result.written)
        try Self.assertNothingWritten(state, provider.id)
    }

    @Test("RD4-STOP-02 connection changed (before write-back): all three items finish and verdicts are kept, stops at connection, nothing written")
    func rd4Stop02ConnectionChanged() async throws {
        let (result, sent, state, providerID) = try await Self.runWithMutation(at: .tool) { state, id in
            guard var current = state.provider(for: id) else { return }
            current.apiKey = "sk-rotated"
            state.providerManager.updateProvider(current)
        }
        let stopped = try #require(result)
        #expect(sent == [.text, .image, .tool])
        #expect(stopped.outcome == .stopped)
        #expect(stopped.stopReason == .connection)
        #expect(stopped.itemResults[.image]?.verdict == .accepted)
        #expect(stopped.itemResults[.toolCall]?.verdict == .accepted)
        try Self.assertNothingWritten(state, providerID)
    }

    @Test("RD4-STOP-03 protocol changed (before sending): after image the model protocol changes -> tool is not sent, stops at protocol, nothing written")
    func rd4Stop03ProtocolChanged() async throws {
        let (result, sent, state, providerID) = try await Self.runWithMutation(at: .image) { state, id in
            guard var current = state.provider(for: id) else { return }
            for index in current.models.indices {
                current.models[index].relayTransport = .openaiResponses
                current.models[index].relayTransportSource = .user
            }
            state.providerManager.updateProvider(current)
        }
        let stopped = try #require(result)
        #expect(sent == [.text, .image])
        #expect(stopped.stopReason == .protocolChanged)
        #expect(stopped.itemResults[.image] != nil)
        #expect(stopped.itemResults[.toolCall] == nil)
        try Self.assertNothingWritten(state, providerID)
    }

    @Test("RD4-STOP-04 model removed: after image the model is disabled -> tool is not sent, stops at unavailable")
    func rd4Stop04ModelRemoved() async throws {
        let (result, sent, _, _) = try await Self.runWithMutation(at: .image) { state, id in
            guard var current = state.provider(for: id) else { return }
            current.models.removeAll()
            state.providerManager.updateProvider(current)
        }
        let stopped = try #require(result)
        #expect(sent == [.text, .image])
        #expect(stopped.outcome == .stopped)
        #expect(stopped.stopReason == .unavailable)
        #expect(stopped.text?.verdict == .accepted)
    }

    // MARK: - RD4-PANEL (fixture panelCases)

    private static let panelCaseIDs = [
        "running_second_of_three", "completed_board", "completed_nothing_saved_single_key",
        "running_first_single_key_image_user_set", "text_not_found", "text_rejected_422", "text_unauthorized",
        "stopped_cancelled_during_tool", "stopped_connection_changed_before_write", "stopped_protocol_changed",
        "stopped_model_unavailable", "completed_not_observed_single_key",
        "running_web_after_not_observed", "running_text_named_key_with_web", "completed_web_searched",
        "completed_web_silent_nothing_saved", "completed_web_rejected", "text_failed_web_not_run",
    ]

    @Test("RD4-PANEL fixture panelCases is exactly these 18 entries")
    func rd4PanelCaseList() throws {
        let cases = try #require((try Self.fixture()["panelCases"] as? [String: Any])?["cases"] as? [[String: Any]])
        #expect(cases.compactMap { $0["caseId"] as? String } == Self.panelCaseIDs)
    }

    private static func itemResult(_ raw: Any?) throws -> RelayCapabilityTest.ItemResult {
        let dict = try #require(raw as? [String: Any])
        return RelayCapabilityTest.ItemResult(
            verdict: try #require(RelayCapabilityTest.Verdict(rawValue: dict["verdict"] as? String ?? "")),
            reason: try #require(RelayCapabilityTest.Reason(rawValue: dict["reason"] as? String ?? "")),
            status: dict["status"] as? Int,
            elapsedMs: try #require(dict["elapsedMs"] as? Int)
        )
    }

    private static func footerObject(_ footer: RelayCapabilityTestPanel.Footer) -> [String: Any] {
        switch footer {
        case let .info(count, keyName?, web):
            ["key": (web ? RelayCapabilityTestPanel.Copy.infoWebNamedKey : .infoNamedKey).rawValue, "count": count, "keyName": keyName]
        case let .info(count, nil, web):
            ["key": (web ? RelayCapabilityTestPanel.Copy.infoWeb : .info).rawValue, "count": count]
        case .saved: ["key": RelayCapabilityTestPanel.Copy.footerSaved.rawValue]
        case .nothing: ["key": RelayCapabilityTestPanel.Copy.footerNothing.rawValue]
        case let .stopped(reason):
            ["key": RelayCapabilityTestPanel.Copy.stopped.rawValue, "reason": RelayCapabilityTestPanel.stopCopy(reason).rawValue]
        }
    }

    /// One fixture panelCase -> pure function input -> compared with expect field by field.
    private static func assertPanelCase(_ caseId: String) throws {
        let fixture = try fixture()
        let transports = try #require(fixture["transports"] as? [String: String])
        let cases = try #require((fixture["panelCases"] as? [String: Any])?["cases"] as? [[String: Any]])
        let testCase = try #require(cases.first { $0["caseId"] as? String == caseId }, "\(caseId)")
        let short = try #require(testCase["transport"] as? String)
        var results: [RelayCapabilityTestPanel.Item: RelayCapabilityTest.ItemResult] = [:]
        for (key, raw) in testCase["results"] as? [String: Any] ?? [:] {
            results[try #require(RelayCapabilityTestPanel.Item(rawValue: key))] = try itemResult(raw)
        }
        let running = try (testCase["running"] as? [String: Any]).map { raw in
            RelayCapabilityTestPanel.Running(
                item: try #require(RelayCapabilityTestPanel.Item(rawValue: raw["kind"] as? String ?? "")),
                elapsedMs: try #require(raw["elapsedMs"] as? Int)
            )
        }
        let input = RelayCapabilityTestPanel.Input(
            transport: try #require(RelayTransport(rawValue: transports[short] ?? "")),
            items: try #require(testCase["items"] as? [String]).map { try #require(RelayCapabilityTestPanel.Item(rawValue: $0)) },
            keyName: testCase["keyName"] as? String,
            phase: try #require(RelayCapabilityTestPanel.Phase(rawValue: testCase["phase"] as? String ?? "")),
            results: results,
            running: running,
            written: testCase["written"] as? Bool ?? false,
            stopReason: (testCase["stopReason"] as? String).flatMap(RelayCapabilityTest.StopReason.init(rawValue:))
        )
        let state = RelayCapabilityTestPanel.make(input)
        let expect = try #require(testCase["expect"] as? [String: Any])

        switch state.header {
        case let .progress(current, total):
            #expect((expect["header"] as? [String: Any])?["progress"] as? [Int] == [current, total], "\(caseId) header")
        case .done: #expect(expect["header"] as? String == "done", "\(caseId) header")
        case .stopped: #expect(expect["header"] as? String == "stopped", "\(caseId) header")
        }
        #expect(expect["progressFraction"] as? [Int] == [state.finished, state.total], "\(caseId) progressFraction")
        let chips = try #require(expect["chips"] as? [String: Any])
        #expect(RelayCapabilityTest.shortName(state.transport) == chips["transport"] as? String, "\(caseId) chip")
        #expect(state.keyName == chips["key"] as? String, "\(caseId) key chip")
        let rows = try #require(expect["rows"] as? [[String: Any]])
        #expect(rows.count == state.rows.count, "\(caseId) rows")
        for (row, expectedRow) in zip(state.rows, rows) {
            let label = "\(caseId) \(row.item.rawValue)"
            #expect(row.item.rawValue == expectedRow["kind"] as? String, "\(label) kind")
            #expect(row.icon.rawValue == expectedRow["icon"] as? String, "\(label) icon")
            #expect(row.subtitle?.rawValue == expectedRow["subtitle"] as? String, "\(label) subtitle")
            #expect(row.subtitleArg?.fixtureValue == expectedRow["subtitleArg"] as? String, "\(label) subtitleArg")
            #expect(row.trailing?.fixtureValue == expectedRow["trailing"] as? String, "\(label) trailing")
        }
        #expect(
            NSDictionary(dictionary: footerObject(state.footer)) == NSDictionary(dictionary: try #require(expect["footer"] as? [String: Any])),
            "\(caseId) footer"
        )
        #expect(state.button.rawValue == expect["button"] as? String, "\(caseId) button")
        #expect(state.dismissible == expect["dismissible"] as? Bool, "\(caseId) dismissible")
    }

    @Test("RD4-PANEL-running_second_of_three") func rd4PanelRunningSecondOfThree() throws { try Self.assertPanelCase("running_second_of_three") }
    @Test("RD4-PANEL-completed_board") func rd4PanelCompletedBoard() throws { try Self.assertPanelCase("completed_board") }
    @Test("RD4-PANEL-completed_nothing_saved_single_key") func rd4PanelCompletedNothingSaved() throws { try Self.assertPanelCase("completed_nothing_saved_single_key") }
    @Test("RD4-PANEL-running_first_single_key_image_user_set") func rd4PanelRunningFirst() throws { try Self.assertPanelCase("running_first_single_key_image_user_set") }
    @Test("RD4-PANEL-text_not_found") func rd4PanelTextNotFound() throws { try Self.assertPanelCase("text_not_found") }
    @Test("RD4-PANEL-text_rejected_422") func rd4PanelTextRejected422() throws { try Self.assertPanelCase("text_rejected_422") }
    @Test("RD4-PANEL-text_unauthorized") func rd4PanelTextUnauthorized() throws { try Self.assertPanelCase("text_unauthorized") }
    @Test("RD4-PANEL-stopped_cancelled_during_tool") func rd4PanelStoppedCancelled() throws { try Self.assertPanelCase("stopped_cancelled_during_tool") }
    @Test("RD4-PANEL-stopped_connection_changed_before_write") func rd4PanelStoppedConnection() throws { try Self.assertPanelCase("stopped_connection_changed_before_write") }
    @Test("RD4-PANEL-stopped_protocol_changed") func rd4PanelStoppedProtocol() throws { try Self.assertPanelCase("stopped_protocol_changed") }
    @Test("RD4-PANEL-stopped_model_unavailable") func rd4PanelStoppedUnavailable() throws { try Self.assertPanelCase("stopped_model_unavailable") }
    @Test("RD4-PANEL-completed_not_observed_single_key") func rd4PanelCompletedNotObserved() throws { try Self.assertPanelCase("completed_not_observed_single_key") }
    @Test("RD4-PANEL-running_web_after_not_observed") func rd4PanelRunningWeb() throws { try Self.assertPanelCase("running_web_after_not_observed") }
    @Test("RD4-PANEL-running_text_named_key_with_web") func rd4PanelRunningTextNamedKeyWeb() throws { try Self.assertPanelCase("running_text_named_key_with_web") }
    @Test("RD4-PANEL-completed_web_searched") func rd4PanelCompletedWebSearched() throws { try Self.assertPanelCase("completed_web_searched") }
    @Test("RD4-PANEL-completed_web_silent_nothing_saved") func rd4PanelCompletedWebSilent() throws { try Self.assertPanelCase("completed_web_silent_nothing_saved") }
    @Test("RD4-PANEL-completed_web_rejected") func rd4PanelCompletedWebRejected() throws { try Self.assertPanelCase("completed_web_rejected") }
    @Test("RD4-PANEL-text_failed_web_not_run") func rd4PanelTextFailedWebNotRun() throws { try Self.assertPanelCase("text_failed_web_not_run") }

    // MARK: - RD4-WEB (the fourth item, web search = manual probe)

    private static func isolatedDefaults() -> UserDefaults {
        let name = "relay-capability-web-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The searched response from fixture web-probe.v1.json (chat protocol url_citation).
    private static func webSearchedResponse() throws -> RelayCapabilityTest.Response {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var url: URL?
        while cursor.path != "/", url == nil {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/web-probe.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
            cursor.deleteLastPathComponent()
        }
        let fixtureURL = try #require(url)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let cases = try #require(object["evidenceCases"] as? [[String: Any]])
        let testCase = try #require(cases.first { $0["caseId"] as? String == "chat_url_citation_searched" })
        let lines = try #require(testCase["sse"] as? [String])
        return RelayCapabilityTest.Response(
            status: try #require(testCase["status"] as? Int), contentType: "text/event-stream",
            body: Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    /// A chat-protocol Relay connection; when `fragment` is true, a chat template fragment is stored in the injected fragment store.
    private static func webScenario(fragment: Bool) throws -> (AppState, Provider, AIModel, RelayWebProbeStore) {
        let model = TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)
        let state = makeState()
        let provider = relayProvider(transport: .openaiChatCompletions, model: model)
        state.providers = [provider]
        let fragments = RelayWebFragmentStore(defaults: isolatedDefaults())
        if fragment {
            let raw = try #require(RelayWebFragments.template(for: .openaiChatCompletions))
            #expect(fragments.save(connectionID: provider.id, transport: .openaiChatCompletions, raw: raw) == nil)
        }
        let records = RelayWebProbeStore(defaults: isolatedDefaults())
        state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(fragments: fragments, records: records)
        return (state, provider, model, records)
    }

    @Test("RD4-WEB-01 when the first-send protocol has a stored fragment, step 4 is the manual web probe; without a fragment it is not listed and a text failure sends nothing; the first frame already contains web")
    func rd4Web01ManualProbeAsFourthStep() async throws {
        let replies = try Self.evidenceResponses(short: "chat")
        let searched = try Self.webSearchedResponse()

        // With a fragment: text -> image -> tool -> web; the web result searched is written back as tested web and does not enter the automatic history.
        let (state, provider, model, records) = try Self.webScenario(fragment: true)
        let manager = state.providerManager
        #expect(RelayCapabilityTest.plannedKinds(provider: provider, model: model, fragments: manager.relayWebProbeAutoContext.fragments)
            == [.text, .image, .tool, .web])
        let sent = Box<[RelayCapabilityTest.Kind]>([])
        let events = Box<[RelayCapabilityTest.Event]>([])
        let result = try #require(await manager.runRelayCapabilityTest(
            providerID: provider.id, modelID: model.id,
            send: { kind, _ in
                sent.value.append(kind)
                return kind == .web ? searched : (replies[kind] ?? Self.ok)
            },
            onEvent: { events.value.append($0) }
        ))
        #expect(sent.value == [.text, .image, .tool, .web])
        #expect(result.outcome == .completed)
        #expect(result.itemResults[.web]?.verdict == .searched)
        #expect(result.written)
        #expect(events.value.contains(.started(.web)))
        let written = try #require(state.provider(for: provider.id)?.models.first?.relayCapabilityOverrides)
        #expect(written.web == true)
        #expect(records.autoHistory().isEmpty, "manual probes do not enter the automatic history")

        // Without a fragment: web is not listed and no web request is sent.
        let (bareState, bareProvider, bareModel, _) = try Self.webScenario(fragment: false)
        let bareSent = Box<[RelayCapabilityTest.Kind]>([])
        let bare = try #require(await bareState.providerManager.runRelayCapabilityTest(
            providerID: bareProvider.id, modelID: bareModel.id,
            send: { kind, _ in bareSent.value.append(kind); return replies[kind] ?? Self.ok }
        ))
        #expect(bareSent.value == [.text, .image, .tool])
        #expect(bare.itemResults[.web] == nil)

        // Text fails: web is not sent.
        let (failState, failProvider, failModel, _) = try Self.webScenario(fragment: true)
        let failSent = Box<[RelayCapabilityTest.Kind]>([])
        let failed = try #require(await failState.providerManager.runRelayCapabilityTest(
            providerID: failProvider.id, modelID: failModel.id,
            send: { kind, _ in
                failSent.value.append(kind)
                return RelayCapabilityTest.Response(status: 404, contentType: "application/json", body: Data("{}".utf8))
            }
        ))
        #expect(failSent.value == [.text])
        #expect(failed.outcome == .textFailed)

        // First frame (before any request is sent): items already contain web and the footer is the info variant that includes web.
        let (frameState, frameProvider, frameModel, _) = try Self.webScenario(fragment: true)
        let controller = RelayCapabilityTestController()
        controller.start(appState: frameState, providerID: frameProvider.id, modelID: frameModel.id)
        let first = try #require(controller.state(at: Date()))
        #expect(first.rows.map(\.item) == [.text, .image, .toolCall, .web])
        #expect(first.footer == .info(count: 4, keyName: nil, web: true))
        controller.cancel()
        await controller.waitUntilFinished()
    }

    @Test("RD4-WEB-02 written only looks at whether the web override was actually written: searched does not count as a write when the user set web; searched on an existing identical tested value does not count either")
    func rd4Web02WrittenOnlyWhenWebOverrideChanges() async throws {
        let searched = try Self.webSearchedResponse()
        // Text passes; image / tool get no response = undetermined and are not written; only the web item decides written.
        let send: RelayCapabilityTest.Send = { kind, _ in
            switch kind {
            case .text: return Self.ok
            case .web: return searched
            default: throw URLError(.timedOut)
            }
        }

        // User set web: the searched probe does not touch the override -> footer is nothing.
        let (userState, userProvider, userModel, _) = try Self.webScenario(fragment: true)
        var userSet = userProvider
        var overrides = RelayCapabilityOverrides()
        overrides.setValue(false, for: .web, source: .user)
        userSet.models[0].relayCapabilityOverrides = overrides
        userSet.catalogModels = userSet.catalogModels.map { model in
            var model = model
            if model.id == userModel.id { model.relayCapabilityOverrides = overrides }
            return model
        }
        userState.providerManager.updateProvider(userSet)
        let userResult = try #require(await userState.providerManager.runRelayCapabilityTest(
            providerID: userProvider.id, modelID: userModel.id, send: send
        ))
        #expect(userResult.outcome == .completed)
        #expect(userResult.itemResults[.web]?.verdict == .searched)
        #expect(!userResult.written, "a user entry is untouched = nothing written")
        #expect(userState.provider(for: userProvider.id)?.models.first?.relayCapabilityOverrides == overrides)

        // Not set: the first searched writes tested web; the second one with the same value changes nothing = not a write.
        let (state, provider, model, _) = try Self.webScenario(fragment: true)
        let first = try #require(await state.providerManager.runRelayCapabilityTest(
            providerID: provider.id, modelID: model.id, send: send
        ))
        #expect(first.written)
        #expect(state.provider(for: provider.id)?.models.first?.relayCapabilityOverrides?.web == true)
        let second = try #require(await state.providerManager.runRelayCapabilityTest(
            providerID: provider.id, modelID: model.id, send: send
        ))
        #expect(second.itemResults[.web]?.verdict == .searched)
        #expect(!second.written, "neither override value nor source changed = nothing written")
    }

    // MARK: - BOARD-CAPTEST-01

    @Test("BOARD-CAPTEST-01 the Advanced page 'Test capabilities' opens the bottom panel whose first state is already in progress (cannot be swiped away, only Cancel); when done it stays on the finished state and writes")
    func boardCapTest01() async throws {
        let fixture = try Self.fixture()
        let markers = try Self.builtinMarkers(fixture)
        // Image / tool items count as accepted only when the response carries evidence; each item answers with the fixture's image_ok / tool_ok.
        var replies: [String: RelayCapabilityFakeServer.Reply] = [:]
        for (kind, name) in [("text", "ok"), ("image", "image_ok"), ("tool", "tool_ok")] {
            replies[kind] = try Self.reply(fixture, kind: name, short: "messages")
        }
        RelayCapabilityFakeServer.install { _, body in
            replies[Self.kind(of: body, markers: markers)] ?? .http(status: 404, contentType: "application/json", body: Data())
        }
        var model = TestFactories.makeModel(id: "claude-sonnet-4-5", capabilities: [.text], isDefault: true)
        model.relayKeyID = "k-claude"
        let state = Self.makeState()
        var provider = Self.relayProvider(transport: .anthropicMessages, model: model)
        provider.relayKeys = [RelayKey(id: "initial", name: "OpenAI"), RelayKey(id: "k-claude", name: "Claude group", apiKey: "sk-claude")]
        state.providers = [provider]
        #expect(RelayModelAdvancedBoard.make(
            provider: provider, model: model, partitionID: "captest", probe: nil, readOnly: false
        ).showsTestEntry)

        let controller = RelayCapabilityTestController()
        controller.start(appState: state, providerID: provider.id, modelID: model.id)
        #expect(controller.isPresented)
        let first = try #require(controller.state(at: Date()))
        #expect(first.header == .progress(current: 1, total: 3))
        #expect(first.rows.map(\.icon) == [.running, .waiting, .waiting])
        #expect(first.rows.first?.subtitle == .runningText)
        #expect(first.footer == .info(count: 3, keyName: "Claude group", web: false))
        #expect(first.keyName == "Claude group")
        #expect(first.button == .cancel)
        #expect(!first.dismissible)
        controller.dismiss()
        #expect(controller.isPresented, "cannot be dismissed while in progress")

        await controller.waitUntilFinished()
        let done = try #require(controller.state(at: Date()))
        #expect(done.header == .done)
        #expect(done.rows.map(\.icon) == [.accepted, .accepted, .accepted])
        #expect(done.footer == .saved)
        #expect(done.button == .done)
        #expect(done.dismissible)
        #expect(RelayCapabilityFakeServer.captured().map { Self.kind(of: $0.1, markers: markers) } == ["text", "image", "tool"])
        controller.dismiss()
        #expect(!controller.isPresented)
    }

    // MARK: - RL2-CAPTEST-FIRSTSEND (the capability test follows the first-send protocol, like chat)

    /// Runs the production "Test capabilities" through the panel controller; returns the protocol shown on the first screen and the request paths actually used. Negative caches are pre-written for both protocol keys.
    private static func runFirstSendScenario(
        modelID: String,
        connection: RelayTransport,
        endpointTypes: [String],
        replyShort: String
    ) async throws -> (shown: RelayTransport, paths: [String], provider: Provider, model: AIModel) {
        let fixture = try Self.fixture()
        let okReply = try Self.reply(fixture, kind: "ok", short: replyShort)
        RelayCapabilityFakeServer.install { _, _ in okReply }
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        var provider = Self.relayProvider(transport: connection, model: model)
        let endpoint = "https://captest-\(provider.id.uuidString.lowercased()).example.com"
        provider.baseURLText = endpoint
        RelayCatalogEndpointTypesCache.shared.record(endpoint: endpoint, endpointTypesByModel: [modelID: endpointTypes])
        for transport in [RelayTransport.anthropicMessages, .openaiChatCompletions] {
            for kind in [RelayNegativeCache.Kind.image, .toolCall] {
                RelayNegativeCache.shared.record(
                    connectionID: provider.id.uuidString, modelID: modelID, transport: transport.rawValue, kind: kind
                )
            }
        }
        let state = Self.makeState()
        state.providers = [provider]
        let controller = RelayCapabilityTestController()
        controller.start(appState: state, providerID: provider.id, modelID: modelID)
        let shown = try #require(controller.state(at: Date())).transport
        await controller.waitUntilFinished()
        controller.dismiss()
        let paths = RelayCapabilityFakeServer.captured().compactMap { $0.0.url?.path }
        return (shown, paths, provider, model)
    }

    private static func cached(_ provider: Provider, _ modelID: String, _ transport: RelayTransport, _ kind: RelayNegativeCache.Kind) -> Bool {
        RelayNegativeCache.shared.isRejected(
            connectionID: provider.id.uuidString, modelID: modelID, transport: transport.rawValue, kind: kind
        )
    }

    @Test("RL2-CAPTEST-FIRSTSEND-01 unverified Claude-family model on an auto connection (first send Messages, effective Chat): sends via Messages, clears the Messages-key image / toolCall entries, leaves the Chat key alone")
    func rl2CapTestFirstSend01() async throws {
        let modelID = "claude-captest-first-send"
        let (shown, paths, provider, model) = try await Self.runFirstSendScenario(
            modelID: modelID, connection: .auto, endpointTypes: ["anthropic", "openai"], replyShort: "messages"
        )
        defer {
            RelayNegativeCache.shared.clearConnection(provider.id.uuidString)
            RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:])
        }
        #expect(RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == .openaiChatCompletions, "precondition: effective Chat")
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == .anthropicMessages, "precondition: first send Messages")
        #expect(RelayCapabilityTest.isEligible(provider: provider, model: model))
        #expect(shown == .anthropicMessages, "the panel shows the first-send protocol")
        #expect(paths.count == 3, "\(paths)")
        #expect(paths.allSatisfy { $0.hasSuffix("/messages") }, "test requests go out via the first-send Messages protocol：\(paths)")
        #expect(!Self.cached(provider, modelID, .anthropicMessages, .image))
        #expect(!Self.cached(provider, modelID, .anthropicMessages, .toolCall))
        #expect(Self.cached(provider, modelID, .openaiChatCompletions, .image), "the Chat key is untouched")
        #expect(Self.cached(provider, modelID, .openaiChatCompletions, .toolCall), "the Chat key is untouched")
    }

    @Test("RL2-CAPTEST-FIRSTSEND-02 first send = effective protocol (Chat): behavior unchanged, sends via Chat, clears the Chat key, leaves the Messages key alone")
    func rl2CapTestFirstSend02() async throws {
        let modelID = "gpt-captest-first-send"
        let (shown, paths, provider, model) = try await Self.runFirstSendScenario(
            modelID: modelID, connection: .auto, endpointTypes: ["openai"], replyShort: "chat"
        )
        defer {
            RelayNegativeCache.shared.clearConnection(provider.id.uuidString)
            RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:])
        }
        #expect(RelayFirstSendTransport.current(provider: provider, model: model) == .openaiChatCompletions)
        #expect(shown == .openaiChatCompletions)
        #expect(paths.count == 3, "\(paths)")
        #expect(paths.allSatisfy { $0.hasSuffix("/chat/completions") }, "\(paths)")
        #expect(!Self.cached(provider, modelID, .openaiChatCompletions, .image))
        #expect(!Self.cached(provider, modelID, .openaiChatCompletions, .toolCall))
        #expect(Self.cached(provider, modelID, .anthropicMessages, .image))
        #expect(Self.cached(provider, modelID, .anthropicMessages, .toolCall))
    }

    // MARK: - Scope, entry point and restoring automatic

    @Test("RL2-PROBE-06 scope matches the per-model probe: local engines, the llama.cpp channel and disabled models send no request and write nothing")
    func rl2Probe06ScopeGates() async throws {
        RelayCapabilityFakeServer.install { _, _ in
            .http(status: 200, contentType: "application/json", body: Data("{}".utf8))
        }
        let model = TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)

        var engine = Self.relayProvider(transport: .openaiChatCompletions, model: model)
        engine.relayRequested?.engineProfile = "ollama"
        var llama = Self.relayProvider(transport: .llamacppNative, model: model)
        llama.relayRequested?.engineProfile = nil
        let chat = Self.relayProvider(transport: .openaiChatCompletions, model: model)

        let state = Self.makeState()
        state.providers = [engine, llama, chat]
        #expect(!RelayCapabilityTest.isEligible(provider: engine, model: model))
        #expect(!RelayCapabilityTest.isEligible(provider: llama, model: model))
        #expect(RelayCapabilityTest.isEligible(provider: chat, model: model))
        #expect(await state.providerManager.runRelayCapabilityTest(providerID: engine.id, modelID: model.id) == nil)
        #expect(await state.providerManager.runRelayCapabilityTest(providerID: llama.id, modelID: model.id) == nil)
        #expect(await state.providerManager.runRelayCapabilityTest(providerID: chat.id, modelID: "not-enabled") == nil)
        #expect(RelayCapabilityFakeServer.captured().isEmpty)
    }

    @Test("RL2-PROBE-06 entry point: 'Test capabilities' is hidden when image and tools both already have user overrides, or when the effective protocol is not one of the four")
    func rl2Probe06EntryVisibility() throws {
        var model = TestFactories.makeModel(id: "gpt-4o-mini", capabilities: [.text], isDefault: true)
        let chat = Self.relayProvider(transport: .openaiChatCompletions, model: model)
        #expect(RelayCapabilityTest.showsEntry(provider: chat, model: model))

        model.relayCapabilityOverrides = RelayCapabilityOverrides(image: false, source: .user)
        #expect(RelayCapabilityTest.showsEntry(provider: chat, model: model), "with only one user item, the other can still be tested")

        model.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, toolCall: true, source: .tested)
        #expect(RelayCapabilityTest.showsEntry(provider: chat, model: model), "a tested item can be retested")

        model.relayCapabilityOverrides = RelayCapabilityOverrides(image: true, toolCall: false, source: .user)
        let empty = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        #expect(!RelayCapabilityTest.showsEntry(provider: chat, model: model, fragments: empty))

        // Image and tools are both user-set, but the first-send protocol has a stored web fragment -> web can still be tested, so the entry stays visible.
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let raw = try #require(RelayWebFragments.template(for: .openaiChatCompletions))
        #expect(fragments.save(connectionID: chat.id, transport: .openaiChatCompletions, raw: raw) == nil)
        #expect(RelayCapabilityTest.showsEntry(provider: chat, model: model, fragments: fragments), "the entry stays when web can be listed")
        #expect(RelayCapabilityTest.plannedKinds(provider: chat, model: model, fragments: fragments) == [.text, .web])

        var llamaModel = TestFactories.makeModel(id: "local", capabilities: [.text], isDefault: true)
        llamaModel.relayTransport = .llamacppNative
        llamaModel.relayTransportSource = .user
        #expect(!RelayCapabilityTest.showsEntry(provider: chat, model: llamaModel), "the model protocol is native llama.cpp")
    }

    // MARK: - T4 restore automatic

    @Test("RL2-PROBE-06 restoreAutomatic: clears only tested items and omits the field when empty; the production write-back keeps the enabled list and catalog on the same id")
    func rl2Probe06RestoreAutomatic() async throws {
        let fixture = try Self.fixture()
        let cases = try #require((fixture["restoreAutomatic"] as? [String: Any])?["cases"] as? [[String: Any]])
        #expect(cases.count == 2)
        for testCase in cases {
            let caseId = testCase["caseId"] as? String ?? "<no id>"
            let before = try Self.overrides(testCase["before"])
            let after = try Self.overrides(testCase["after"])
            #expect(RelayCapabilityTest.hasTestedEntries(before), "\(caseId)")
            #expect(RelayCapabilityTest.restoreAutomatic(before) == after, "\(caseId)")

            var model = TestFactories.makeModel(id: "qwen-plus", capabilities: [.text], isDefault: true)
            model.relayCapabilityOverrides = before
            let state = Self.makeState()
            let provider = Self.relayProvider(transport: .openaiChatCompletions, model: model)
            state.providers = [provider]
            state.providerManager.restoreRelayCapabilityAutomatic(providerID: provider.id, modelID: "qwen-plus")

            let current = try #require(state.provider(for: provider.id))
            let encoded = try JSONEncoder().encode(current)
            let stored = try JSONDecoder().decode(Provider.self, from: encoded)
            #expect(stored.models.first?.relayCapabilityOverrides == after, "\(caseId)")
            #expect(stored.catalogModels.first?.relayCapabilityOverrides == after, "\(caseId) catalog")
            #expect(!RelayCapabilityTest.hasTestedEntries(stored.models.first?.relayCapabilityOverrides), "\(caseId)")
        }
    }
}
