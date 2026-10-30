import Foundation

// MARK: - External search execution wiring (see the external search services contract)
//
// IO layer: on every send, compute this conversation's search services, call the SearchTurn combined entry point for plan / effect, then send requests, feed results back, persist, and emit telemetry per the effect.
// Counts, budget, numbering, facts, and error cards always come from SearchTurn's output; nothing is decided here.

/// Sends one search request (production = SearchExecutor; tests replace the HTTP layer or the whole thing).
nonisolated protocol ExternalSearchRequesting: Sendable {
    func run(_ target: ExternalSearchTarget, query: String, count: Int?, otherServices: Int) async -> SearchExecutionReport
}

/// All inputs one search request needs (the key lives only in memory).
nonisolated enum ExternalSearchTarget: Sendable {
    case preset(entry: SearchJSON, regionId: String, boundHost: String, withdrawn: Bool, key: String?)
    case custom(spec: SearchJSON, address: SearchServiceAddress, requestPath: String, key: String?)
    /// Decided locally that it cannot be sent (not in the catalog / invalid custom address): emit an error by category and the request never leaves the device.
    case unavailable(SearchErrorInput)
}

extension SearchExecutor: ExternalSearchRequesting {
    func run(_ target: ExternalSearchTarget, query: String, count: Int?, otherServices: Int) async -> SearchExecutionReport {
        switch target {
        case let .preset(entry, regionId, boundHost, withdrawn, key):
            return await runPresetReport(
                entry: entry, regionId: regionId, boundHost: boundHost, withdrawn: withdrawn,
                query: query, count: count, key: key, otherServices: otherServices
            )
        case let .custom(spec, address, requestPath, key):
            return await runCustomReport(
                spec: spec, address: address, requestPath: requestPath, query: query, count: count, key: key,
                otherServices: otherServices
            )
        case .unavailable(var input):
            input.otherServices = otherServices
            return .init(outcome: .failure(SearchTransport.classifySearchError(input)), sent: false)
        }
    }
}

extension ExternalSearchTarget {
    /// The preset service has no usable key (cannot be read locally / the reused connection was deleted).
    var presetKeyMissing: Bool {
        guard case let .preset(_, _, _, _, key) = self else { return false }
        return (key ?? "").isEmpty
    }
}

/// Service facts when this turn goes through external search (computed once before sending).
struct ExternalSearchServiceContext: Sendable {
    var path: WebSearchRoute.Path
    var service: SearchTurnService
    /// Telemetry service dimension: preset = catalog id, custom = custom (Citation / error card use the local service record id).
    var telemetryServiceID: String
    var otherServices: [SearchOtherService]
    var target: ExternalSearchTarget
    /// "Results per search" on the detail page (used when the model gives no count).
    var resultCount: Int
    var toolCall: WebSearchRouteInput.ToolCall
}

/// External search state of one reply (started after planSearchTurn, finished in finishSearchReply).
@MainActor
final class ExternalSearchTurn {
    let plan: SearchTurnPlan
    let context: ExternalSearchServiceContext
    private let requester: any ExternalSearchRequesting
    private(set) var state: SearchReplyState
    /// On send gives the activity (service name + query), on deliver gives nil.
    var onActivity: (SearchActivity?) -> Void = { _ in }
    /// Telemetry in effect / plan (the service dimension is already rewritten per telemetryServiceID).
    var onTelemetry: (SearchTelemetryEvent) -> Void = { _ in }
    private var finished: SearchReplyFinish?
    /// Starting input (an internal resend rebuilds the [D] envelope on a separate state using the same allocator start).
    private let startInput: SearchReplyStartInput
    /// An internal resend this turn (window overflow / memory downgrade) continues the previous attempt: the reply state carries over (source row and facts = this turn's real request count),
    /// and the [D] envelope is rebuilt on a separate state with reuse.
    let carriesPriorAttempt: Bool

    init(
        plan: SearchTurnPlan,
        context: ExternalSearchServiceContext,
        windowTokens: Double?,
        rhoHi: Double,
        priorBatches: [SearchCitationBatch] = [],
        retrievedAt: String = ExternalSearchTurn.retrievedAtNow(),
        requester: any ExternalSearchRequesting = SearchExecutor()
    ) {
        self.plan = plan
        self.context = context
        self.requester = requester
        startInput = SearchReplyStartInput(
            plan: plan, service: context.service, otherServices: context.otherServices, windowTokens: windowTokens,
            rhoHi: rhoHi, retrievedAt: retrievedAt, priorBatches: priorBatches
        )
        state = SearchTurn.startSearchReply(startInput)
        carriesPriorAttempt = false
    }

