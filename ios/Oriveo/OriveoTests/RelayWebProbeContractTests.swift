import Foundation
import Testing
@testable import Oriveo

/// Records the requests the probe actually sent during a test.
private final class WebProbeSendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { items.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { items }
    }
}

/// RL2-WEBPROBE: core of the relay web probe, driven by the caseIds in `shared/test-fixtures/relay/web-probe.v1.json`.
/// Scenarios go through the production `ProviderManager.runRelayWebProbe` -> the production chat builder (merging the locally stored fragment) -> replay by an injected fake upstream ->
/// the production Strategy parses the evidence; record and override assertions read the production store and the written-back model.
@Suite("RL2-WEBPROBE - relay web probe", .serialized, .sharedProcessState)
@MainActor
struct RelayWebProbeContractTests {
    // MARK: - Fixtures

    nonisolated private static func loadFixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return (object as? [String: Any]) ?? [:]
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    nonisolated private static let fixture: [String: Any] = (try? loadFixture("web-probe.v1.json")) ?? [:]

    nonisolated private static func caseIds(_ key: String) -> [String] {
        ((fixture[key] as? [[String: Any]]) ?? []).compactMap { $0["caseId"] as? String }
    }

    nonisolated private static let shapeCaseIds = caseIds("requestShapes")
    nonisolated private static let evidenceCaseIds = caseIds("evidenceCases")
    nonisolated private static let mergeCaseIds = ((fixture["record"] as? [String: Any])?["mergeCases"] as? [[String: Any]] ?? [])
        .compactMap { $0["caseId"] as? String }
    nonisolated private static let hashCaseIds = ((fixture["fragmentHash"] as? [String: Any])?["cases"] as? [[String: Any]] ?? [])
        .compactMap { $0["caseId"] as? String }
    nonisolated private static let gatewayKeys = ((fixture["gatewayRecordings"] as? [String: Any]) ?? [:])
        .keys.filter { !$0.hasPrefix("$") }.sorted()

    private static func item(_ list: [[String: Any]]?, _ caseId: String) throws -> [String: Any] {
        try #require(list?.first { $0["caseId"] as? String == caseId }, "\(caseId)")
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
    }

    /// Fixture subset matching: objects match as a key-wise subset, arrays of equal length match item-wise as subsets, scalars must be equal.
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

    /// mustContain: objects must contain each key, every expected item of an array must be found in the actual array (tools the builder brings along may coexist,
    /// e.g. the Responses chat builder always carries image_generation, with the fragment tool appended after it), scalars must be equal.
    private static func contains(_ expected: Any, in actual: Any?) -> Bool {
        if let object = expected as? [String: Any] {
            guard let actualObject = actual as? [String: Any] else { return false }
            return object.allSatisfy { key, value in contains(value, in: actualObject[key]) }
        }
        if let array = expected as? [Any] {
            guard let actualArray = actual as? [Any] else { return false }
            return array.allSatisfy { item in actualArray.contains { contains(item, in: $0) } }
        }
        guard let actual else { return false }
        return (expected as? NSObject)?.isEqual(actual) ?? false
    }

