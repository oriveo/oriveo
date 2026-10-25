import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-EARLY: driven by `earlyStopCases` in `shared/test-fixtures/relay/web-probe.v1.json`.
/// Goes through the production probe send point (`ProviderManager.runRelayWebProbe`, no injected send: it uses the
/// production session byte stream). The fake upstream delivers one event at a time; `stall` = it never sends again
/// and never ends. Asserts the verdict, whether the connection was cancelled before the stream ended, and the
/// latest event after which the verdict must be reached.
@Suite("RL2-WEBPROBE-EARLY · web probe decides as soon as it sees evidence", .serialized, .sharedProcessState)
@MainActor
struct RelayWebProbeEarlyStopTests {
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
    nonisolated private static let cases: [[String: Any]] =
        (fixture["earlyStopCases"] as? [String: Any])?["cases"] as? [[String: Any]] ?? []
    nonisolated private static let caseIds = cases.compactMap { $0["caseId"] as? String }

    private static var retainedStates: [AppState] = []

    private static func isolatedDefaults() -> UserDefaults {
        let name = "relay-web-early-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func loadMetadata() async throws {
        // Same patch as RL2-WEBPROBE-09: the shared metadata fixture has no Chat / Messages web profile.
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
    }

    @Test("RL2-WEBPROBE-EARLY", arguments: caseIds)
    func earlyStop(caseId: String) async throws {
        let label = "RL2-WEBPROBE-EARLY-\(caseId)"
        #expect(Self.caseIds.count == 6, "\(label) fixture count")
        let testCase = try #require(Self.cases.first { $0["caseId"] as? String == caseId })
        let expect = try #require(testCase["expect"] as? [String: Any])
        let transport = try #require(RelayTransport(rawValue: testCase["transport"] as? String ?? ""))
        let events = try #require(testCase["events"] as? [String])
        let stalls = testCase["then"] as? String == "stall"

        var model = TestFactories.makeModel(id: "relay-early-model", capabilities: [.text], isDefault: true)
        model.relayTransport = transport
        model.relayTransportSource = .user
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [model],
            apiKey: "sk-test", apiKeyPreview: "...test", baseURLText: "https://relay-early.example.com",
            relayRequested: RelayRequestedConfig(transport: transport, authMode: .auto, securityMode: .remoteHTTPS)
        )
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let records = RelayWebProbeStore(defaults: Self.isolatedDefaults())
        #expect(fragments.save(
            connectionID: provider.id, transport: transport, raw: try #require(RelayWebFragments.template(for: transport))
        ) == nil, "\(label) saved fragment")

        try await Self.loadMetadata()
        ProviderAPIKeyStore.useInMemoryBackendForTesting(true)
        defer { ProviderAPIKeyStore.useInMemoryBackendForTesting(false) }
        EarlyStopProtocol.reset(events: events, stalls: stalls)
        let state = AppState(
            seedDemoData: false, sessionUID: "relay-web-early-\(UUID().uuidString)",
            providerSession: EarlyStopProtocol.session()
        )
        Self.retainedStates.append(state)
        state.providers = [provider]

        // Only "no evidence and the stream never ends" waits for the overall deadline: give it a short deadline; every other case gets a long one and relies on the early verdict returning before it.
        let timesOut = expect["reason"] as? String == "timeout"
        let deadline: Duration = timesOut ? .milliseconds(1_500) : .seconds(20)
        let clock = ContinuousClock()
        let started = clock.now
        let run = await state.providerManager.runRelayWebProbe(
            providerID: provider.id, modelID: model.id, deadline: deadline, fragments: fragments, records: records
        )
        let elapsed = clock.now - started
        guard case let .probed(outcome)? = run else { Issue.record("\(label) should have been probed: \(String(describing: run))"); return }
        #expect(outcome.result.rawValue == expect["result"] as? String, "\(label) result: \(outcome)")
        #expect(outcome.reason.rawValue == expect["reason"] as? String, "\(label) reason: \(outcome)")
        for url in expect["urlsInclude"] as? [String] ?? [] {
            #expect(outcome.evidenceUrls.contains(url), "\(label) urls: \(outcome.evidenceUrls)")
        }

        // Cancellation reaches the connection asynchronously: give it a moment to land.
        let wantsCancel = expect["cancelled"] as? Bool == true
        let settle = clock.now + .seconds(2)
        while wantsCancel, !EarlyStopProtocol.cancelled, clock.now < settle {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(EarlyStopProtocol.cancelled == wantsCancel, "\(label) cancelled")
        if let atMost = expect["decidedAfterEventAtMost"] as? Int {
            #expect(EarlyStopProtocol.deliveredWhenStopped <= atMost, "\(label) events delivered at verdict time: \(EarlyStopProtocol.deliveredWhenStopped)")
            #expect(elapsed < deadline / 4, "\(label) must not wait for the stream to end: took \(elapsed)")
        }
    }
}

/// A fake upstream that delivers one event at a time, 40ms apart; `stalls` = after the last event it neither ends nor
/// sends again. Records whether the connection was cancelled before the stream ended and how many events had been
/// delivered at the moment of cancellation.
private final class EarlyStopProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _events: [String] = []
    nonisolated(unsafe) private static var _stalls = false
    nonisolated(unsafe) private static var _delivered = 0
    nonisolated(unsafe) private static var _finished = false
    nonisolated(unsafe) private static var _cancelled = false
    nonisolated(unsafe) private static var _deliveredWhenStopped = 0
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "relay-web-early-stub")

    static func reset(events: [String], stalls: Bool) {
        lock.withLock {
            _events = events
            _stalls = stalls
            _delivered = 0
            _finished = false
            _cancelled = false
            _deliveredWhenStopped = 0
        }
    }

    static var cancelled: Bool { lock.withLock { _cancelled } }
    static var deliveredWhenStopped: Int { lock.withLock { _deliveredWhenStopped } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EarlyStopProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://relay.invalid")!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let (events, stalls) = Self.lock.withLock { (Self._events, Self._stalls) }
        deliver(events, index: 0, stalls: stalls)
    }

    private func deliver(_ events: [String], index: Int, stalls: Bool) {
        Self.queue.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            guard let self else { return }
            let stopped = Self.lock.withLock { self.stopped }
            guard !stopped else { return }
            if index < events.count {
                self.client?.urlProtocol(self, didLoad: Data("data: \(events[index])\n\n".utf8))
                Self.lock.withLock { Self._delivered = index + 1 }
                self.deliver(events, index: index + 1, stalls: stalls)
            } else if !stalls {
                Self.lock.withLock { Self._finished = true }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            stopped = true
            if !Self._finished, !Self._cancelled {
                Self._cancelled = true
                Self._deliveredWhenStopped = Self._delivered
            }
        }
    }
}