    /// Internal resend this turn: a new plan (no more searching), the reply state continues from the previous attempt.
    init(plan: SearchTurnPlan, carrying previous: ExternalSearchTurn, requester: any ExternalSearchRequesting) {
        self.plan = plan
        context = previous.context
        self.requester = requester
        startInput = previous.startInput
        state = previous.state
        carriesPriorAttempt = true
    }

    /// [D] section of an internal resend: rebuild the envelope with reuse on a separate starting state (numbering starts at the same point as the original state); the original reply state is untouched and no telemetry is emitted.
    func reuseEnvelope(_ citations: [SearchWebCitation]) -> String? {
        var scratch = SearchTurn.startSearchReply(startInput)
        let contents = Self.reuseGroups(citations).compactMap { group -> String? in
            guard let step = try? SearchTurn.applySearchEvent(scratch, .reuse(query: group.query, results: group.results)),
                  case .deliver(let content, _, _, _) = step.effect else { return nil }
            scratch = step.state
            return content.isEmpty ? nil : content
        }
        return contents.isEmpty ? nil : contents.joined(separator: "\n\n")
    }

    /// Persisted external sources sorted by number and grouped by query (input of the reuse event).
    nonisolated static func reuseGroups(_ citations: [SearchWebCitation]) -> [(query: String, results: [SearchResultItem])] {
        var groups: [(query: String, results: [SearchResultItem])] = []
        var index: [String: Int] = [:]
        for citation in citations.sorted(by: { $0.number < $1.number }) where citation.source == Citation.externalSearchSource {
            if index[citation.query] == nil {
                index[citation.query] = groups.count
                groups.append((citation.query, []))
            }
            groups[index[citation.query]!].results.append(SearchResultItem(
                title: citation.title, url: citation.url, snippet: citation.snippet, site: citation.site, date: citation.date
            ))
        }
        return groups
    }

    var webResultsPresent: Bool { state.webResultsPresent }

    /// One search (the model calls web_search / pre-search), running until deliver; returns the content handed back to the model (tool_result or the [D] section).
    func search(query: String?, count: Int?) async -> String {
        var effect = apply(.call(query: query, count: count))
        while true {
            switch effect {
            case .send(_, let activity):
                onActivity(activity)
                guard let current = state.current else { return "" }
                // The preset service's key cannot be read locally (or the reused connection was deleted): send no request, record once as auth_invalid with sent = false (primary button "Update Key").
                // A custom service's key is optional, so send as usual.
                if context.target.presetKeyMissing {
                    effect = apply(.result(.init(kind: .error(errorClass: "auth_invalid", retryOnce: false), sent: false)))
                    continue
                }
                let started = ContinuousClock.now
                let report = await requester.run(
                    context.target, query: current.query, count: current.count ?? context.resultCount,
                    otherServices: context.otherServices.count
                )
                let elapsed = ContinuousClock.now - started
                let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                effect = apply(.result(Self.outcome(report, latencyMs: latencyMs)))
            case .deliver(let content, _, _, let telemetry):
                onActivity(nil)
                telemetry.forEach(emit)
                return content
            case .numbers, .none:
                onActivity(nil)
                return ""
            }
        }
    }

    /// Pre-search: query = the user's own words (plan.presearch).
    func presearch() async -> String? {
        guard let request = plan.presearch else { return nil }
        return await search(query: request.query, count: request.count)
    }

    /// Resend reuse (plan.reuse): the external sources of the message being regenerated are grouped by query and sent as reuse, with no request. Returns the [D] section.
    func reuse(_ citations: [SearchWebCitation]) -> String? {
        let contents = Self.reuseGroups(citations).compactMap { group -> String? in
            guard case .deliver(let content, _, _, let telemetry) = apply(.reuse(query: group.query, results: group.results)) else {
                return nil
            }
            telemetry.forEach(emit)
            return content.isEmpty ? nil : content
        }
        return contents.isEmpty ? nil : contents.joined(separator: "\n\n")
    }

    /// Sources from elsewhere in the loop (library / MCP) share numbering with external search.
    @discardableResult
    func otherSources(source: String, items: [SearchCitationItem]) -> [Int] {
        guard !items.isEmpty, case .numbers(let numbers) = apply(.otherSources(source: source, items: items)) else { return [] }
        return numbers
    }

    /// Sources newly read in the library loop (the same whether they arrive before or after the web search): take numbers from the shared allocator (other_sources); keys that already have a number reuse it.
    func libraryNumber(docKey: String, url: String) -> Int? {
        otherSources(source: "library", items: [SearchCitationItem(libraryKey: docKey, url: url)]).first
    }

    /// Reply wrap-up (including a user stop: send stopped first). Computed only once.
    func finish(stopped: Bool) -> SearchReplyFinish {
        if let finished { return finished }
        if stopped { _ = apply(.stopped) }
        onActivity(nil)
        let result = SearchTurn.finishSearchReply(state)
        finished = result
        return result
    }

