import CryptoKit
import Foundation

// MARK: - Relay 2.0 web-search probe
//
// Listed only when the form is relay and the model's effective protocol has a stored web fragment; no fragment = not listed, zero requests.
// The request is built by the same builder as "Test capabilities" (`RelayCapabilityTest.request`); the only user message is a fixed prompt,
// and the fragment is merged into the request body by the same merge function as chat; sent only once, with a total deadline `timeoutSeconds`.
// Verdict: status classification reuses the capability test's `judge`; for a 2xx the SSE is then fed to this protocol's production Strategy, and only the evidence it yields counts.
// The criteria follow `shared/test-fixtures/relay/web-probe.v1.json`.

enum RelayWebProbe {
    nonisolated enum Result: String, Equatable, Sendable {
        case searched, rejected, silent, undetermined
    }

    struct Outcome: Equatable, Sendable {
        let result: Result
        let reason: RelayCapabilityTest.Reason
        /// Present only when an HTTP response was received.
        let status: Int?
        /// Citation URLs produced by the parser, de-duplicated in order of arrival.
        let evidenceUrls: [String]
        let elapsedMs: Int
    }

    enum Run: Equatable, Sendable {
        /// Out of scope (non-RELAY / local engine / unsupported protocol) or this protocol has no fragment: no request was sent at all.
        case notListed
        case probed(Outcome)
    }

    /// Sends the probe request and reads the whole response; a throw = no HTTP response was received.
    typealias Send = @Sendable (_ request: URLRequest) async throws -> RelayCapabilityTest.Response

    // MARK: Fixed material (fixture `request`)

    static let prompt = "Search the web and give one source URL for today's top news."
    static let outputLimit = 256
    static let timeoutSeconds = 30
    static let deadline: Duration = .seconds(timeoutSeconds)

    /// Same scope as the capability test: Relay form, no `engineProfile`, and the model's first-send protocol is one of the four.
    static func isEligible(provider: Provider, model: AIModel) -> Bool {
        RelayCapabilityTest.isEligible(provider: provider, model: model)
    }

    /// The protocol used for probing = the capability test's protocol (the first-send protocol of a chat without attachments).
    static func transport(provider: Provider, model: AIModel) -> RelayTransport {
        RelayCapabilityTest.transport(provider: provider, model: model)
    }