    private static func containsInt(_ value: Any?, _ target: Int) -> Bool {
        if let object = value as? [String: Any] { return object.values.contains { containsInt($0, target) } }
        if let array = value as? [Any] { return array.contains { containsInt($0, target) } }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue == target }
        return false
    }

    nonisolated private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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

    // MARK: - Scenarios

    private static var retainedStates: [AppState] = []
    private static let fixedNow = Date(timeIntervalSince1970: 1_791_902_703)

    private static func makeState(session: URLSession? = nil) -> AppState {
        let configuration = URLSessionConfiguration.ephemeral
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-web-probe-\(UUID().uuidString)",
            providerSession: session ?? URLSession(configuration: configuration)
        )
        retainedStates.append(state)
        return state
    }

    private static func isolatedDefaults() -> UserDefaults {
        let name = "relay-web-probe-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func provider(
        kind: ProviderKind = .relay,
        authMode: ProviderAuthMode = .apiKey,
        transport: RelayTransport,
        model: AIModel
    ) -> Provider {
        var provider = Provider(
            id: UUID(),
            kind: kind,
            status: .connected,
            models: [model],
            catalogModels: [model],
            apiKey: "sk-test",
            apiKeyPreview: "...test",
            baseURLText: "https://relay.example.com",
            relayRequested: kind == .relay
                ? RelayRequestedConfig(transport: transport, authMode: .auto, securityMode: .remoteHTTPS)
                : nil
        )
        provider.authMode = authMode
        return provider
    }

    private struct Run {
        let run: RelayWebProbe.Run?
        let requests: [URLRequest]
        let provider: Provider
        let records: RelayWebProbeStore
        let transport: RelayTransport
        let fragmentHash: String?
    }

    /// Builds a connection, stores the fragment for this transport as needed, and runs the production probe; `reply` is the fake upstream.
    private static func run(
        kind: ProviderKind = .relay,
        authMode: ProviderAuthMode = .apiKey,
        transport: RelayTransport,
        fragment: [String: Any]?,
        existingOverrides: RelayCapabilityOverrides? = nil,
        existingRecord: RelayWebProbeRecord.Result? = nil,
        deadline: Duration = .seconds(5),
        reply: @escaping @Sendable (URLRequest) async throws -> RelayCapabilityTest.Response
    ) async throws -> Run {
        var model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        model.relayCapabilityOverrides = existingOverrides
        let provider = provider(kind: kind, authMode: authMode, transport: transport, model: model)
        let fragments = RelayWebFragmentStore(defaults: isolatedDefaults())
        if let fragment {
            let raw = try #require(String(data: json(fragment), encoding: .utf8))
            #expect(fragments.save(connectionID: provider.id, transport: transport, raw: raw) == nil)
        }
        let records = RelayWebProbeStore(defaults: isolatedDefaults(), clock: { fixedNow })
        if let existingRecord, let fragment {
            records.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue,
                result: existingRecord, source: .tested, fragmentHash: RelayWebProbe.fragmentHash(fragment)
            )
        }
        let state = makeState()
        state.providers = [provider]
        let log = WebProbeSendLog()
        let result = await state.providerManager.runRelayWebProbe(
            providerID: provider.id,
            modelID: model.id,
            deadline: deadline,
            send: { request in
                log.append(request)
                return try await reply(request)
            },
            fragments: fragments,
            records: records
        )
        let after = try #require(state.providerManager.provider(for: provider.id))
        return Run(
            run: result,
            requests: log.requests,
            provider: after,
            records: records,
            transport: transport,
            fragmentHash: fragment.map { RelayWebProbe.fragmentHash($0) }
        )
    }

    nonisolated private static func sseResponse(_ lines: [String], status: Int = 200) -> RelayCapabilityTest.Response {
        RelayCapabilityTest.Response(
            status: status, contentType: "text/event-stream",
            body: Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    private static func template(_ transport: RelayTransport) throws -> [String: Any] {
        let raw = try #require(RelayWebFragments.template(for: transport))
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private static func outcome(_ run: Run, _ label: String) throws -> RelayWebProbe.Outcome {
        guard case let .probed(outcome) = try #require(run.run, "\(label)") else {
            Issue.record("\(label): expected to have probed, got \(String(describing: run.run))")
            throw CancellationError()
        }
        return outcome
    }

    private static func storedRecord(_ run: Run) -> RelayWebProbeRecord? {
        run.records.record(
            connectionID: run.provider.id.uuidString, modelID: "relay-model", transport: run.transport.rawValue
        )
    }

    private static func webOverride(_ run: Run) -> (value: Bool?, source: RelayCapabilityOverrides.Source?) {
        let overrides = run.provider.models.first?.relayCapabilityOverrides
        return (overrides?.web, overrides?.sources[.web])
    }

    /// Result -> record and overrides (classify section): searched / rejected / silent write a record (tested, injected clock, current fragment hash),
    /// searched / rejected additionally write the web override; undetermined writes nothing.
    private static func expectWriteback(_ run: Run, result: String, _ label: String) {
        let record = storedRecord(run)
        if ["searched", "rejected", "silent"].contains(result) {
            #expect(record?.result.rawValue == result, "\(label) record.result")
            #expect(record?.source == .tested, "\(label) record.source")
            #expect(record?.at == fixedNow, "\(label) record.at")
            #expect(record?.fragmentHash == run.fragmentHash, "\(label) record.fragmentHash")
        } else {
            #expect(record == nil, "\(label) writes no record")
        }
        let web = webOverride(run)
        switch result {
        case "searched":
            #expect(web.value == true && web.source == .tested, "\(label) web override")
        case "rejected":
            #expect(web.value == false && web.source == .tested, "\(label) web override")
        default:
            #expect(web.value == nil, "\(label) writes no web override")
        }
    }

    // MARK: - SHAPE

    @Test("RL2-WEBPROBE-03 SHAPE", arguments: shapeCaseIds)
    func shape(caseId: String) async throws {
        let label = "RL2-WEBPROBE-SHAPE-\(caseId)"
        let testCase = try Self.item(Self.fixture["requestShapes"] as? [[String: Any]], caseId)
        let request = try #require(Self.fixture["request"] as? [String: Any])
        let transport = try #require(RelayTransport(rawValue: testCase["transport"] as? String ?? ""))
        let fragment = try #require(testCase["fragment"] as? [String: Any])

        let run = try await Self.run(transport: transport, fragment: fragment) { _ in
            Self.sseResponse(["data: [DONE]"])
        }
        #expect(run.requests.count == request["attempts"] as? Int, "\(label) sent only once")
        let sent = try #require(run.requests.first, "\(label)")
        let data = Self.body(of: sent)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], "\(label)")
        let text = String(decoding: data, as: UTF8.self)
        #expect(Self.contains(try #require(testCase["mustContain"]), in: parsed), "\(label) mustContain")
        if testCase["mustContainPrompt"] as? Bool == true {
            let prompt = try #require(request["prompt"] as? String)
            #expect(text.contains(prompt) || text.contains(prompt.replacingOccurrences(of: "'", with: "\\u0027")), "\(label) prompt")
            #expect(RelayWebProbe.prompt == prompt, "\(label) prompt constant")
        }
        #expect(Self.containsInt(parsed, try #require(request["outputLimit"] as? Int)), "\(label) outputLimit")
        let capability = try Self.loadFixture("capability-test.v1.json")
        let builtins = try #require(capability["builtins"] as? [String: Any])
        for path in testCase["mustNotContain"] as? [String] ?? [] {
            let needle: String? = switch path {
            case "builtins.imagePNGBase64": builtins["imagePNGBase64"] as? String
            case "builtins.tool.name": (builtins["tool"] as? [String: Any])?["name"] as? String
            default: nil
            }
            let value = try #require(needle, "\(label) unrecognized mustNotContain \(path)")
            #expect(!text.contains(value), "\(label) mustNotContain \(path)")
        }
        #expect(RelayWebProbe.outputLimit == request["outputLimit"] as? Int)
        #expect(RelayWebProbe.timeoutSeconds == request["timeoutSeconds"] as? Int)
    }

    // MARK: - EV

    @Test("RL2-WEBPROBE-04 EV", arguments: evidenceCaseIds)
    func evidence(caseId: String) async throws {
        let label = "RL2-WEBPROBE-EV-\(caseId)"
        let testCase = try Self.item(Self.fixture["evidenceCases"] as? [[String: Any]], caseId)
        let transport = try #require(RelayTransport(rawValue: testCase["transport"] as? String ?? ""))
        let expect = try #require(testCase["expect"] as? [String: Any])
        let expectedResult = try #require(expect["result"] as? String)

        let response: RelayCapabilityTest.Response?
        if testCase["failure"] as? String == "timeout" {
            response = nil
        } else if let sse = testCase["sse"] as? [String] {
            response = Self.sseResponse(sse, status: try #require(testCase["status"] as? Int))
        } else {
            response = RelayCapabilityTest.Response(
                status: try #require(testCase["status"] as? Int),
                contentType: "application/json",
                body: Self.json(try #require(testCase["body"]))
            )
        }
        let run = try await Self.run(
            transport: transport, fragment: try Self.template(transport),
            deadline: response == nil ? .milliseconds(300) : .seconds(5)
        ) { _ in
            guard let response else {
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            return response
        }
        #expect(run.requests.count == 1, "\(label) sent only once")
        let outcome = try Self.outcome(run, label)
        #expect(outcome.result.rawValue == expectedResult, "\(label) result")
        if let urls = expect["evidenceUrls"] as? [String] {
            #expect(outcome.evidenceUrls == urls, "\(label) evidenceUrls")
        }
        if testCase["failure"] as? String == "timeout" {
            #expect(outcome.reason == .timeout, "\(label) reason")
        }
        Self.expectWriteback(run, result: expectedResult, label)
    }

    // MARK: - GW

    @Test("RL2-WEBPROBE-09 GW", arguments: gatewayKeys)
    func gateway(key: String) async throws {
        let label = "RL2-WEBPROBE-GW-\(key)"
        let recordings = try #require(Self.fixture["gatewayRecordings"] as? [String: Any])
        let recording = try #require(recordings[key] as? [String: Any])
        let response = try #require(recording["response"] as? [String: Any])
        let expect = try #require(recording["expect"] as? [String: Any])
        let transport = try #require(RelayTransport(rawValue: expect["transport"] as? String ?? ""))
        let requestBody = (recording["request"] as? [String: Any])?["body"] as? [String: Any] ?? [:]
        let fragment: [String: Any] = try requestBody["web_search_options"].map { ["web_search_options": $0] }
            ?? Self.template(transport)
        let replay = RelayCapabilityTest.Response(
            status: try #require(response["status"] as? Int),
            contentType: response["contentType"] as? String ?? "text/event-stream",
            body: Data(((try #require(response["sse"] as? [String])).joined(separator: "\n\n") + "\n\n").utf8)
        )
        let run = try await Self.run(transport: transport, fragment: fragment) { _ in replay }
        let outcome = try Self.outcome(run, label)
        let expectedResult = try #require(expect["result"] as? String)
        #expect(outcome.result.rawValue == expectedResult, "\(label) result")
        #expect(outcome.evidenceUrls == expect["evidenceUrls"] as? [String], "\(label) evidenceUrls")
        Self.expectWriteback(run, result: expectedResult, label)
    }

    // MARK: - HASH

    @Test("RL2-WEBPROBE-05 HASH", arguments: hashCaseIds)
    func hash(caseId: String) throws {
        let label = "RL2-WEBPROBE-HASH-\(caseId)"
        let cases = (Self.fixture["fragmentHash"] as? [String: Any])?["cases"] as? [[String: Any]]
        let testCase = try Self.item(cases, caseId)
        let fragment = try #require(testCase["fragment"] as? [String: Any])
        #expect(RelayWebProbe.canonicalJSON(fragment) == testCase["canonical"] as? String, "\(label) canonical")
        #expect(RelayWebProbe.fragmentHash(fragment) == testCase["sha256"] as? String, "\(label) sha256")
    }

    // MARK: - MERGE

    @Test("RL2-WEBPROBE-06 MERGE", arguments: mergeCaseIds)
    func merge(caseId: String) throws {
        let label = "RL2-WEBPROBE-MERGE-\(caseId)"
        let cases = (Self.fixture["record"] as? [String: Any])?["mergeCases"] as? [[String: Any]]
        let testCase = try Self.item(cases, caseId)
        let expect = try #require(testCase["expect"] as? [String: Any])
        let store = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        let connection = UUID().uuidString
        func write(_ raw: Any?) throws {
            guard let object = raw as? [String: Any] else { return }
            store.record(
                connectionID: connection, modelID: "relay-model", transport: RelayTransport.anthropicMessages.rawValue,
                result: try #require(RelayWebProbeRecord.Result(rawValue: object["result"] as? String ?? "")),
                source: try #require(RelayWebProbeRecord.Source(rawValue: object["source"] as? String ?? "")),
                fragmentHash: try #require(object["fragmentHash"] as? String)
            )
        }
        try write(testCase["existing"])
        try write(testCase["incoming"])
        let stored = store.record(
            connectionID: connection, modelID: "relay-model", transport: RelayTransport.anthropicMessages.rawValue
        )
        #expect(stored?.result.rawValue == expect["result"] as? String, "\(label) result")
        #expect(stored?.source.rawValue == expect["source"] as? String, "\(label) source")
        // Hash != current fragment = untested.
        if let incoming = testCase["incoming"] as? [String: Any], let hash = incoming["fragmentHash"] as? String {
            #expect(store.current(
                connectionID: connection, modelID: "relay-model", transport: RelayTransport.anthropicMessages.rawValue,
                fragmentHash: hash
            ) != nil, "\(label) current hash is readable")
            #expect(store.current(
                connectionID: connection, modelID: "relay-model", transport: RelayTransport.anthropicMessages.rawValue,
                fragmentHash: "other"
            ) == nil, "\(label) different hash = untested")
        }
        store.clearConnection(connection)
        #expect(store.record(
            connectionID: connection, modelID: "relay-model", transport: RelayTransport.anthropicMessages.rawValue
        ) == nil, "\(label) deleted along with the connection")
    }

    // MARK: - FORMS

    @Test("RL2-WEBPROBE-13 FORMS")
    func forms() async throws {
        let forms = try #require(Self.fixture["forms"] as? [String: Any])
        #expect(forms["probe"] as? [String] == ["RELAY"])
        let never: [String: (ProviderKind, ProviderAuthMode)] = [
            "BYOK": (.openAI, .apiKey),
            "SUB": (.openAI, .subscription),
        ]
        for form in forms["never"] as? [String] ?? [] {
            guard let (kind, authMode) = never[form] else { continue } // community edition has no FREE / MANAGED forms
            let run = try await Self.run(
                kind: kind, authMode: authMode, transport: .openaiChatCompletions,
                fragment: try Self.template(.openaiChatCompletions)
            ) { _ in Self.sseResponse(["data: [DONE]"]) }
            #expect(run.run == .notListed, "RL2-WEBPROBE-FORMS \(form)")
            #expect(run.requests.isEmpty, "RL2-WEBPROBE-FORMS \(form) zero requests")
        }
        // RELAY without a fragment for this transport = not listed, zero requests.
        let bare = try await Self.run(transport: .openaiChatCompletions, fragment: nil) { _ in
            Self.sseResponse(["data: [DONE]"])
        }
        #expect(bare.run == .notListed, "RL2-WEBPROBE-FORMS RELAY without fragment")
        #expect(bare.requests.isEmpty, "RL2-WEBPROBE-FORMS RELAY without fragment, zero requests")
        let relay = try await Self.run(
            transport: .openaiChatCompletions, fragment: try Self.template(.openaiChatCompletions)
        ) { _ in Self.sseResponse(["data: [DONE]"]) }
        #expect(relay.requests.count == 1, "RL2-WEBPROBE-FORMS RELAY with fragment sends once")
    }

    // MARK: - OVERRIDE

    private static func evidenceResponse(_ caseId: String) throws -> RelayCapabilityTest.Response {
        let testCase = try item(fixture["evidenceCases"] as? [[String: Any]], caseId)
        if let sse = testCase["sse"] as? [String] {
            return sseResponse(sse, status: try #require(testCase["status"] as? Int))
        }
        return RelayCapabilityTest.Response(
            status: try #require(testCase["status"] as? Int), contentType: "application/json",
            body: json(try #require(testCase["body"]))
        )
    }

    @Test("RL2-WEBPROBE-10 OVERRIDE")
    func override() async throws {
        #expect(RelayCapabilityOverrides.Key.allCases.last == .web, "web is appended at the end of the override keys")

        let searched = try Self.evidenceResponse("chat_url_citation_searched")
        let rejected = try Self.evidenceResponse("chat_400_rejected")
        let silent = try Self.evidenceResponse("chat_text_only_silent")
        let fragment = try Self.template(.openaiChatCompletions)

        let a = try await Self.run(transport: .openaiChatCompletions, fragment: fragment) { _ in searched }
        #expect(Self.webOverride(a).value == true && Self.webOverride(a).source == .tested, "searched → web true tested")

        let b = try await Self.run(transport: .openaiChatCompletions, fragment: fragment) { _ in rejected }
        #expect(Self.webOverride(b).value == false && Self.webOverride(b).source == .tested, "rejected → web false tested")

        // The override mirrors the merged current record: silent does not erase a searched record, and the tested web stays true.
        var testedTrue = RelayCapabilityOverrides(source: .tested)
        testedTrue.setValue(true, for: .web, source: .tested)
        let c = try await Self.run(
            transport: .openaiChatCompletions, fragment: fragment, existingOverrides: testedTrue, existingRecord: .searched
        ) { _ in silent }
        #expect(Self.storedRecord(c)?.result == .searched, "silent does not erase a searched record")
        #expect(Self.webOverride(c).value == true && Self.webOverride(c).source == .tested, "record still searched -> web still true")

        // A web value the user set by hand is not touched (try both directions).
        var userFalse = RelayCapabilityOverrides()
        userFalse.setValue(false, for: .web, source: .user)
        let d = try await Self.run(transport: .openaiChatCompletions, fragment: fragment, existingOverrides: userFalse) { _ in searched }
        #expect(Self.webOverride(d).value == false && Self.webOverride(d).source == .user, "user source untouched")
        #expect(Self.storedRecord(d)?.result == .searched, "a user override does not block the record")

        var userTrue = RelayCapabilityOverrides()
        userTrue.setValue(true, for: .web, source: .user)
        let e = try await Self.run(transport: .openaiChatCompletions, fragment: fragment, existingOverrides: userTrue) { _ in rejected }
        #expect(Self.webOverride(e).value == true && Self.webOverride(e).source == .user, "user source untouched")

        // The web override key round-trips through Codable (`{value, source}`), and restoring automatic clears the tested web.
        let encoded = try JSONEncoder().encode(try #require(a.provider.models.first?.relayCapabilityOverrides))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Self.subsetMatches(["web": ["value": true, "source": "tested"]], object), "web encoding")
        let decoded = try JSONDecoder().decode(RelayCapabilityOverrides.self, from: encoded)
        #expect(decoded.web == true && decoded.sources[.web] == .tested)
        #expect(RelayCapabilityTest.restoreAutomatic(decoded)?.web == nil)
    }
}

// MARK: - Chat side and presentation

/// Replays upstream responses in order and records the requests chat actually sent (used only by the chat section).
private final class WebProbeChatProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _script: [(status: Int, body: String)] = []
    private static let lock = NSLock()

    static let chatOK = """
    data: {"choices":[{"delta":{"content":"ok"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    static func reset(_ replies: [(Int, String)] = []) {
        lock.withLock {
            _requests = []
            _script = replies.map { ($0.0, $0.1) }
        }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebProbeChatProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let data = Self.readStream(request.httpBodyStream) {
            recorded.httpBody = data
        }
        let next: (status: Int, body: String) = Self.lock.withLock {
            Self._requests.append(recorded)
            return Self._script.isEmpty ? (200, Self.chatOK) : Self._script.removeFirst()
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

extension RelayWebProbeContractTests {
    nonisolated private static let presentationCaseIds = ((fixture["presentationCases"] as? [String: Any])?["cases"] as? [[String: Any]] ?? [])
        .compactMap { $0["caseId"] as? String }

    /// statusId -> each client's own copy and table (web_user_on = the source badge "Set by you").
    private static let statusCopy: [String: (key: String, table: L10n.Table)] = [
        "web_probe_searched": ("Search confirmed", .chat),
        "web_probe_silent": ("Didn’t search when tested", .chat),
        "web_probe_unverified": ("Set · not verified", .chat),
        "web_probe_rejected": ("This model rejects the web search settings", .chat),
        "web_probe_untested": ("Not tested yet", .providers),
        "web_user_off": ("Turned off in this model’s Advanced settings", .providers),
        "web_user_on": ("Set by you", .providers),
    ]

    /// A saved fragment that differs from the template: tells whether the request body carries the saved one or the template.
    private static let savedChatFragment = #"{"web_search_options":{"search_context_size":"low"}}"#

    private struct PresentationScenario {
        let provider: Provider
        let model: AIModel
        let fragments: RelayWebFragmentStore
        let records: RelayWebProbeStore
        let preference: Bool?
        let expect: [String: Any]
        let savedObject: [String: Any]
        let templateObject: [String: Any]
    }

    /// One fixture presentationCase -> isolated fragment / record / preference stores; the switch is resolved through the production `RelayWebSwitch` (preference store + default layer).
    private static func presentationScenario(_ caseId: String) throws -> PresentationScenario {
        let section = try #require(Self.fixture["presentationCases"] as? [String: Any])
        let testCase = try Self.item(section["cases"] as? [[String: Any]], caseId)
        let transport = RelayTransport.openaiChatCompletions
        var model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        if let userOverride = testCase["userOverride"] as? Bool {
            model.relayCapabilityOverrides = RelayCapabilityOverrides(web: userOverride, source: .user)
        }
        let provider = Self.provider(transport: transport, model: model)
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        let settings = GenerationParameterSettingsStore(defaults: Self.isolatedDefaults())
        let templateObject = try Self.template(transport)
        let savedObject = try #require(try JSONSerialization.jsonObject(with: Data(savedChatFragment.utf8)) as? [String: Any])
        let saved = testCase["savedFragment"] as? Bool == true
        if saved {
            #expect(fragments.save(connectionID: provider.id, transport: transport, raw: savedChatFragment) == nil, "\(caseId)")
        }
        if let record = testCase["record"] as? [String: Any] {
            let result = try #require(RelayWebProbeRecord.Result(rawValue: record["result"] as? String ?? ""))
            let hash = record["fragmentHash"] as? String == "current"
                ? RelayWebProbe.fragmentHash(saved ? savedObject : templateObject) : "other"
            records.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue,
                result: result, source: .tested, fragmentHash: hash
            )
        }
        let conversationID = UUID()
        if let preference = testCase["webPreference"] as? String {
            RelayWebSwitch.write(
                preference != "off", provider: provider, model: model, conversationID: conversationID, store: settings
            )
        }
        let resolved = RelayWebSwitch.isOn(
            provider: provider, model: model, conversationID: conversationID, store: settings, fragments: fragments
        )
        return PresentationScenario(
            provider: provider, model: model, fragments: fragments, records: records, preference: resolved,
            expect: try #require(testCase["expect"] as? [String: Any]),
            savedObject: savedObject, templateObject: templateObject
        )
    }

    // MARK: PRES

    /// The production fact (`RelayWebProbe.fact`, shared by the panel / sending / badge / advanced page) is compared field by field against the fixture;
    /// the request body fragment reads the same call chat sending uses (`RelayWebProbe.chatFragments`).
    @Test("RL2-WEBPROBE-08 PRES", arguments: presentationCaseIds)
    func presentation(caseId: String) throws {
        let label = "RL2-WEBPROBE-PRES-\(caseId)"
        #expect(Self.presentationCaseIds.count == 12, "\(label) fixture case count")
        let scenario = try Self.presentationScenario(caseId)
        let expect = scenario.expect
        let fact = try #require(RelayWebProbe.fact(
            provider: scenario.provider, model: scenario.model, preference: scenario.preference,
            fragments: scenario.fragments, records: scenario.records
        ), "\(label) in scope")
        #expect(fact.row.rawValue == expect["row"] as? String, "\(label) row: \(fact)")
        #expect(fact.isOn == expect["isOn"] as? Bool, "\(label) isOn: \(fact)")
        #expect(fact.statusId.rawValue == expect["statusId"] as? String, "\(label) statusId: \(fact)")
        let retest: String? = switch fact.retestLink {
        case .openConnectionWebSearch?: "openConnectionWebSearch"
        case .openTestCapabilities?: "testCapabilities"
        default: nil
        }
        #expect(retest == expect["retestLink"] as? String, "\(label) retestLink")
        #expect(fact.sendsFragment == expect["sendsFragment"] as? Bool, "\(label) sendsFragment")
        #expect(fact.replyNotice?.rawValue == expect["replyNotice"] as? String, "\(label) replyNotice: \(fact)")
        #expect(fact.truth.rawValue == expect["truth"] as? String, "\(label) truth")
        let advanced = try #require(expect["advanced"] as? [String: Any])
        #expect(fact.probeStatus.rawValue == advanced["statusId"] as? String, "\(label) advanced.statusId")
        #expect(fact.advancedSource?.rawValue == advanced["source"] as? String, "\(label) advanced.source")

        let sent = RelayWebProbe.chatFragments(
            provider: scenario.provider, model: scenario.model, webOn: scenario.preference ?? false,
            fragments: scenario.fragments, records: scenario.records
        )?.object(for: .openaiChatCompletions)
        switch expect["sentFragment"] as? String {
        case "saved"?:
            #expect(sent.map { NSDictionary(dictionary: $0) } == NSDictionary(dictionary: scenario.savedObject), "\(label) carries the saved fragment")
        case "template"?:
            #expect(sent.map { NSDictionary(dictionary: $0) } == NSDictionary(dictionary: scenario.templateObject), "\(label) carries the template")
        default:
            #expect(sent == nil, "\(label) carries no fragment")
        }
    }

    /// Model options web row (production `RelayWebProbe.panelFact` -> `ModelOptionCapabilityShape.resolve`): toggle / greyed out, default on or off, status line, retest exit.
    @Test("RL2-WEBPROBE-14 ROW", arguments: presentationCaseIds)
    func optionsRow(caseId: String) throws {
        let label = "RL2-WEBPROBE-14-\(caseId)"
        let scenario = try Self.presentationScenario(caseId)
        let expect = scenario.expect
        let shape = ModelOptionCapabilityShape.resolve(.init(
            capability: .web,
            // The presentation state given by the catalog must not affect the relay web row.
            presentation: .customOnly,
            connection: .custom,
            protocolUndecided: false,
            relayWeb: RelayWebProbe.panelFact(
                provider: scenario.provider, model: scenario.model, preference: scenario.preference,
                fragments: scenario.fragments, records: scenario.records
            )
        ))
        guard case let .toggle(toggle) = shape else { Issue.record("\(label): \(shape)"); return }
        #expect(toggle.isEnabled == (expect["row"] as? String == "toggle"), "\(label) row")
        #expect(toggle.isOn == expect["isOn"] as? Bool, "\(label) isOn")
        #expect(toggle.target == .capabilityPreference(on: "automatic", off: "off"), "\(label) target")
        let statusId = try #require(expect["statusId"] as? String)
        let copy = try #require(Self.statusCopy[statusId], "\(label) unknown statusId")
        #expect(toggle.caption == L10n.tr(copy.key, table: copy.table), "\(label) status row")
        switch expect["retestLink"] as? String {
        case "openConnectionWebSearch"?:
            #expect(toggle.link == .init(title: L10n.tr("Test again in Web Search", table: .chat), action: .openConnectionWebSearch), "\(label)")
        case "testCapabilities"?:
            #expect(toggle.link == .init(title: L10n.tr("Test capabilities", table: .providers), action: .openTestCapabilities), "\(label)")
        default:
            #expect(toggle.link == nil, "\(label) no retest")
        }
    }

    // MARK: CHAT (production AppState.sendMessage)

    private static func chatModel() -> AIModel {
        var model = AIModel(
            id: "relay-chat-model", name: "relay-chat-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = .openaiChatCompletions
        model.relayTransportSource = .reachable
        return model
    }

    private static func chatProvider(_ model: AIModel, transport: RelayTransport = .openaiChatCompletions) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
    }

    /// An unverified Claude-family model on an auto connection: the first catalog endpoint type is anthropic -> first send uses Messages, effective transport is Chat.
    private static func firstSendMessagesProvider() -> (Provider, AIModel) {
        let model = AIModel(
            id: "claude-sonnet-4", name: "claude-sonnet-4", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        var provider = chatProvider(model, transport: .auto)
        provider.baseURLText = "https://webprobe-\(provider.id.uuidString.lowercased()).example.com/v1"
        RelayCatalogEndpointTypesCache.shared.record(
            endpoint: provider.baseURLText ?? "", endpointTypesByModel: [model.id: ["anthropic", "openai"]]
        )
        return (provider, model)
    }

    private static func cleanUp(_ provider: Provider) {
        RelayWebFragmentStore.shared.deleteConnection(provider.id)
        RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
        RelayCatalogEndpointTypesCache.shared.record(endpoint: provider.baseURLText ?? "", endpointTypesByModel: [:])
    }

    private static func saveTemplate(_ transport: RelayTransport, for provider: Provider, in store: RelayWebFragmentStore = .shared) throws {
        let raw = try #require(String(data: json(try template(transport)), encoding: .utf8))
        #expect(store.save(connectionID: provider.id, transport: transport, raw: raw) == nil)
    }

    /// Sends one message through the production `AppState.sendMessage` (fragment and records go through the shared store), and returns the outbound request bodies and the last message.
    private static func sendChat(
        provider: Provider, modelID: String, replies: [(Int, String)] = []
    ) async throws -> (bodies: [[String: Any]], message: ChatMessage?) {
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        // The shared metadata fixture has no Chat web profile; per the production catalog contract (metadata_catalog_contract.v1.json) add oai_web_tool,
        // whose citation path is only message.annotations.
        var root = try loadFixture("metadata-fixture.json")
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        var webSearch = profiles["webSearch"] as? [String: Any] ?? [:]
        webSearch["oai_web_tool"] = [
            "mergeParams": [String: Any](),
            "streamShape": [
                "citationTitleField": "url_citation.title",
                "citationUrlField": "url_citation.url",
                "citationsArrayPath": "choices.0.message.annotations",
            ],
        ]
        webSearch["ant_web_tool"] = [
            "mergeParams": ["tools": [["max_uses": 5, "name": "web_search", "type": "web_search_20250305"]]],
            "streamShape": ["citationSnippetField": "cited_text", "citationsBlockType": "web_search_tool_result"],
        ]
        profiles["webSearch"] = webSearch
        root["profiles"] = profiles
        let metadata = try JSONSerialization.data(withJSONObject: root)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: metadata, as: UTF8.self))
        WebProbeChatProtocol.reset(replies)
        let state = AppState(
            seedDemoData: false,
            sessionUID: "relay-web-probe-chat-\(UUID().uuidString)",
            providerSession: WebProbeChatProtocol.session()
        )
        retainedStates.append(state)
        let conversation = TestFactories.makeConversation(providerID: provider.id, providerKind: .relay, modelID: modelID)
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        _ = await state.sendMessage("search the news", attachments: [], in: conversation.id, capabilitySelection: ChatCapabilitySelection())
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let message = state.conversation(for: conversation.id)?.messages.last,
               message.role == .assistant, message.state == .failed || message.state == .delivered {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let bodies = WebProbeChatProtocol.requests.map { request -> [String: Any] in
            let data = request.httpBody ?? WebProbeChatProtocol.readStream(request.httpBodyStream)
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        return (bodies, state.conversation(for: conversation.id)?.messages.last)
    }

    private static func sseText(_ caseId: String) throws -> String {
        let testCase = try item(fixture["evidenceCases"] as? [[String: Any]], caseId)
        let lines = try #require(testCase["sse"] as? [String])
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("RL2-WEBPROBE-09 CHAT-01: with the current fragment, rejected -> chat does not attach the fragment; silent / untested / stale hash attach as usual")
    func chat01() async throws {
        let template = try Self.template(.openaiChatCompletions)
        let raw = try #require(String(data: Self.json(template), encoding: .utf8))
        let current = RelayWebProbe.fragmentHash(template)
        let variants: [(name: String, record: (RelayWebProbeRecord.Result, String)?, sends: Bool)] = [
            ("rejected", (.rejected, current), false),
            ("silent", (.silent, current), true),
            ("untested", nil, true),
            ("stale_rejected", (.rejected, "other"), true),
        ]
        for variant in variants {
            let label = "RL2-WEBPROBE-CHAT-01-\(variant.name)"
            let model = Self.chatModel()
            let provider = Self.chatProvider(model)
            defer {
                RelayWebFragmentStore.shared.deleteConnection(provider.id)
                RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
            }
            #expect(RelayWebFragmentStore.shared.save(connectionID: provider.id, transport: .openaiChatCompletions, raw: raw) == nil)
            if let (result, hash) = variant.record {
                RelayWebProbeStore.shared.record(
                    connectionID: provider.id.uuidString, modelID: model.id,
                    transport: RelayTransport.openaiChatCompletions.rawValue,
                    result: result, source: .tested, fragmentHash: hash
                )
            }
            let sent = try await Self.sendChat(provider: provider, modelID: model.id)
            let body = try #require(sent.bodies.first, "\(label) the production send chain sent no request")
            #expect(body["model"] as? String == model.id, "\(label) precondition")
            #expect((body["web_search_options"] != nil) == variant.sends, "\(label) fragment attachment")
        }
    }

    @Test("RL2-WEBPROBE-02 the switch decides the request body (production sendMessage): off without a fragment / on without a saved one -> template / on with a saved one -> saved / override off or rejected -> none")
    func chatSwitchDecidesBody() async throws {
        let template = try Self.template(.openaiChatCompletions)
        let variants: [(name: String, saved: Bool, switchOn: Bool?, userOff: Bool, rejected: Bool, expect: String?)] = [
            ("unset_no_saved_off", false, nil, false, false, nil),
            ("on_no_saved_template", false, true, false, false, "template"),
            ("off_saved_nothing", true, false, false, false, nil),
            ("unset_saved_default_on", true, nil, false, false, "saved"),
            ("on_saved", true, true, false, false, "saved"),
            ("on_user_off", true, true, true, false, nil),
            ("on_template_rejected", false, true, false, true, nil),
        ]
        for variant in variants {
            let label = "RL2-WEBPROBE-02-\(variant.name)"
            var model = Self.chatModel()
            if variant.userOff { model.relayCapabilityOverrides = RelayCapabilityOverrides(web: false, source: .user) }
            let provider = Self.chatProvider(model)
            defer { Self.cleanUp(provider) }
            if variant.saved {
                #expect(RelayWebFragmentStore.shared.save(
                    connectionID: provider.id, transport: .openaiChatCompletions, raw: Self.savedChatFragment
                ) == nil, "\(label)")
            }
            if variant.rejected {
                RelayWebProbeStore.shared.record(
                    connectionID: provider.id.uuidString, modelID: model.id,
                    transport: RelayTransport.openaiChatCompletions.rawValue,
                    result: .rejected, source: .tested, fragmentHash: RelayWebProbe.fragmentHash(template)
                )
            }
            // Write the switch at the model-default scope: the conversation layer is unset, so the ladder falls to this layer.
            if let on = variant.switchOn {
                RelayWebSwitch.write(on, provider: provider, model: model, conversationID: nil)
            }
            let sent = try await Self.sendChat(provider: provider, modelID: model.id)
            let body = try #require(sent.bodies.first, "\(label) the production send chain sent no request")
            #expect(body["model"] as? String == model.id, "\(label) precondition")
            let options = body["web_search_options"] as? [String: Any]
            switch variant.expect {
            case "template"?:
                #expect(options != nil && options?.isEmpty == true, "\(label) carries the template: \(String(describing: options))")
            case "saved"?:
                #expect(options?["search_context_size"] as? String == "low", "\(label) carries the saved one: \(String(describing: options))")
            default:
                #expect(body["web_search_options"] == nil, "\(label) carries no fragment")
            }
        }
    }

    @Test("RL2-WEBPROBE-14 nometa: a relay model without a metadata identity gets the switch turned on -> still on after re-entering -> the request body carries the fragment; still on after the first-send protocol changes")
    func switchWithoutMetadataIdentity() async throws {
        var model = Self.chatModel()
        let provider = Self.chatProvider(model)
        defer { Self.cleanUp(provider) }
        #expect(CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model) == nil, "precondition: no metadata identity")
        #expect(RelayWebSwitch.isOn(provider: provider, model: model, conversationID: nil) == false, "never set and no saved fragment = off")
        RelayWebSwitch.write(true, provider: provider, model: model, conversationID: nil)
        #expect(RelayWebSwitch.isOn(provider: provider, model: model, conversationID: nil) == true, "reads back on after re-entering")
        let sent = try await Self.sendChat(provider: provider, modelID: model.id)
        #expect(sent.bodies.first?["web_search_options"] != nil, "the request body carries the template fragment")
        // The model's first-send protocol changes to Responses: the switch is still the same record.
        model.relayTransport = .openaiResponses
        model.relayTransportSource = .user
        var switched = provider
        switched.models = [model]
        #expect(RelayWebSwitch.isOn(provider: switched, model: model, conversationID: nil) == true, "still on after the first-send protocol switch")
        #expect(RelayWebProbe.chatFragments(provider: switched, model: model, webOn: true)?.object(for: .openaiResponses) != nil,
                "the first-send protocol's section is present")
    }

    @Test("RL2-WEBPROBE-09 CHAT-02: delivered with a fragment and the parser yields citations -> searched / observed; no citations or an error writes nothing")
    func chat02() async throws {
        let template = try Self.template(.openaiChatCompletions)
        let raw = try #require(String(data: Self.json(template), encoding: .utf8))
        let current = RelayWebProbe.fragmentHash(template)
        let variants: [(name: String, reply: (Int, String), expect: RelayWebProbeRecord.Result?)] = [
            ("chat_url_citation_searched", (200, try Self.sseText("chat_url_citation_searched")), .searched),
            ("chat_text_only_silent", (200, try Self.sseText("chat_text_only_silent")), nil),
            ("chat_error_after_output_undetermined", (200, try Self.sseText("chat_error_after_output_undetermined")), nil),
            ("http_503", (503, #"{"error":{"message":"busy"}}"#), nil),
        ]
        for variant in variants {
            let label = "RL2-WEBPROBE-CHAT-02-\(variant.name)"
            let model = Self.chatModel()
            let provider = Self.chatProvider(model)
            defer {
                RelayWebFragmentStore.shared.deleteConnection(provider.id)
                RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
            }
            #expect(RelayWebFragmentStore.shared.save(connectionID: provider.id, transport: .openaiChatCompletions, raw: raw) == nil)
            let sent = try await Self.sendChat(provider: provider, modelID: model.id, replies: [variant.reply])
            #expect(sent.bodies.first?["web_search_options"] != nil, "\(label) precondition: this turn carried the fragment")
            let record = RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayTransport.openaiChatCompletions.rawValue
            )
            if let expected = variant.expect {
                #expect(sent.message?.state == .delivered, "\(label) precondition: delivered")
                #expect(sent.message?.citations?.map(\.url) == ["https://news.example.com/top"], "\(label) delta.annotations goes into citations")
                #expect(record?.result == expected, "\(label) result")
                #expect(record?.source == .observed, "\(label) source")
                #expect(record?.fragmentHash == current, "\(label) fragmentHash")
            } else {
                #expect(record == nil, "\(label) writes no record: \(String(describing: record))")
            }
        }
    }

    // MARK: First-send transport

    @Test("RL2-WEBPROBE-PRES-first_send: the panel judges the saved fragment, the effective fragment and the record by the first-send transport (a Claude-family model whose first send is Messages on an auto connection)")
    func presentationFirstSend() throws {
        let (provider, model) = Self.firstSendMessagesProvider()
        defer { Self.cleanUp(provider) }
        #expect(RelayEndpointResolver.effectiveTransport(provider: provider, model: model) == .openaiChatCompletions, "precondition: effective transport is Chat")
        #expect(RelayWebProbe.transport(provider: provider, model: model) == .anthropicMessages, "precondition: first send is Messages")
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })

        func fact(_ fragments: RelayWebFragmentStore) -> RelayWebFact? {
            RelayWebProbe.fact(provider: provider, model: model, preference: nil, fragments: fragments, records: records)
        }

        // Store only the Messages fragment and write searched -> Search confirmed, on by default.
        let messagesOnly = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        try Self.saveTemplate(.anthropicMessages, for: provider, in: messagesOnly)
        records.record(
            connectionID: provider.id.uuidString, modelID: model.id, transport: RelayTransport.anthropicMessages.rawValue,
            result: .searched, source: .tested, fragmentHash: RelayWebProbe.fragmentHash(try Self.template(.anthropicMessages))
        )
        #expect(fact(messagesOnly)?.statusId == .searched)
        #expect(fact(messagesOnly)?.isOn == true)

        // Store only the Chat fragment -> nothing saved for first-send Messages: the effective fragment is the Messages template; the template was never tested, so the existing searched record still applies; off by default.
        let chatOnly = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        try Self.saveTemplate(.openaiChatCompletions, for: provider, in: chatOnly)
        #expect(fact(chatOnly)?.savedFragment == false)
        #expect(fact(chatOnly)?.statusId == .searched, "record hash = Messages template hash")
        #expect(fact(chatOnly)?.isOn == false)
        let empty = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let fresh = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        #expect(RelayWebProbe.fact(provider: provider, model: model, preference: nil, fragments: empty, records: fresh)?.statusId == .untested)
    }

    @Test("RL2-WEBPROBE-CHAT-02-first_send: first send on Messages delivered with citations -> searched / observed under Messages; after a protocol-level fallback the Chat fragment is attached and the record is written under Chat")
    func chat02FirstSend() async throws {
        let messagesSSE = try Self.sseText("messages_web_search_tool_result_searched")
        let chatSSE = try Self.sseText("chat_url_citation_searched")

        do {
            let (provider, model) = Self.firstSendMessagesProvider()
            defer { Self.cleanUp(provider) }
            try Self.saveTemplate(.anthropicMessages, for: provider)
            let sent = try await Self.sendChat(provider: provider, modelID: model.id, replies: [(200, messagesSSE)])
            #expect(sent.message?.state == .delivered, "precondition: delivered \(sent.message?.errorDetail ?? "")")
            #expect(sent.bodies.count == 1 && sent.bodies.first?["tools"] != nil, "precondition: first send on Messages carries the fragment")
            let record = RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: RelayTransport.anthropicMessages.rawValue
            )
            #expect(record?.result == .searched && record?.source == .observed, "writes searched / observed under Messages: \(String(describing: record))")
            #expect(record?.fragmentHash == RelayWebProbe.fragmentHash(try Self.template(.anthropicMessages)))
        }

        do {
            let (provider, model) = Self.firstSendMessagesProvider()
            defer { Self.cleanUp(provider) }
            try Self.saveTemplate(.anthropicMessages, for: provider)
            try Self.saveTemplate(.openaiChatCompletions, for: provider)
            let sent = try await Self.sendChat(
                provider: provider, modelID: model.id,
                replies: [(404, #"{"error":{"message":"not found"}}"#), (200, chatSSE)]
            )
            #expect(sent.bodies.count == 2, "precondition: after Messages is rejected it falls back to Chat")
            #expect(sent.message?.state == .delivered, "precondition: delivered \(sent.message?.errorDetail ?? "")")
            #expect(sent.bodies.first?["tools"] != nil, "the first-send Messages request carries the first-send protocol's fragment")
            #expect(sent.bodies.last?["web_search_options"] != nil, "a protocol fallback attaches the fragment of the target protocol")
            let messages = RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: RelayTransport.anthropicMessages.rawValue
            )
            #expect(messages == nil, "the first-send protocol was not delivered, nothing written: \(String(describing: messages))")
            let chat = RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: RelayTransport.openaiChatCompletions.rawValue
            )
            #expect(chat?.result == .searched && chat?.source == .observed, "written under the protocol actually used: \(String(describing: chat))")
            #expect(chat?.fragmentHash == RelayWebProbe.fragmentHash(try Self.template(.openaiChatCompletions)))
        }
    }

    @Test("RL2-WEBPROBE-10 STALE: the fragment changed while the probe was sending -> neither a record nor an override is written")
    func probeFragmentChangedDuringSend() async throws {
        let model = TestFactories.makeModel(id: "relay-model", capabilities: [.text], isDefault: true)
        let provider = Self.provider(transport: .openaiChatCompletions, model: model)
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        try Self.saveTemplate(.openaiChatCompletions, for: provider, in: fragments)
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        let state = Self.makeState()
        state.providers = [provider]
        let searched = try Self.evidenceResponse("chat_url_citation_searched")
        let changed = #"{"web_search_options":{"search_context_size":"low"}}"#
        let result = await state.providerManager.runRelayWebProbe(
            providerID: provider.id, modelID: model.id, deadline: .seconds(5),
            send: { _ in
                _ = fragments.save(connectionID: provider.id, transport: .openaiChatCompletions, raw: changed)
                return searched
            },
            fragments: fragments, records: records
        )
        guard case let .probed(outcome) = try #require(result) else { Issue.record("expected to have probed: \(String(describing: result))"); return }
        #expect(outcome.result == .searched, "precondition: the probe itself judges searched")
        #expect(records.record(connectionID: provider.id.uuidString, modelID: model.id, transport: "openai_chat_completions") == nil, "no record written")
        let after = try #require(state.providerManager.provider(for: provider.id))
        #expect(after.models.first?.relayCapabilityOverrides?.web == nil, "no override written")
    }
}

// MARK: - Automatic trigger wiring and override clearing

/// Records the concurrency of automatic probes and whether the history was already written when each was sent.
private final class WebProbeAutoLog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    private var sent: [(model: String, historyWritten: Bool)] = []

    func enter(model: String, historyWritten: Bool) {
        lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
            sent.append((model, historyWritten))
        }
    }

    func leave() { lock.withLock { active -= 1 } }

    var models: [String] { lock.withLock { sent.map(\.model) } }
    var allHistoryWrittenFirst: Bool { lock.withLock { sent.allSatisfy(\.historyWritten) } }
    var peak: Int { lock.withLock { maxActive } }
}

/// A main-thread action that fires only once: inserts one save while the first automatic-probe send is in flight.
private final class WebProbeOnceHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@MainActor () -> Void)?

    func set(_ value: @escaping @MainActor () -> Void) { lock.withLock { action = value } }

    func take() -> (@MainActor () -> Void)? {
        lock.withLock {
            defer { action = nil }
            return action
        }
    }
}

extension RelayWebProbeContractTests {
    nonisolated private static func requestModel(_ request: URLRequest) -> String {
        let object = try? JSONSerialization.jsonObject(with: body(of: request)) as? [String: Any]
        return object?["model"] as? String ?? ""
    }

    /// Fake upstream: records concurrency and "history already written at send time", and replays the given responses.
    nonisolated private static func autoSend(
        _ log: WebProbeAutoLog, records: RelayWebProbeStore, reply: RelayCapabilityTest.Response
    ) -> RelayWebProbe.Send {
        { request in
            let model = requestModel(request)
            log.enter(model: model, historyWritten: records.autoHistory().contains { $0.modelID == model })
            defer { log.leave() }
            try await Task.sleep(for: .milliseconds(20))
            return reply
        }
    }

    /// Follows the page's save path: take the pre-save fragment, persist with `Board.commit`, then hand over to ProviderManager to trigger.
    private static func saveLikePage(
        _ draft: RelayWebSearchDraft, providerID: UUID, state: AppState, fragments: RelayWebFragmentStore
    ) throws -> RelayWebSearchDraft? {
        let manager = state.providerManager
        let provider = try #require(manager.provider(for: providerID))
        let before = manager.relayWebFragmentsBeforeSave(provider)
        guard let baseline = RelayWebSearchBoardModel.commit(draft, provider: provider, store: fragments, persist: {
            manager.updateProvider($0)
        }) else { return nil }
        manager.relayWebFragmentsSaved(providerID: providerID, before: before)
        return baseline
    }

    private static func chatTemplateDraft() -> RelayWebSearchDraft {
        var draft = RelayWebSearchDraft(texts: [:])
        draft.useTemplate(.openaiChatCompletions)
        return draft
    }

    @Test("RL2-WEBPROBE-11 WIRE-save: saving a fragment -> the selected models run the production probe serially in enable order, write history before sending, and write records; untested ones get zero requests")
    func wireSave() async throws {
        let ids = (1...7).map { "m\($0)" }
        let models = ids.map { TestFactories.makeModel(id: $0, capabilities: [.text], isDefault: $0 == "m1") }
        var provider = Self.provider(transport: .openaiChatCompletions, model: models[0])
        provider.models = models
        provider.catalogModels = models
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        let state = Self.makeState()
        state.providers = [provider]
        let log = WebProbeAutoLog()
        let searched = try Self.evidenceResponse("chat_url_citation_searched")
        state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(
            send: Self.autoSend(log, records: records, reply: searched), fragments: fragments, records: records
        )

        let draft = Self.chatTemplateDraft()
        #expect(try Self.saveLikePage(draft, providerID: provider.id, state: state, fragments: fragments) == draft)
        await state.providerManager.waitForRelayWebProbesForTesting()

        let probed = Array(ids.prefix(5))
        #expect(log.models == probed, "WIRE-save probes the first 5 in enable order")
        #expect(log.peak == 1, "WIRE-save is serial")
        #expect(log.allHistoryWrittenFirst, "WIRE-save writes history before sending")
        let hash = RelayWebProbe.fragmentHash(try Self.template(.openaiChatCompletions))
        for id in probed {
            let record = records.record(connectionID: provider.id.uuidString, modelID: id, transport: "openai_chat_completions")
            #expect(record?.result == .searched && record?.source == .tested && record?.fragmentHash == hash, "WIRE-save \(id) record")
        }
        for id in ids.suffix(2) {
            #expect(records.record(connectionID: provider.id.uuidString, modelID: id, transport: "openai_chat_completions") == nil,
                    "WIRE-save \(id) untested writes no record")
        }
        let history = records.autoHistory()
        #expect(history.map(\.modelID) == probed, "WIRE-save history")
        #expect(history.allSatisfy {
            $0.connectionID == provider.id.uuidString && $0.transport == "openai_chat_completions"
                && $0.fragmentHash == hash && $0.sentAt == Self.fixedNow
        }, "WIRE-save history fields")
        let after = try #require(state.providerManager.provider(for: provider.id))
        #expect(after.models.prefix(5).allSatisfy { $0.relayCapabilityOverrides?.web == true }, "WIRE-save searched mirrors web")

        // Save the same fragment again: ones already probed are deduplicated and the remaining two are filled in.
        #expect(try Self.saveLikePage(draft, providerID: provider.id, state: state, fragments: fragments) == draft)
        await state.providerManager.waitForRelayWebProbesForTesting()
        #expect(log.models == ids, "WIRE-save saving again probes only m6, m7")
    }

    @Test("RL2-WEBPROBE-11 WIRE-resave: save B while the probe after saving A is in progress -> the rest of A's models are not sent and write no history; B is selected as usual")
    func wireSaveThenResave() async throws {
        let ids = ["m1", "m2", "m3"]
        let models = ids.map { TestFactories.makeModel(id: $0, capabilities: [.text], isDefault: $0 == "m1") }
        var provider = Self.provider(transport: .openaiChatCompletions, model: models[0])
        provider.models = models
        provider.catalogModels = models
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        let state = Self.makeState()
        state.providers = [provider]
        let log = WebProbeAutoLog()
        let searched = try Self.evidenceResponse("chat_url_citation_searched")
        let inner = Self.autoSend(log, records: records, reply: searched)
        // Save B (different fragment content) while A's first probe is in flight.
        let draftB = RelayWebSearchDraft(texts: ["openai_chat_completions": #"{"web_search_options":{"search_context_size":"low"}}"#])
        let hook = WebProbeOnceHook()
        hook.set { [state, fragments] in
            _ = try? Self.saveLikePage(draftB, providerID: provider.id, state: state, fragments: fragments)
        }
        state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(
            send: { request in
                if let action = hook.take() { await action() }
                return try await inner(request)
            },
            fragments: fragments, records: records
        )

        #expect(try Self.saveLikePage(Self.chatTemplateDraft(), providerID: provider.id, state: state, fragments: fragments) != nil)
        await state.providerManager.waitForRelayWebProbesForTesting()
        await state.providerManager.waitForRelayWebProbesForTesting()

        let hashA = RelayWebProbe.fragmentHash(try Self.template(.openaiChatCompletions))
        let hashB = RelayWebProbe.fragmentHash(["web_search_options": ["search_context_size": "low"]])
        #expect(hashA != hashB)
        #expect(log.models == ["m1", "m1", "m2", "m3"], "A sends only m1; B probes m1, m2, m3")
        #expect(log.allHistoryWrittenFirst, "history written before sending")
        let history = records.autoHistory()
        // Saving B prunes history by the new hash, so A's m1 entry may be pruned; A's remaining m2 and m3 must not appear either way.
        #expect(!history.contains { $0.fragmentHash == hashA && $0.modelID != "m1" }, "the rest of A's models write no history")
        #expect(history.filter { $0.fragmentHash == hashB }.map(\.modelID) == ids, "B history")
    }

    @Test("RL2-WEBPROBE-11 WIRE-enable: probe once after the lazy verification really passes; 0 times if the lazy verification fails or did not run")
    func wireEnable() async throws {
        for scenario in ["passed", "failed", "notRun"] {
            let label = "RL2-WEBPROBE-WIRE-enable-\(scenario)"
            let stub = RelaySetupHTTPStub()
            if scenario == "failed" { stub.failGeneration(status: 404) }
            var model = TestFactories.makeModel(id: "gpt-4o", capabilities: [.text], isDefault: true)
            if scenario == "notRun" { model.relayTransport = .openaiChatCompletions }
            var provider = Self.provider(transport: .openaiChatCompletions, model: model)
            provider.relayRequested?.transport = .auto
            provider.baseURLText = stub.endpoint + "/v1"
            let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
            for transport in RelayWebFragments.transports {
                if let raw = RelayWebFragments.template(for: transport) {
                    #expect(fragments.save(connectionID: provider.id, transport: transport, raw: raw) == nil)
                }
            }
            let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
            let state = Self.makeState(session: RelaySetupHTTPStub.session())
            state.providers = [provider]
            let log = WebProbeAutoLog()
            state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(
                send: Self.autoSend(log, records: records, reply: Self.sseResponse(["data: [DONE]"])),
                fragments: fragments, records: records
            )

            await state.providerManager.probeRelayModelTransport(providerID: provider.id, modelID: model.id)
            await state.providerManager.waitForRelayWebProbesForTesting()

            let after = try #require(state.providerManager.provider(for: provider.id))
            let afterModel = try #require(after.models.first)
            switch scenario {
            case "passed":
                #expect(model.relayTransport == nil && afterModel.relayTransport != nil, "\(label) precondition: a passing lazy verification writes back the transport")
                let transport = RelayWebProbe.transport(provider: after, model: afterModel)
                #expect(fragments.chatFragments(for: after)?.object(for: transport) != nil, "\(label) precondition: the first-send transport has a fragment")
                #expect(log.models == ["gpt-4o"], "\(label) probes once")
                #expect(log.allHistoryWrittenFirst, "\(label) writes history before sending")
                #expect(records.autoHistory().count == 1, "\(label) 1 history entry")
                #expect(records.record(connectionID: provider.id.uuidString, modelID: "gpt-4o", transport: transport.rawValue) != nil,
                        "\(label) writes a record")
            case "failed":
                #expect(!stub.generationModels.isEmpty && afterModel.relayTransport == nil, "\(label) precondition: lazy verification was sent and failed")
                #expect(log.models.isEmpty && records.autoHistory().isEmpty, "\(label) 0 times")
            default:
                #expect(stub.generationModels.isEmpty, "\(label) precondition: lazy verification did not run")
                #expect(log.models.isEmpty && records.autoHistory().isEmpty, "\(label) 0 times")
            }
        }
    }

    @Test("RL2-WEBPROBE-10 OVERRIDE-clear: fragment hash changed / probe silent -> remove tested web; undetermined untouched; user entries untouched")
    func overrideClear() async throws {
        // 1. Saving changed some transport's fragment: models whose first-send transport is that one lose the tested web; user entries and unchanged fragments are kept.
        var testedTrue = RelayCapabilityOverrides(source: .tested)
        testedTrue.setValue(true, for: .web, source: .tested)
        var userFalse = RelayCapabilityOverrides()
        userFalse.setValue(false, for: .web, source: .user)
        var a = TestFactories.makeModel(id: "a", capabilities: [.text], isDefault: true)
        a.relayCapabilityOverrides = testedTrue
        var b = TestFactories.makeModel(id: "b", capabilities: [.text], isDefault: false)
        b.relayCapabilityOverrides = userFalse
        var provider = Self.provider(transport: .openaiChatCompletions, model: a)
        provider.models = [a, b]
        provider.catalogModels = [a, b]
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        try Self.saveTemplate(.openaiChatCompletions, for: provider, in: fragments)
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults(), clock: { Self.fixedNow })
        // Window full: saving sends no automatic probe, so only the override clearing is checked.
        records.appendAutoHistory(connectionID: provider.id.uuidString, (0..<10).map {
            RelayWebProbeTrigger.Candidate(modelID: "x\($0)", transport: "openai_chat_completions", fragmentHash: "h")
        })
        let state = Self.makeState()
        state.providers = [provider]
        let log = WebProbeAutoLog()
        state.providerManager.relayWebProbeAutoContext = RelayWebProbeAutoContext(
            send: Self.autoSend(log, records: records, reply: Self.sseResponse(["data: [DONE]"])),
            fragments: fragments, records: records
        )

        // Save the same fragment again: the hash is unchanged, so the tested web is kept.
        _ = try Self.saveLikePage(Self.chatTemplateDraft(), providerID: provider.id, state: state, fragments: fragments)
        var after = try #require(state.providerManager.provider(for: provider.id))
        #expect(after.models.first { $0.id == "a" }?.relayCapabilityOverrides?.web == true, "unchanged fragment is not cleared")

        let changed = RelayWebSearchDraft(texts: ["openai_chat_completions": #"{"web_search_options":{"search_context_size":"low"}}"#])
        _ = try Self.saveLikePage(changed, providerID: provider.id, state: state, fragments: fragments)
        await state.providerManager.waitForRelayWebProbesForTesting()
        after = try #require(state.providerManager.provider(for: provider.id))
        for list in [after.models, after.catalogModels] {
            #expect(list.first { $0.id == "a" }?.relayCapabilityOverrides?.web == nil, "fragment changed -> tested web removed")
            let bWeb = list.first { $0.id == "b" }?.relayCapabilityOverrides
            #expect(bWeb?.web == false && bWeb?.sources[.web] == .user, "user entry untouched")
        }
        #expect(log.models.isEmpty, "window full, zero requests")

        // 2. A retest lifts rejected and then yields silent: the record becomes silent and the tested web(false) is removed.
        var testedFalse = RelayCapabilityOverrides(source: .tested)
        testedFalse.setValue(false, for: .web, source: .tested)
        let fragment = try Self.template(.openaiChatCompletions)
        let silent = try Self.evidenceResponse("chat_text_only_silent")
        let lifted = try await Self.run(
            transport: .openaiChatCompletions, fragment: fragment, existingOverrides: testedFalse, existingRecord: .rejected
        ) { _ in silent }
        #expect(Self.storedRecord(lifted)?.result == .silent, "precondition: silent lifts rejected")
        #expect(Self.webOverride(lifted).value == nil, "silent -> tested web removed")

        // 3. undetermined (network error): no record written and overrides untouched - still false after rejected.
        struct Offline: Error {}
        let undetermined = try await Self.run(
            transport: .openaiChatCompletions, fragment: fragment, existingOverrides: testedFalse, existingRecord: .rejected
        ) { _ in throw Offline() }
        #expect(try Self.outcome(undetermined, "OVERRIDE-clear undetermined").result == .undetermined)
        #expect(Self.storedRecord(undetermined)?.result == .rejected, "undetermined does not change the record")
        #expect(Self.webOverride(undetermined).value == false && Self.webOverride(undetermined).source == .tested,
                "rejected then undetermined -> tested web stays false")

        // 4. User entries are untouched under silent.
        let user = try await Self.run(
            transport: .openaiChatCompletions, fragment: fragment, existingOverrides: userFalse
        ) { _ in silent }
        #expect(Self.webOverride(user).value == false && Self.webOverride(user).source == .user, "user entry untouched")
    }
}