    /// plan.telemetry (search_fallback_presearch) is sent as usual.
    func emitPlanTelemetry() {
        plan.telemetry.forEach(emit)
    }

    private func apply(_ event: SearchReplyEvent) -> SearchReplyEffect {
        guard let step = try? SearchTurn.applySearchEvent(state, event) else { return .none }
        state = step.state
        return step.effect
    }

    private func emit(_ event: SearchTelemetryEvent) {
        if case .searchExecuted(var props) = event {
            props.service = context.telemetryServiceID
            onTelemetry(.searchExecuted(props))
        } else {
            onTelemetry(event)
        }
    }

    nonisolated static func outcome(_ report: SearchExecutionReport, latencyMs: Int) -> SearchCallOutcome {
        switch report.outcome {
        case .results(let items): return .init(kind: .results(items), latencyMs: latencyMs)
        case .empty: return .init(kind: .empty, latencyMs: latencyMs)
        case .failure(let classification):
            return .init(
                kind: .error(errorClass: classification.errorClass, retryOnce: classification.retryOnce),
                latencyMs: latencyMs, sent: report.sent
            )
        }
    }

    nonisolated static func retrievedAtNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Local date YYYY-MM-DD ({today} in the web_search tool description).
    nonisolated static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - This turn's service facts

extension ExternalSearchTurn {
    /// thinking.protocolID of planSearchTurn: maps this turn's tool-loop outbound protocol + provider to a key of thinkingToolRules,
    /// anything else passes through unchanged (treated as unverified).
    nonisolated static func thinkingProtocolID(transport: String, providerKind: ProviderKind) -> String {
        switch transport {
        case TransportKind.openaiChat.rawValue:
            switch providerKind {
            case .deepseek: return "deepseek_chat"
            case .moonshot: return "moonshot_chat"
            case .zhipu: return "zhipu_chat"
            case .qwen: return "qwen_chat"
            default: return "openai_chat"
            }
        case TransportKind.geminiGenerate.rawValue: return "gemini_generate_content"
        default: return transport
        }
    }

    /// On the external path, takes the current source service (preset protocol = catalog; custom takes its own protocol), the switchable services, and the execution input.
    static func serviceContext(
        state: WebSearchState,
        search: WebSearchSettingsModel,
        toolCall: WebSearchRouteInput.ToolCall,
        catalog: SearchCatalogStore = .shared
    ) async -> ExternalSearchServiceContext? {
        guard state.route.path.isExternal,
              let serviceID = state.source.serviceId,
              let item = search.items.first(where: { $0.id == serviceID }) else { return nil }
        let stored = item.service
        let service = SearchTurnService(
            id: item.id,
            name: item.displayName,
            protocolID: item.isCustom ? (stored.protocolID ?? "manual") : "catalog",
            custom: item.isCustom
        )
        let others = search.selectableItems.filter { $0.id != item.id }.map {
            SearchOtherService(id: $0.id, name: $0.displayName, isDefault: $0.id == search.defaultID)
        }
        let target: ExternalSearchTarget
        switch await search.testTarget(for: item) {
        case let .preset(entry, regionId, boundHost, key)?:
            target = .preset(
                entry: entry, regionId: regionId, boundHost: boundHost,
                withdrawn: await catalog.isWithdrawn(stored.serviceId ?? ""), key: key
            )
        case let .custom(spec, address, requestPath, key)?:
            target = .custom(spec: spec, address: address, requestPath: requestPath, key: key)
        case nil:
            target = .unavailable(item.isCustom
                ? SearchErrorInput(transportFailure: .blocked)
                : SearchErrorInput(preflight: .serviceWithdrawn))
        }
        return ExternalSearchServiceContext(
            path: state.route.path,
            service: service,
            telemetryServiceID: item.isCustom ? "custom" : (stored.serviceId ?? "custom"),
            otherServices: others,
            target: target,
            resultCount: stored.effectiveResultCount,
            toolCall: toolCall
        )
    }
}

// MARK: - Tool-loop entry

/// External search's `web_search` (definition from plan.webSearchTool). The executor does not throw: failures all map to result events and are fed back with a fixed phrase;
/// if it does throw it is also fed back as neutral and does not count toward consecutive failures (plan.toolHost.webSearchDisposition).
nonisolated struct ExternalWebSearchToolEntry: ToolRegistryEntry {
    static let toolName = "web_search"

    let definition: ToolLoopToolDefinition?
    let search: @Sendable (_ query: String?, _ count: Int?) async -> String

    var name: String { Self.toolName }
    var scope: ToolScope { .web }

    init(tool: WebSearchToolDefinition, search: @escaping @Sendable (_ query: String?, _ count: Int?) async -> String) {
        definition = Self.definition(tool)
        self.search = search
    }

    static func definition(_ tool: WebSearchToolDefinition) -> ToolLoopToolDefinition? {
        guard let data = try? JSONEncoder().encode(tool.parameters),
              let parameters = try? JSONDecoder().decode(ToolJSONValue.self, from: data) else { return nil }
        return ToolLoopToolDefinition(function: .init(name: tool.name, description: tool.description, parameters: parameters))
    }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        let object = call.function.arguments.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = object["query"] as? String
        let count = (object["count"] as? NSNumber)?.intValue
        return ToolExecutionOutcome(content: await search(query, count))
    }