    static func message(modelID: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .user,
            text: prompt,
            providerKind: .relay,
            providerName: "Relay",
            modelName: modelID,
            state: .delivered
        )
    }

    static func request(
        provider: Provider,
        model: AIModel,
        fragments: RelayWebFragmentSet,
        services: ProviderServiceRouter.Services,
        partitionID: String
    ) throws -> URLRequest {
        try RelayCapabilityTest.request(
            provider: provider, model: model, services: services, partitionID: partitionID,
            messages: [message(modelID: model.id)], maxOutputTokens: outputLimit, webFragments: fragments
        )
    }

    // MARK: Chat attachment and panel

    /// The probe record result for this model under the current fragment, looked up on the same protocol the probe wrote the record under (the first-send protocol).
    /// Out of scope, no fragment on that protocol, or a hash different from the current fragment (= untested) all return nil.
    static func currentResult(
        provider: Provider, model: AIModel, fragments set: RelayWebFragmentSet?, records: RelayWebProbeStore
    ) -> RelayWebProbeRecord.Result? {
        guard isEligible(provider: provider, model: model) else { return nil }
        let transport = transport(provider: provider, model: model)
        guard let fragment = set?.object(for: transport) else { return nil }
        return records.current(
            connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue,
            fragmentHash: fragmentHash(fragment)
        )?.result
    }

    /// Fragments carried by a chat send: the connection's effective fragments, minus the protocol whose record under the current fragment is rejected; returns nil if none remain.
    static func chatFragments(
        provider: Provider, model: AIModel,
        fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared
    ) -> RelayWebFragmentSet? {
        guard var set = fragments.chatFragments(for: provider) else { return nil }
        if currentResult(provider: provider, model: model, fragments: set, records: records) == .rejected {
            set.raw[transport(provider: provider, model: model).rawValue] = nil
        }
        return set.isEmpty ? nil : set
    }

    /// Facts for the web row of the model options panel: whether a fragment exists and its status are both read on the same protocol the probe wrote the record under (the first-send protocol), not the effective protocol.
    static func panelFact(
        provider: Provider, model: AIModel,
        fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared
    ) -> ModelOptionCapabilityShape.RelayWeb {
        let set = fragments.chatFragments(for: provider) ?? RelayWebFragmentSet()
        return RelayWebFragments.panelFact(
            engineProfile: provider.relayRequested?.engineProfile,
            effectiveTransport: transport(provider: provider, model: model),
            fragments: set,
            probe: currentResult(provider: provider, model: model, fragments: set, records: records)
        )
    }

    // MARK: Verdict

    /// Judges the whole response as one of four outcomes.
    nonisolated static func evaluate(
        transport: RelayTransport,
        fragment: [String: Any]?,
        response: RelayCapabilityTest.Response,
        elapsedMs: Int
    ) -> Outcome {
        let judgement = RelayCapabilityTest.judge(
            status: response.status, contentType: response.contentType, body: response.body
        )
        switch judgement.verdict {
        // judge never yields notObserved (that is the evidence step for the capability test's image / tool items); it is listed only to be exhaustive.
        case .rejected, .undetermined, .notObserved, .searched, .silent:
            return Outcome(
                result: judgement.verdict == .rejected ? .rejected : .undetermined,
                reason: judgement.reason, status: response.status, evidenceUrls: [], elapsedMs: elapsedMs
            )
        case .accepted:
            // An error frame after output is not a rejection: nothing is written.
            if RelayCapabilityTest.eventStreamSignals(response.body).sawError {
                return Outcome(
                    result: .undetermined, reason: .server, status: response.status, evidenceUrls: [], elapsedMs: elapsedMs
                )
            }
            let found = evidence(transport: transport, fragment: fragment, body: response.body)
            return Outcome(
                result: found.isEmpty ? .silent : .searched,
                reason: .ok,
                status: response.status,
                evidenceUrls: deduplicated(found.urls),
                elapsedMs: elapsedMs
            )
        }
    }

    /// Feeds the SSE line by line into this protocol's production Strategy (the same citation stream-shape as chat) and collects the web-search evidence it yields.
    nonisolated static func evidence(transport: RelayTransport, fragment: [String: Any]?, body: Data) -> WebSearchEvidence {
        parseStream(transport: transport, fragment: fragment, body: body).context.webSearchEvidence
    }

    /// Feeds the SSE line by line into this protocol's production Strategy, and returns the events it produced (including tool-call proposals flushed when the stream ends) and the final context.
    /// The web probe reads the web-search evidence in the context; the capability test reads the visible text and tool calls in the events.
    nonisolated static func parseStream(
        transport: RelayTransport,
        fragment: [String: Any]?,
        body: Data
    ) -> (events: [StreamEvent], context: StreamContext) {
        let strategy: any TransportStrategy
        let flush: (inout StreamContext) -> [StreamEvent]
        switch transport {
        case .openaiResponses:
            strategy = OpenAIResponsesStrategy()
            flush = { OpenAIResponsesStrategy.flushToolCalls(ctx: &$0) }
        case .anthropicMessages:
            strategy = AnthropicMessagesStrategy()
            flush = { AnthropicMessagesStrategy.flushToolCalls(ctx: &$0) }
        case .geminiGenerateContent:
            strategy = GeminiGenerateStrategy()
            flush = { GeminiGenerateStrategy.flushToolCalls(ctx: &$0) }
        case .openaiChatCompletions, .auto, .llamacppNative:
            strategy = OpenAIChatStrategy()
            flush = { OpenAIChatStrategy.flushToolCalls(ctx: &$0) }
        }
        let shape = MetadataClient.shared.syncWebSearchStreamShape(
            profileName: RelayWebFragments.citationProfile(transport: transport, fragment: fragment)
        )
        var ctx = StreamContext()
        var events: [StreamEvent] = []
        for rawLine in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            events.append(contentsOf: strategy.parseStreamLine(payload, ctx: &ctx, shape: shape))
        }
        // Consistent with how the chat Service finishes: catch an upstream that has no end signal, and hand over the tool-call proposals accumulated so far.
        events.append(contentsOf: flush(&ctx))
        return (events, ctx)
    }

    nonisolated private static func deduplicated(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    // MARK: Send and total deadline

    private final class DeadlineFlag: @unchecked Sendable {
        var fired = false
    }

    /// Sends once and judges. When the total deadline hits, the request is cancelled and judged timeout; `CancellationError` is thrown only if the outer task is cancelled.
    static func execute(
        transport: RelayTransport,
        fragment: [String: Any]?,
        request: URLRequest,
        deadline: Duration,
        send: @escaping Send
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        let flag = DeadlineFlag()
        let work = Task { try await send(request) }
        let watchdog = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            flag.fired = true
            work.cancel()
        }
        let outcome: Swift.Result<RelayCapabilityTest.Response, Error> = await withTaskCancellationHandler {
            do { return .success(try await work.value) } catch { return .failure(error) }
        } onCancel: {
            work.cancel()
        }
        watchdog.cancel()
        let elapsed = clock.now - start
        let elapsedMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        if Task.isCancelled, !flag.fired { throw CancellationError() }
        switch outcome {
        case let .success(response):
            return evaluate(transport: transport, fragment: fragment, response: response, elapsedMs: elapsedMs)
        case .failure:
            return Outcome(
                result: .undetermined, reason: flag.fired ? .timeout : .network, status: nil, evidenceUrls: [],
                elapsedMs: elapsedMs
            )
        }
    }

    // MARK: Fragment hash

    /// Canonical JSON: object keys at every level sorted by Unicode code point, arrays order-preserving, no whitespace, strings escaped only where JSON requires.
    nonisolated static func canonicalJSON(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            return "{" + keys.map { quoted($0) + ":" + canonicalJSON(object[$0]!) }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + array.map(canonicalJSON).joined(separator: ",") + "]"
        }
        if let string = value as? String { return quoted(string) }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let data = (try? JSONSerialization.data(withJSONObject: [number])) ?? Data("[]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return "null"
    }

    nonisolated private static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// SHA-256 of the UTF-8 bytes of the canonical JSON, lowercase hex.
    nonisolated static func fragmentHash(_ fragment: [String: Any]) -> String {
        SHA256.hash(data: Data(canonicalJSON(fragment).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Override write-back

    /// Mirror: searched -> web true, rejected -> web false (both recorded as tested); silent removes the tested web;
    /// undetermined writes no record and leaves the override as is; `user` items are never touched. The caller passes the current merged record result.
    static func merged(_ existing: RelayCapabilityOverrides?, with result: Result) -> RelayCapabilityOverrides? {
        let value: Bool
        switch result {
        case .searched: value = true
        case .rejected: value = false
        case .silent: return clearingTestedWeb(existing)
        case .undetermined: return existing
        }
        guard !RelayCapabilityTest.isUserSet(existing, .web) else { return existing }
        var overrides = existing ?? RelayCapabilityOverrides()
        overrides.setValue(value, for: .web, source: .tested)
        return overrides.isEmpty ? nil : overrides
    }

    /// Remove only the web item whose source is tested; user items and other keys are untouched.
    static func clearingTestedWeb(_ existing: RelayCapabilityOverrides?) -> RelayCapabilityOverrides? {
        guard var overrides = existing, overrides.sources[.web] == .tested else { return existing }
        overrides.setValue(nil, for: .web, source: .tested)
        return overrides.isEmpty ? nil : overrides
    }

    /// On a protocol whose fragment hash changed, models whose first-send protocol is that one (enabled and catalog written together) have the tested web removed.
    static func clearTestedWeb(transports: Set<RelayTransport>, in provider: inout Provider) {
        guard !transports.isEmpty else { return }
        let snapshot = provider
        func write(_ models: inout [AIModel]) {
            for index in models.indices
            where isEligible(provider: snapshot, model: models[index])
                && transports.contains(transport(provider: snapshot, model: models[index])) {
                models[index].relayCapabilityOverrides = clearingTestedWeb(models[index].relayCapabilityOverrides)
            }
        }
        write(&provider.models)
        write(&provider.catalogModels)
    }

    /// The model with the same id is written in both the enabled list and the catalog, each merged with its own current override.
    static func apply(_ result: Result, modelID: String, to provider: inout Provider) {
        func write(_ models: inout [AIModel]) {
            for index in models.indices where models[index].id == modelID {
                models[index].relayCapabilityOverrides = merged(models[index].relayCapabilityOverrides, with: result)
            }
        }
        write(&provider.models)
        write(&provider.catalogModels)
    }
}

// MARK: - Local probe records

/// One web probe record (fixture `record`): key = connection x model x protocol, stored on this device only.
nonisolated struct RelayWebProbeRecord: Codable, Equatable, Sendable {
    enum Result: String, Codable, Sendable { case searched, rejected, silent }
    enum Source: String, Codable, Sendable { case tested, observed }

    let result: Result
    let source: Source
    let at: Date
    let fragmentHash: String

    /// Merge (fixture `mergeCases`): different hash = the new record replaces the old one; with the same hash, rejected / searched replaces everything,
    /// and silent replaces silent / rejected but does not erase searched (failing to find a search cannot negate one that was seen).
    static func merge(existing: Self?, incoming: Self) -> Self {
        guard let existing, existing.fragmentHash == incoming.fragmentHash else { return incoming }
        switch incoming.result {
        case .rejected, .searched: return incoming
        case .silent: return existing.result == .searched ? existing : incoming
        }
    }
}

/// Local key-value store `relay_web_probe_records.v1` (same layer as the negative cache): excluded from cloud sync and backups, and the whole entry is removed when the connection is deleted.
nonisolated final class RelayWebProbeStore: @unchecked Sendable {
    static let storageKey = "relay_web_probe_records.v1"
    static let shared = RelayWebProbeStore()

    private struct Entry: Codable, Equatable {
        let connectionID: String
        let modelID: String
        let transport: String
        let result: RelayWebProbeRecord.Result
        let source: RelayWebProbeRecord.Source
        let at: TimeInterval
        let fragmentHash: String

        func matches(_ connectionID: String, _ modelID: String, _ transport: String) -> Bool {
            self.connectionID == connectionID && self.modelID == modelID && self.transport == transport
        }

        var record: RelayWebProbeRecord {
            RelayWebProbeRecord(
                result: result, source: source, at: Date(timeIntervalSince1970: at), fragmentHash: fragmentHash
            )
        }
    }

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    /// Writes one record by the merge rules (time taken from the injected clock) and returns the merged record.
    @discardableResult
    func record(
        connectionID: String, modelID: String, transport: String,
        result: RelayWebProbeRecord.Result, source: RelayWebProbeRecord.Source, fragmentHash: String
    ) -> RelayWebProbeRecord {
        let incoming = RelayWebProbeRecord(result: result, source: source, at: clock(), fragmentHash: fragmentHash)
        var merged = incoming
        mutate { entries in
            let existing = entries.first { $0.matches(connectionID, modelID, transport) }?.record
            merged = RelayWebProbeRecord.merge(existing: existing, incoming: incoming)
            entries.removeAll { $0.matches(connectionID, modelID, transport) }
            entries.append(Entry(
                connectionID: connectionID, modelID: modelID, transport: transport,
                result: merged.result, source: merged.source, at: merged.at.timeIntervalSince1970,
                fragmentHash: merged.fragmentHash
            ))
        }
        return merged
    }

    /// Read as is (the hash is not checked).
    func record(connectionID: String, modelID: String, transport: String) -> RelayWebProbeRecord? {
        load().first { $0.matches(connectionID, modelID, transport) }?.record
    }

    /// The record under the current fragment: a different hash = untested, returns nil.
    func current(connectionID: String, modelID: String, transport: String, fragmentHash: String) -> RelayWebProbeRecord? {
        guard let record = record(connectionID: connectionID, modelID: modelID, transport: transport),
              record.fragmentHash == fragmentHash else { return nil }
        return record
    }

    /// Delete the connection: clears the whole connection (probe records and auto history together).
    func clearConnection(_ connectionID: String) {
        mutate { entries in entries.removeAll { $0.connectionID == connectionID } }
        mutateHistory { entries in entries.removeAll { $0.connectionID == connectionID } }
    }

    // MARK: Auto history

    /// Auto-probe history `relay_web_probe_auto_history.v1`: same layer as the records, stored on this device only, written only by automatic probes (before sending).
    static let historyKey = "relay_web_probe_auto_history.v1"

    /// Injected clock: both the auto-selection `now` and the history's sentAt use it.
    var now: Date { clock() }

    func autoHistory() -> [RelayWebProbeTrigger.HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return decodeHistory()
    }

    /// Writes a batch of automatic probes (sentAt = injected clock).
    func appendAutoHistory(connectionID: String, _ candidates: [RelayWebProbeTrigger.Candidate]) {
        guard !candidates.isEmpty else { return }
        let sentAt = clock()
        mutateHistory { entries in
            entries.append(contentsOf: candidates.map {
                RelayWebProbeTrigger.HistoryEntry(
                    connectionID: connectionID, modelID: $0.modelID, transport: $0.transport,
                    fragmentHash: $0.fragmentHash, sentAt: sentAt
                )
            })
        }
    }

    /// On save, prune entries of this connection that are out of the window and do not belong to the current fragment.
    func pruneAutoHistory(connectionID: String, currentHashes: [String: String]) {
        let now = clock()
        mutateHistory { entries in
            entries = RelayWebProbeTrigger.pruned(entries, connectionID: connectionID, currentHashes: currentHashes, now: now)
        }
    }

    private func mutateHistory(_ body: (inout [RelayWebProbeTrigger.HistoryEntry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = decodeHistory()
        body(&entries)
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.historyKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    private func decodeHistory() -> [RelayWebProbeTrigger.HistoryEntry] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? JSONDecoder().decode([RelayWebProbeTrigger.HistoryEntry].self, from: data)) ?? []
    }

    private func load() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return decode()
    }

    private func mutate(_ body: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = decode()
        body(&entries)
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Corrupt data is treated as empty as a whole: at worst losing it equals never having tested.
    private func decode() -> [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
