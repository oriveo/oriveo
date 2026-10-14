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

    // MARK: Effective fragments, chat attachment and panel

    /// Effective fragment set: the fragments saved on the connection; when the first-send protocol has none saved, that protocol's built-in template is added. Returns nil when out of scope.
    /// `saved` = the fragment on the first-send protocol is a saved one (including the legacy-field mapping), not the template.
    static func effectiveFragments(
        provider: Provider, model: AIModel, fragments: RelayWebFragmentStore = .shared
    ) -> (set: RelayWebFragmentSet, saved: Bool)? {
        guard isEligible(provider: provider, model: model) else { return nil }
        let transport = transport(provider: provider, model: model)
        let stored = fragments.chatFragments(for: provider)
        if let stored, stored.object(for: transport) != nil { return (stored, true) }
        guard let raw = RelayWebFragments.template(for: transport) else { return nil }
        var set = stored ?? RelayWebFragmentSet()
        set.raw[transport.rawValue] = raw
        return (set, false)
    }

    /// The effective fragment object on a protocol: the one in the set if present, otherwise that protocol's template.
    static func effectiveFragment(_ set: RelayWebFragmentSet?, transport: RelayTransport) -> [String: Any]? {
        if let object = set?.object(for: transport) { return object }
        guard let raw = RelayWebFragments.template(for: transport), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The probe record result for this model under the current (effective fragment hash), looked up on the first-send protocol. `set` = the fragments saved on the connection; when the first-send protocol has none saved, the template is used.
    /// Out of scope, or a hash different from the effective fragment (= untested), returns nil.
    static func currentResult(
        provider: Provider, model: AIModel, fragments set: RelayWebFragmentSet?, records: RelayWebProbeStore
    ) -> RelayWebProbeRecord.Result? {
        guard isEligible(provider: provider, model: model) else { return nil }
        let transport = transport(provider: provider, model: model)
        guard let fragment = effectiveFragment(set, transport: transport) else { return nil }
        return records.current(
            connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue,
            fragmentHash: fragmentHash(fragment)
        )?.result
    }

    /// The web override the user set by hand on the Advanced page (source user); a mirror of a tested result does not count.
    static func userOverride(_ model: AIModel) -> Bool? {
        RelayCapabilityTest.isUserSet(model.relayCapabilityOverrides, .web) ? model.relayCapabilityOverrides?.web : nil
    }

    /// Facts for the web row (fixture web-probe.v1.json presentationCases); `preference` = the resolved chat web switch
    /// (nil = never set, so the default applies: a saved fragment on the first-send protocol means on). Returns nil when out of scope.
    static func fact(
        provider: Provider, model: AIModel, preference: Bool?,
        fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared
    ) -> RelayWebFact? {
        guard let effective = effectiveFragments(provider: provider, model: model, fragments: fragments) else { return nil }
        return RelayWebFact(
            savedFragment: effective.saved,
            probe: currentResult(provider: provider, model: model, fragments: effective.set, records: records),
            userOverride: userOverride(model),
            preference: preference
        )
    }

    /// The protocols that get one fragment each in the fragment set (each protocol's builder reads its own).
    static let fragmentTransports: [RelayTransport] = [
        .anthropicMessages, .openaiChatCompletions, .openaiResponses, .geminiGenerateContent,
    ]

    /// Fragments carried by a chat send, decided per attempt by that attempt's protocol: the switch is on, the user override is not off, and (the record
    /// for that protocol is not rejected under the current fragment, or the user override is on) -> carry that protocol's effective fragment (the saved one, otherwise that protocol's template).
    /// The set holds one fragment per protocol, so after a protocol fallback within the same send the target protocol's builder reads its own. Returns nil if none is carried.
    static func chatFragments(
        provider: Provider, model: AIModel, webOn: Bool,
        fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared
    ) -> RelayWebFragmentSet? {
        let override = userOverride(model)
        guard webOn, override != false, isEligible(provider: provider, model: model) else { return nil }
        let stored = fragments.chatFragments(for: provider)
        var set = RelayWebFragmentSet()
        for transport in fragmentTransports {
            let key = transport.rawValue
            let raw = stored?.object(for: transport) != nil ? stored?.raw[key] : RelayWebFragments.template(for: transport)
            guard let raw, let object = RelayWebFragmentSet(raw: [key: raw]).object(for: transport) else { continue }
            if override != true, records.current(
                connectionID: provider.id.uuidString, modelID: model.id, transport: key, fragmentHash: fragmentHash(object)
            )?.result == .rejected {
                continue
            }
            set.raw[key] = raw
        }
        return set.isEmpty ? nil : set
    }

    /// Whether the web switch is in scope (the model options panel has a relay web row): neither a local engine nor an undecided protocol is.
    static func inScope(provider: Provider, model: AIModel, fragments: RelayWebFragmentStore = .shared) -> Bool {
        provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && effectiveFragments(provider: provider, model: model, fragments: fragments) != nil
    }

    /// Facts for the web row of the model options panel: a local engine is listed separately; an undecided protocol (out of scope) = undecided.
    static func panelFact(
        provider: Provider, model: AIModel, preference: Bool?,
        fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared
    ) -> ModelOptionCapabilityShape.RelayWeb {
        if provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .localEngine
        }
        guard let fact = fact(provider: provider, model: model, preference: preference, fragments: fragments, records: records)
        else { return .undecided }
        return .relay(fact)
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
        // A server-side error frame (overload / internal error, equivalent to a 5xx) is not a rejection: nothing is written (fixture error_frame_before_evidence_is_undetermined).
        if judgement.verdict == .rejected, (200..<300).contains(response.status),
           response.contentType.lowercased().contains("text/event-stream"), hasServerErrorFrame(response.body) {
            return Outcome(
                result: .undetermined, reason: .server, status: response.status, evidenceUrls: [], elapsedMs: elapsedMs
            )
        }
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

    /// Server-side error types (Anthropic `overloaded_error` / `api_error`, OpenAI `server_error`): treated like a 5xx status.
    nonisolated static let serverErrorTypes: Set<String> = ["overloaded_error", "api_error", "server_error"]

    nonisolated private static func hasServerErrorFrame(_ body: Data) -> Bool {
        String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:"),
                  let event = (try? JSONSerialization.jsonObject(
                      with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                  )) as? [String: Any],
                  let error = event["error"] as? [String: Any] else { return false }
            return [error["type"], error["code"]].contains { ($0 as? String).map(serverErrorTypes.contains) ?? false }
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
        var feed = StreamFeed(transport: transport, fragment: fragment)
        for rawLine in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            _ = feed.feed(rawLine)
        }
        feed.finish()
        return (feed.events, feed.context)
    }

    /// Incremental parser that feeds this protocol's production Strategy line by line (the same citation stream-shape as chat): whole-body parsing and the probe's judge-while-reading share one copy.
    nonisolated struct StreamFeed {
        private let strategy: any TransportStrategy
        private let flush: (inout StreamContext) -> [StreamEvent]
        private let shape: MetadataClient.StreamShape?
        private(set) var context = StreamContext()
        private(set) var events: [StreamEvent] = []
        /// An error frame has been seen: later evidence is not used to conclude early (left to the whole-body judgement).
        private(set) var sawError = false

        init(transport: RelayTransport, fragment: [String: Any]?) {
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
            shape = MetadataClient.shared.syncWebSearchStreamShape(
                profileName: RelayWebFragments.citationProfile(transport: transport, fragment: fragment)
            )
        }

        /// Evidence has arrived, and before any error frame (seeing evidence is judged searched).
        var hasEvidence: Bool { !sawError && !context.webSearchEvidence.isEmpty }

        /// Feeds one line (without the newline); returns whether conclusive evidence exists after feeding it.
        mutating func feed<Line: StringProtocol>(_ rawLine: Line) -> Bool {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { return hasEvidence }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { return hasEvidence }
            if RelayCapabilityTest.eventStreamSignals(Data(line.utf8)).sawError { sawError = true }
            events.append(contentsOf: strategy.parseStreamLine(payload, ctx: &context, shape: shape))
            return hasEvidence
        }

        /// Consistent with how the chat Service finishes: catch an upstream that has no end signal, and hand over the tool-call proposals accumulated so far.
        mutating func finish() {
            events.append(contentsOf: flush(&context))
        }
    }

    /// Production send for the web probe: on a 2xx event stream, feeds it line by line into this protocol's production Strategy; as soon as web-search evidence appears (and before any error frame),
    /// the request is cancelled and returned with the bytes read so far, without waiting for the stream to end. Everything else (non-2xx, not an event stream, no evidence ever) is read to the end of the stream as before.
    /// The capability test's text / vision / tool items do not go through here and still read the whole body (`RelayCapabilityTest.perform`).
    nonisolated static func perform(
        _ request: URLRequest, session: URLSession, transport: RelayTransport, fragment: [String: Any]?
    ) async throws -> RelayCapabilityTest.Response {
        let (bytes, response) = try await session.relayBytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "No HTTP response")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        var feed = (200..<300).contains(http.statusCode) && contentType.lowercased().contains("text/event-stream")
            ? StreamFeed(transport: transport, fragment: fragment) : nil
        var data = Data()
        var line = Data()
        for try await byte in bytes {
            data.append(byte)
            guard feed != nil else { continue }
            guard byte == UInt8(ascii: "\n") else {
                if byte != UInt8(ascii: "\r") { line.append(byte) }
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if feed?.feed(text) == true {
                bytes.task.cancel()
                break
            }
        }
        return RelayCapabilityTest.Response(status: http.statusCode, contentType: contentType, body: data)
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


// MARK: - Web row facts

/// One set of facts about relay web search and the presentations derived from it (fixture web-probe.v1.json presentationCases).
/// Priority: user override off > user override on > current record rejected > the rest.
nonisolated struct RelayWebFact: Equatable, Sendable {
    /// Status id -> per-platform copy (fixture statusId).
    enum StatusID: String, Equatable, Sendable {
        case searched = "web_probe_searched"
        case silent = "web_probe_silent"
        case rejected = "web_probe_rejected"
        case unverified = "web_probe_unverified"
        case untested = "web_probe_untested"
        case userOff = "web_user_off"
        case userOn = "web_user_on"
    }

    enum Row: String, Equatable, Sendable {
        case toggle, toggleDisabled
    }

    enum Truth: String, Equatable, Sendable {
        case supported, unsupported, unknown
    }

    /// The first-send protocol has a saved fragment (otherwise the effective fragment is that protocol's template).
    var savedFragment: Bool
    /// The probe record result under the current (effective fragment hash); nil = untested or the hash is stale.
    var probe: RelayWebProbeRecord.Result?
    /// The user override of web on the Advanced page (source user).
    var userOverride: Bool?
    /// The resolved chat web switch; nil = never set.
    var preference: Bool?

    /// Blocked: only when the user overrides off on the Advanced page. A rejected current record no longer greys the switch out or shows it as off (the switch follows the user only).
    var isBlocked: Bool { userOverride == false }

    var row: Row { isBlocked ? .toggleDisabled : .toggle }

    /// Default when never set: a saved fragment means on, otherwise off.
    var isOn: Bool { !isBlocked && (preference ?? savedFragment) }

    /// Whether the first-send protocol carries a fragment this time: the switch is on and the current record is not rejected (the record is ignored when the user override is on).
    var sendsFragment: Bool { isOn && (probe != .rejected || userOverride == true) }

    /// On but not carrying a fragment -> a notice under the reply saying this reply did not use web search.
    var replyNotice: RelayWebReplyNotice? { isOn && !sendsFragment ? .webNotUsed : nil }

    /// Status by the probe record (the Advanced page row uses it, ignoring the override).
    var probeStatus: StatusID {
        switch probe {
        case .searched?: .searched
        case .silent?: .silent
        case .rejected?: .rejected
        case nil: savedFragment ? .unverified : .untested
        }
    }

    var statusId: StatusID {
        switch userOverride {
        case false?: .userOff
        case true?: .userOn
        case nil: probeStatus
        }
    }

    /// A retest link is given only when blocked by a rejected current record: a rejected saved fragment -> the web search settings page, a rejected template -> the model's Advanced page.
    var retestLink: ModelOptionCapabilityAction? {
        guard userOverride == nil, probe == .rejected else { return nil }
        return savedFragment ? .openConnectionWebSearch : .openTestCapabilities
    }

    /// Badge / globe: user override > current record (searched = supported, rejected = unsupported) > unknown.
    var truth: Truth {
        if let userOverride { return userOverride ? .supported : .unsupported }
        switch probe {
        case .searched?: return .supported
        case .rejected?: return .unsupported
        case .silent?, nil: return .unknown
        }
    }

    /// Source badge of the Advanced page web row: user override > current record searched / rejected (tested) > none.
    var advancedSource: RelayCapabilityOverrides.Source? {
        if userOverride != nil { return .user }
        return probe == .searched || probe == .rejected ? .tested : nil
    }
}

/// Relay web reply notice (replyNotice in fixture web-probe.v1.json presentationCases / chatCases).
nonisolated enum RelayWebReplyNotice: String, Equatable, Sendable {
    case webNotUsed = "web_not_used"
}

// MARK: - Chat web switch

/// Relay web switch: reuses the `CapabilityWebPreference` storage and scope ladder; a relay has no timing tier, so anything other than off is on.
/// When never set, the default layer supplies the value: a saved fragment on the first-send protocol means on (filled in only at resolve time, no migration written).
enum RelayWebSwitch {
    /// Fixed addressing segment of the relay web switch: it does not change with the metadata revision or the first-send protocol (it can be stored and read without a metadata identity;
    /// after the first-send protocol switches it is still the same record, so the web-on state is kept).
    static let fallbackTransport = "relay"
    static let fallbackRevision = "relay-web"

    /// The identity used to address the preference store (same store, same scope ladder, only the identity segment is fixed).
    static func transportIdentity(provider: Provider, model: AIModel) -> String? {
        CapabilityPreferenceRuntimeIdentity(
            canonicalModelID: modelID(provider: provider, model: model),
            finalTransport: fallbackTransport, runtimeRevision: fallbackRevision
        ).wireValue
    }

    static func modelID(provider: Provider, model: AIModel) -> String {
        CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
    }

    /// The resolved switch (including the default layer); returns nil when out of scope.
    static func isOn(
        provider: Provider, model: AIModel, conversationID: UUID?, skillID: UUID? = nil,
        store: GenerationParameterSettingsStore = .shared, fragments: RelayWebFragmentStore = .shared
    ) -> Bool? {
        guard let effective = RelayWebProbe.effectiveFragments(provider: provider, model: model, fragments: fragments)
        else { return nil }
        guard let identity = transportIdentity(provider: provider, model: model) else { return effective.saved }
        // Read compatibility: when the fixed identity has no record in a scope, copy over the latest web value under the old (protocol-bearing) identity of the same scope.
        store.adoptLegacyWebPreference(
            providerID: provider.id, modelID: modelID(provider: provider, model: model),
            conversationID: conversationID, skillID: skillID, fixedIdentity: identity
        )
        return store.resolvedCapabilityPreferences(
            providerID: provider.id, modelID: modelID(provider: provider, model: model),
            conversationID: conversationID, skillID: skillID, transportIdentity: identity,
            providerDefault: effective.saved ? .init(web: .automatic) : nil
        ).web != .off
    }

    /// When a new conversation sends its first message, move the switch from the draft id to the real conversation id (at the same moment `AppState.sendMessage` moves the official preference).
    /// The switch is addressed by the fixed relay identity, not the official runtime identity; moving only the official one would leave the switch the user just turned on
    /// under the draft id: the first message would carry no fragment, and after sending the panel would read the default (off) by conversation id.
    static func migrateSession(
        provider: Provider, model: AIModel, from draftID: UUID, to conversationID: UUID,
        store: GenerationParameterSettingsStore = .shared
    ) {
        guard provider.kind == .relay, let identity = transportIdentity(provider: provider, model: model) else { return }
        store.migrateCapabilitySession(
            providerID: provider.id, modelID: modelID(provider: provider, model: model),
            from: draftID, to: conversationID, transportIdentity: identity
        )
    }

    /// Writes the switch (conversation scope; with no conversation, the model default), keeping the reasoning level in the same record.
    static func write(
        _ isOn: Bool, provider: Provider, model: AIModel, conversationID: UUID?,
        store: GenerationParameterSettingsStore = .shared
    ) {
        guard let identity = transportIdentity(provider: provider, model: model) else { return }
        let modelID = modelID(provider: provider, model: model)
        var values = store.capabilityPreferences(
            providerID: provider.id, modelID: modelID, conversationID: conversationID, transportIdentity: identity
        ) ?? CapabilityPreferenceValues(web: .inherit)
        values.web = isOn ? .automatic : .off
        store.setCapabilityPreferences(
            values, providerID: provider.id, modelID: modelID, conversationID: conversationID, transportIdentity: identity
        )
    }
}