    func failureDisposition(for error: any Error) -> ToolFailureDisposition {
        .neutral(code: "search_unavailable", message: SearchTransport.toolMessages["unavailable"] ?? "")
    }
}

/// The first leg carrying web_search was rejected by upstream with 400 / 422: hand back to the send task to recompute the plan per upstreamRejection (no resend with tools stripped).
nonisolated struct ExternalSearchToolsRejected: Error {
    var status: Int
    var underlying: any Error
}

/// Remembered in-process per "conversation x modelKey" that it was rejected (not persisted).
@MainActor
final class ExternalSearchToolsRejections {
    static let shared = ExternalSearchToolsRejections()
    private var keys: Set<String> = []

    func contains(conversationID: UUID, modelKey: String) -> Bool { keys.contains("\(conversationID.uuidString)|\(modelKey)") }
    func insert(conversationID: UUID, modelKey: String) { keys.insert("\(conversationID.uuidString)|\(modelKey)") }
}

// MARK: - Persistence

/// External search's message facts + error card + notice (finishSearchReply writes them onto the assistant message, device-local, stored with capabilityExecution).
nonisolated struct ExternalSearchMessageRecord: Codable, Hashable, Sendable {
    struct Facts: Codable, Hashable, Sendable {
        var state: String
        var source: String?
        var evidenceKind: String?
        var searchCount: Int
        var sourceCount: Int
        var serviceName: String?
        /// All from resend reuse (no new request).
        var reused: Bool?
    }

    struct SwitchTarget: Codable, Hashable, Sendable {
        var id: String
        var name: String
    }

    /// finishSearchReply.sourcesLine (the single source of the source card's three-part title); nil when no search was sent or it failed.
    struct SourcesLine: Codable, Hashable, Sendable {
        var searchCount: Int
        var serviceName: String
        var sourceCount: Int
        var reused: Bool
        var custom: Bool
    }

    struct ErrorCard: Codable, Hashable, Sendable {
        var errorClass: String
        var headline: String
        var primaryAction: String
        var secondaryAction: String?
        /// Local service record id (used to jump to the detail page).
        var serviceId: String
        var serviceName: String
        var switchTo: SwitchTarget?
    }

    var facts: Facts
    var sourcesLine: SourcesLine?
    var errorCard: ErrorCard?
    /// finishSearchReply.notice (one-time notice code for falling back to pre-search).
    var notice: String?

    init(facts: Facts, sourcesLine: SourcesLine? = nil, errorCard: ErrorCard? = nil, notice: String? = nil) {
        self.facts = facts
        self.sourcesLine = sourcesLine
        self.errorCard = errorCard
        self.notice = notice
    }

    init(finish: SearchReplyFinish, serviceID: String) {
        facts = Facts(
            state: finish.facts.state, source: finish.facts.source, evidenceKind: finish.facts.evidenceKind,
            searchCount: finish.facts.searchCount, sourceCount: finish.facts.sourceCount,
            serviceName: finish.facts.serviceName, reused: finish.sourcesLine?.reused
        )
        sourcesLine = finish.sourcesLine.map {
            SourcesLine(
                searchCount: $0.searchCount, serviceName: $0.serviceName, sourceCount: $0.sourceCount,
                reused: $0.reused, custom: $0.custom
            )
        }
        errorCard = finish.errorCard.map {
            ErrorCard(
                errorClass: $0.errorClass, headline: $0.headline, primaryAction: $0.primaryAction,
                secondaryAction: $0.secondaryAction, serviceId: serviceID, serviceName: $0.serviceName,
                switchTo: $0.switchTo.map { SwitchTarget(id: $0.id, name: $0.name) }
            )
        }
        notice = finish.notice
    }

    /// This platform's message-fact constants (equal to shared/search-contracts/result-facts.v1.json constants and the request_preference contract's resultFacts.externalSearch).
    static let source = "external_search"
    static let evidenceKind = "external_search_result"
    static let states = SearchInject.factStates
}
