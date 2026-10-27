import Foundation

// MARK: - Execution-side composition entry point (external search services contract)
//
// Function-by-function port of scripts/lib/search-turn.mjs (same names on all three platforms): planSearchTurn / startSearchReply / applySearchEvent /
// finishSearchReply / searchedRecordLine. Covers everything from resolveWebSearchState's route.path through to the request and its presentation:
// pre-send planning -> one step per search -> reply finish. The IO layer (executor, tool loop, [D] assembly, persistence, telemetry sending) only acts on these outputs,
// and never decides counts, budgets, numbering, facts or error cards itself.

nonisolated enum SearchTurnError: Error, Equatable {
    case externalPathWithoutService
    case callInFlight
    case resultWithoutCall

    var message: String {
        switch self {
        case .externalPathWithoutService: "external path without service"
        case .callInFlight: "call while another call is in flight"
        case .resultWithoutCall: "result without call"
        }
    }
}

/// The search service used this turn. protocolID = catalog / searxng / same_as / manual.
nonisolated struct SearchTurnService: Sendable, Equatable {
    var id: String
    var name: String
    var protocolID: String
    var custom: Bool
}

/// Another service that can be switched to (the error card's secondary action "Switch to X").
nonisolated struct SearchOtherService: Sendable, Equatable {
    var id: String
    var name: String
    var isDefault: Bool
}

nonisolated struct SearchTurnThinking: Sendable, Equatable {
    var on = false
    var protocolID: String?
    var continuationStateAvailable = true
}

/// Upstream rejection of a request carrying tools: status = HTTP status, leg = which leg of this reply (0-based).
nonisolated struct SearchUpstreamRejection: Sendable, Equatable {
    var status: Int
    var leg: Int
}

nonisolated struct SearchTurnPlanInput: Sendable, Equatable {
    var path: WebSearchRoute.Path
    var service: SearchTurnService?
    var toolCall: WebSearchRouteInput.ToolCall = .unknown
    /// The path field is unused; resolution follows this input's path.
    var host = SearchToolHostInput(path: .none)
    var thinking = SearchTurnThinking()
    var upstreamRejection: SearchUpstreamRejection?
    /// This conversation x model has already been rejected once during this run (kept in memory only, not persisted).
    var toolsRejectedBefore = false
    var regenerateAction: SearchRegenerateAction = .send
    var previousResultsPersisted = false
    var userText: String?
    /// Context window B; nil = unknown.
    var windowTokens: Double?
    /// Local date YYYY-MM-DD.
    var today: String
}

/// Telemetry events (external search services contract).
nonisolated enum SearchTelemetryEvent: Encodable, Sendable, Equatable {
    case fallbackPresearch(reason: String)
    case searchExecuted(SearchExecutedProps)

    private enum CodingKeys: String, CodingKey { case event, props }
    private enum ReasonKeys: String, CodingKey { case reason }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fallbackPresearch(let reason):
            try container.encode("search_fallback_presearch", forKey: .event)
            var props = container.nestedContainer(keyedBy: ReasonKeys.self, forKey: .props)
            try props.encode(reason, forKey: .reason)
        case .searchExecuted(let props):
            try container.encode("search_executed", forKey: .event)
            try container.encode(props, forKey: .props)
        }
    }
}

nonisolated struct SearchExecutedProps: Encodable, Sendable, Equatable {
    var service: String
    var `protocol`: String
    var path: String
    var result_bucket: String
    var latency_bucket: String
    var error_class: String
    var retried: Bool
}

/// web_search tool definition (visible to the model, English, byte-identical on all three platforms).
nonisolated struct WebSearchToolDefinition: Encodable, Sendable, Equatable {
    struct Property: Encodable, Sendable, Equatable {
        var type: String
        var description: String
    }

    struct Parameters: Encodable, Sendable, Equatable {
        var type = "object"
        var properties: [String: Property]
        var required: [String]
    }

    var name: String
    var description: String
    var parameters: Parameters
}

nonisolated struct SearchPresearchRequest: Encodable, Sendable, Equatable {
    var query: String
    var count: Int
}

nonisolated struct SearchTurnPlan: Encodable, Sendable, Equatable {
    var path: WebSearchRoute.Path
    var fallbackReason: String?
    var noticeOnce: Bool
    var requestHasNativeSearchFields: Bool
    var requestHasWebSearchTool: Bool
    var toolHost: SearchToolHost
    var webSearchTool: WebSearchToolDefinition?
    var presearch: SearchPresearchRequest?
    var reuse: Bool
    var budget: SearchInjectionBudget?
    var writeToolConfirm: String
    var telemetry: [SearchTelemetryEvent]

    private enum CodingKeys: String, CodingKey {
        case path, fallbackReason, noticeOnce, requestHasNativeSearchFields, requestHasWebSearchTool
        case toolHost, webSearchTool, presearch, reuse, budget, writeToolConfirm, telemetry
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(fallbackReason, forKey: .fallbackReason)
        try container.encode(noticeOnce, forKey: .noticeOnce)
        try container.encode(requestHasNativeSearchFields, forKey: .requestHasNativeSearchFields)
        try container.encode(requestHasWebSearchTool, forKey: .requestHasWebSearchTool)
        try container.encode(toolHost, forKey: .toolHost)
        try container.encode(webSearchTool, forKey: .webSearchTool)
        try container.encode(presearch, forKey: .presearch)
        try container.encode(reuse, forKey: .reuse)
        try container.encode(budget, forKey: .budget)
        try container.encode(writeToolConfirm, forKey: .writeToolConfirm)
        try container.encode(telemetry, forKey: .telemetry)
    }
}

/// A persisted external search source (one item in a message's citations with source = external_search).
nonisolated struct SearchWebCitation: Codable, Sendable, Equatable {
    var number: Int
    var source: String
    var title: String
    var url: String
    var snippet: String
    var query: String
    var serviceId: String
    var serviceName: String
    var retrievedAt: String
    var site: String?
    var date: String?
}

nonisolated struct SearchReplyStartInput: Sendable, Equatable {
    /// From planSearchTurn.
    var path: WebSearchRoute.Path
    var fallbackReason: String?
    var noticeOnce: Bool
    var service: SearchTurnService
    var otherServices: [SearchOtherService] = []
    var windowTokens: Double?
    var rhoHi: Double
    var retrievedAt: String
    /// Sources already numbered in this message before the search (library <entry citation>); shares one allocator with external search.
    var priorBatches: [SearchCitationBatch] = []
}

extension SearchReplyStartInput {
    init(
        plan: SearchTurnPlan, service: SearchTurnService, otherServices: [SearchOtherService], windowTokens: Double?,
        rhoHi: Double, retrievedAt: String, priorBatches: [SearchCitationBatch] = []
    ) {
        self.init(
            path: plan.path, fallbackReason: plan.fallbackReason, noticeOnce: plan.noticeOnce, service: service,
            otherServices: otherServices, windowTokens: windowTokens, rhoHi: rhoHi, retrievedAt: retrievedAt,
            priorBatches: priorBatches
        )
    }
}

nonisolated struct SearchReplyState: Sendable, Equatable {
    struct Current: Sendable, Equatable {
        var query: String
        var count: Int?
        var requests: Int
        var attempts: Int
        var latencyMs: Int
        var reused: Bool
    }

    struct Call: Sendable, Equatable {
        var query: String
        /// results / empty / cap_reached / error class name.
        var outcome: String
        var delivered: Int
        var requests: Int
        var errorClass: String?
        var reused: Bool
    }

    /// presearch / tool.
    var path: String
    var notice: String?
    var service: SearchTurnService
    var otherServices: [SearchOtherService]
    var windowTokens: Double?
    var rhoHi: Double
    var retrievedAt: String
    var requestsSent: Int
    var usedTokens: Int
    var allocatorKeys: [String: Int]
    var allocatorNext: Int
    var current: Current?
    var calls: [Call]
    var citations: [SearchWebCitation]
    var webResultsPresent: Bool
}

/// The executor's report for one request.
nonisolated struct SearchCallOutcome: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case results([SearchResultItem])
        case empty
        case error(errorClass: String, retryOnce: Bool)
    }

    var kind: Kind
    var latencyMs: Int = 0
    /// Meaningful only for error: false = blocked by the local pre-check, the request was never sent.
    var sent: Bool? = nil
}

nonisolated enum SearchReplyEvent: Sendable, Equatable {
    /// The model called web_search / a pre-search started.
    case call(query: String?, count: Int?)
    case result(SearchCallOutcome)
    /// Reuse on resend: rebuilt from the message's persisted citations, no request is sent.
    case reuse(query: String, results: [SearchResultItem])
    /// MCP sources appearing in the loop, sharing the numbering.
    case otherSources(source: String, items: [SearchCitationItem])
    /// User stopped: the in-flight request was already sent and still counts as one (no results).
    case stopped
}

nonisolated struct SearchActivity: Encodable, Sendable, Equatable {
    var kind = "external_search"
    var serviceName: String
    var query: String
}

nonisolated enum SearchReplyEffect: Encodable, Sendable, Equatable {
    case send(retry: Bool, activity: SearchActivity)
    case deliver(content: String, citations: [SearchWebCitation], webResultsPresent: Bool, telemetry: [SearchTelemetryEvent])
    case numbers([Int])
    case none

    private enum CodingKeys: String, CodingKey { case kind, retry, activity, content, citations, webResultsPresent, telemetry, numbers }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .send(let retry, let activity):
            try container.encode("send", forKey: .kind)
            try container.encode(retry, forKey: .retry)
            try container.encode(activity, forKey: .activity)
        case .deliver(let content, let citations, let webResultsPresent, let telemetry):
            try container.encode("deliver", forKey: .kind)
            try container.encode(content, forKey: .content)
            try container.encode(citations, forKey: .citations)
            try container.encode(webResultsPresent, forKey: .webResultsPresent)
            try container.encode(telemetry, forKey: .telemetry)
        case .numbers(let numbers):
            try container.encode("numbers", forKey: .kind)
            try container.encode(numbers, forKey: .numbers)
        case .none:
            try container.encode("none", forKey: .kind)
        }
    }
}

nonisolated struct SearchSourcesLine: Encodable, Sendable, Equatable {
    var searchCount: Int
    var serviceName: String
    var sourceCount: Int
    /// Everything came from resend reuse: the source line reads "Reusing the previous search".
    var reused: Bool
    var custom: Bool
}

nonisolated struct SearchReplyErrorCard: Encodable, Sendable, Equatable {
    struct SwitchTarget: Encodable, Sendable, Equatable {
        var id: String
        var name: String
    }

    var errorClass: String
    var headline: String
    var primaryAction: String
    var secondaryAction: String?
    var serviceName: String
    var switchTo: SwitchTarget?

    private enum CodingKeys: String, CodingKey { case errorClass, headline, primaryAction, secondaryAction, serviceName, switchTo }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(errorClass, forKey: .errorClass)
        try container.encode(headline, forKey: .headline)
        try container.encode(primaryAction, forKey: .primaryAction)
        try container.encodeIfPresent(secondaryAction, forKey: .secondaryAction)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(switchTo, forKey: .switchTo)
    }
}

nonisolated struct SearchReplyFinish: Encodable, Sendable, Equatable {
    var facts: SearchFacts
    var sourcesLine: SearchSourcesLine?
    var errorCard: SearchReplyErrorCard?
    var notice: String?
    var citations: [SearchWebCitation]
    var webResultsPresent: Bool

    private enum CodingKeys: String, CodingKey { case facts, sourcesLine, errorCard, notice, citations, webResultsPresent }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(facts, forKey: .facts)
        try container.encode(sourcesLine, forKey: .sourcesLine)
        try container.encode(errorCard, forKey: .errorCard)
        try container.encode(notice, forKey: .notice)
        try container.encode(citations, forKey: .citations)
        try container.encode(webResultsPresent, forKey: .webResultsPresent)
    }
}

nonisolated enum SearchTurn {
    /// Criteria for upstream rejecting tools (tools_rejected): first leg of this reply, web_search was included, the catalog did not confirm tool-call support, HTTP 400 / 422.
    static let toolsRejectedStatuses = [400, 422]

    /// A pre-search has no tool, so the message returned to the model must not mention web_search (placed where <oriveo-web> sits in [D]). English, byte-identical on all three platforms.
    static let presearchMessages: [String: String] = [
        "no_results": "A web search for this message returned no results. Answer from what you know and say that the search found nothing.",
        "unavailable": "Web search was not available for this message. Answer directly and tell the user you could not search the web.",
        "cap_reached": "No web results could be added for this message. Answer from what you know.",
    ]

    /// web_search tool definition; {today} = local date YYYY-MM-DD.
    static let webSearchTool = WebSearchToolDefinition(
        name: "web_search",
        description: "Search the web for current information. Today is {today}. Each result has a publication date (date) when known; the search itself happens now. For technical topics you may search once more in English. Cite results as [n] using their id; do not write a reference list. At most 3 searches per reply.",
        parameters: .init(
            properties: [
                "query": .init(type: "string", description: "Search query, at most 400 characters."),
                "count": .init(type: "integer", description: "Number of results, 1 to 10. Default 5."),
            ],
            required: ["query"]
        )
    )

    /// Once this reply's remaining injection budget falls below this value, no more requests are sent: the envelope skeleton plus a single result would not fit, so sending would only waste money.
    static let minSearchBudgetTokens = 256

    static let resultBuckets = ["0", "1-3", "4-5", "6-10"]
    static let latencyBuckets = ["lt_1s", "1_3s", "3_10s", "gte_10s"]

    private static func resultBucket(_ count: Int) -> String {
        count <= 0 ? "0" : count <= 3 ? "1-3" : count <= 5 ? "4-5" : "6-10"
    }

    private static func latencyBucket(_ ms: Int) -> String {
        ms < 1000 ? "lt_1s" : ms < 3000 ? "1_3s" : ms < 10000 ? "3_10s" : "gte_10s"
    }

        // MARK: Pre-send planning

        /// Called once on each send, and once more when switching route after upstream rejects tools.
    static func planSearchTurn(_ input: SearchTurnPlanInput) throws -> SearchTurnPlan {
        var host = input.host
        guard input.path.isExternal else {
            let turn = SearchRoute.resolveSearchTurnPath(SearchTurnInput(path: input.path))
            host.path = input.path
            return SearchTurnPlan(
                path: turn.path, fallbackReason: turn.fallbackReason, noticeOnce: turn.noticeOnce,
                requestHasNativeSearchFields: turn.requestHasNativeSearchFields,
                requestHasWebSearchTool: turn.requestHasWebSearchTool,
                toolHost: try SearchToolHosts.resolveSearchToolHost(host),
                webSearchTool: nil, presearch: nil, reuse: false, budget: nil, writeToolConfirm: "n/a", telemetry: []
            )
        }
        guard input.service != nil else { throw SearchTurnError.externalPathWithoutService }
        var toolHost: SearchToolHost?
        if input.path == .externalTool {
            host.path = .externalTool
            toolHost = try SearchToolHosts.resolveSearchToolHost(host)
        }
        let supported = input.toolCall == .supported
        let rejectedNow = input.upstreamRejection.map { $0.leg == 0 && toolsRejectedStatuses.contains($0.status) } == true && !supported
                // This conversation x model was already rejected once during this run: go straight to pre-search with no more prompting (kept in memory only, not persisted)
        let rejectedBefore = input.toolsRejectedBefore && !supported
        let turn = SearchRoute.resolveSearchTurnPath(SearchTurnInput(
            path: input.path,
            thinkingOn: input.thinking.on,
            continuationStateAvailable: input.thinking.continuationStateAvailable,
            upstreamRejectedTools: rejectedNow || rejectedBefore,
                        // Protocols not yet verified always use pre-search while thinking is on ("protocols we can't pin down")
            thinkingWithTools: input.thinking.protocolID.flatMap { SearchToolHosts.thinkingToolRules[$0]?.thinkingWithTools } ?? "presearch",
            hostMaxSteps: toolHost?.maxSteps ?? 0
        ))
        let reuse = SearchRoute.regenerateSearchPolicy(
            action: input.regenerateAction, previousResultsPersisted: input.previousResultsPersisted
        ).reusePrevious
        let toolPath = turn.path == .externalTool && !reuse
        var resolvedHost: SearchToolHost
        if toolPath, let toolHost {
            resolvedHost = toolHost
        } else {
            host.path = .externalPresearch
            resolvedHost = try SearchToolHosts.resolveSearchToolHost(host)
        }
        var tool: WebSearchToolDefinition?
        if toolPath {
            tool = webSearchTool
            tool?.description = webSearchTool.description.replacingOccurrences(of: "{today}", with: input.today)
        }
        return SearchTurnPlan(
            path: turn.path,
            fallbackReason: turn.fallbackReason,
            noticeOnce: turn.noticeOnce && rejectedNow,
            requestHasNativeSearchFields: turn.requestHasNativeSearchFields,
            requestHasWebSearchTool: toolPath,
            toolHost: resolvedHost,
            webSearchTool: tool,
            presearch: turn.path == .externalPresearch && !reuse ? .init(query: input.userText ?? "", count: 5) : nil,
            reuse: reuse,
            budget: SearchInject.searchInjectionBudget(input.windowTokens),
                        // When web results enter the context this turn, MCP write tools are forced to "this time only"; pre-search applies the same way
            writeToolConfirm: input.host.mcp ? "once_when_web_results_present" : "n/a",
            telemetry: turn.fallbackReason.map { [.fallbackPresearch(reason: $0)] } ?? []
        )
    }

        // MARK: One reply

    static func startSearchReply(_ input: SearchReplyStartInput) -> SearchReplyState {
        var keys: [String: Int] = [:]
        var next = 1
        for batch in input.priorBatches {
            for item in batch.items {
                let key = SearchInject.citationKey(item)
                if keys[key] == nil {
                    keys[key] = next
                    next += 1
                }
            }
        }
        return SearchReplyState(
            path: input.path == .externalPresearch ? "presearch" : "tool",
            notice: input.noticeOnce ? input.fallbackReason : nil,
            service: input.service,
            otherServices: input.otherServices,
            windowTokens: input.windowTokens,
            rhoHi: input.rhoHi,
            retrievedAt: input.retrievedAt,
            requestsSent: 0,
            usedTokens: 0,
            allocatorKeys: keys,
            allocatorNext: next,
            current: nil,
            calls: [],
            citations: [],
            webResultsPresent: false
        )
    }

    private static func message(_ state: SearchReplyState, _ key: String) -> String {
        (state.path == "presearch" ? presearchMessages : SearchTransport.toolMessages)[key] ?? ""
    }

    private struct Delivery {
        var state: SearchReplyState
        var delivered: Int
        var content: String
        var citations: [SearchWebCitation]
    }

    private static func deliverResults(_ state: SearchReplyState, query: String, results: [SearchResultItem]) -> Delivery {
                // URLs already numbered in this message are not given to the model again (already in its context); only new results get numbers
        var fresh: [SearchResultItem] = []
        var seen: Set<String> = []
        for result in results {
            let key = SearchInject.citationKey(.init(url: result.url))
            if state.allocatorKeys[key] != nil || seen.contains(key) { continue }
            seen.insert(key)
            fresh.append(result)
        }
        let budgetTokens = SearchInject.budgetForNextSearch(windowTokens: state.windowTokens, usedTokens: state.usedTokens)
        let fit = fresh.isEmpty ? nil : SearchInject.fitWebResults(
            provider: state.service.name, query: query, retrievedAt: state.retrievedAt, results: fresh,
            firstId: state.allocatorNext, budgetTokens: budgetTokens, rhoHi: state.rhoHi
        )
        guard let fit, let envelope = fit.envelope else {
            return Delivery(state: state, delivered: 0, content: message(state, fresh.isEmpty ? "no_results" : "cap_reached"), citations: [])
        }
        var next = state
        let citations = fit.ids.enumerated().map { index, id -> SearchWebCitation in
            let result = fresh[index]
            next.allocatorKeys[SearchInject.citationKey(.init(url: result.url))] = id
            return SearchWebCitation(
                number: id, source: "external_search", title: result.title, url: result.url, snippet: result.snippet,
                query: query, serviceId: state.service.id, serviceName: state.service.name, retrievedAt: state.retrievedAt,
                site: result.site?.isEmpty == false ? result.site : nil,
                date: result.date?.isEmpty == false ? result.date : nil
            )
        }
        next.usedTokens += fit.estimatedTokens
        next.allocatorNext += fit.ids.count
        next.citations += citations
        next.webResultsPresent = true
        return Delivery(state: next, delivered: citations.count, content: envelope, citations: citations)
    }

    private static func finishCall(_ state: SearchReplyState, _ outcome: SearchCallOutcome) -> (SearchReplyState, SearchReplyEffect) {
        guard let current = state.current else { return (state, .none) }
        var next = state
        next.current = nil
        var delivered = 0
        let content: String
        var citations: [SearchWebCitation] = []
        let recorded: String
        var errorClass: String?
        switch outcome.kind {
        case .results(let results):
            let delivery = deliverResults(next, query: current.query, results: results)
            next = delivery.state
            delivered = delivery.delivered
            content = delivery.content
            citations = delivery.citations
            recorded = delivered > 0 ? "results" : "empty"
        case .empty:
            content = message(next, "no_results")
            recorded = "empty"
        case .error(let name, _):
            content = message(next, "unavailable")
            recorded = name
            errorClass = name
        }
        next.calls.append(.init(
            query: current.query, outcome: recorded, delivered: delivered, requests: current.requests,
            errorClass: errorClass, reused: current.reused
        ))
        let telemetry: [SearchTelemetryEvent] = current.reused ? [] : [.searchExecuted(.init(
            service: next.service.custom ? "custom" : next.service.id,
            protocol: next.service.protocolID,
            path: next.path,
            result_bucket: resultBucket(delivered),
            latency_bucket: latencyBucket(current.latencyMs),
            error_class: errorClass ?? "none",
            retried: current.attempts > 1
        ))]
        return (next, .deliver(content: content, citations: citations, webResultsPresent: next.webResultsPresent, telemetry: telemetry))
    }

        /// One step: returns the new state and what the IO layer should do (send / deliver / numbers / none).
    static func applySearchEvent(_ state: SearchReplyState, _ event: SearchReplyEvent) throws -> (state: SearchReplyState, effect: SearchReplyEffect) {
        let limits = SearchRoute.searchCallLimits
        switch event {
        case .otherSources(_, let items):
            var next = state
            let numbers = items.map { item -> Int in
                let key = SearchInject.citationKey(item)
                if let number = next.allocatorKeys[key] { return number }
                next.allocatorKeys[key] = next.allocatorNext
                next.allocatorNext += 1
                return next.allocatorNext - 1
            }
            return (next, .numbers(numbers))
        case .stopped:
            guard let current = state.current else { return (state, .none) }
            var next = state
            next.current = nil
            next.requestsSent += 1
            next.calls.append(.init(
                query: current.query, outcome: "empty", delivered: 0, requests: current.requests + 1, errorClass: nil, reused: false
            ))
            return (next, .none)
        case .reuse(let query, let results):
            var next = state
            next.current = .init(query: query, count: nil, requests: 0, attempts: 0, latencyMs: 0, reused: true)
            let finished = finishCall(next, .init(kind: .results(results)))
            return (finished.0, finished.1)
        case .call(let rawQuery, let count):
            if state.current != nil { throw SearchTurnError.callInFlight }
            let query = SearchJSText.trim(rawQuery ?? "")
                        // An empty query sends no request and does not count as a search (query_empty)
            if query.isEmpty {
                return (state, .deliver(content: message(state, "no_results"), citations: [], webResultsPresent: state.webResultsPresent, telemetry: []))
            }
            let noBudget = SearchInject.budgetForNextSearch(windowTokens: state.windowTokens, usedTokens: state.usedTokens) < minSearchBudgetTokens
            if state.requestsSent >= limits.maxSearchRequestsPerReply || noBudget {
                                // Over the cap or this reply's injection budget is used up: no request, no charge (cap_reached)
                var next = state
                next.calls.append(.init(query: query, outcome: "cap_reached", delivered: 0, requests: 0, errorClass: nil, reused: false))
                return (next, .deliver(content: message(state, "cap_reached"), citations: [], webResultsPresent: state.webResultsPresent, telemetry: []))
            }
            var next = state
            next.current = .init(query: query, count: count, requests: 0, attempts: 0, latencyMs: 0, reused: false)
            return (next, .send(retry: false, activity: .init(serviceName: state.service.name, query: query)))
        case .result(let outcome):
            guard var current = state.current else { throw SearchTurnError.resultWithoutCall }
            var retryOnce = false
            var sent = true
            if case .error(_, let retry) = outcome.kind {
                retryOnce = retry
                sent = outcome.sent != false
            }
            current.attempts += 1
            current.requests += sent ? 1 : 0
            current.latencyMs += outcome.latencyMs
            var next = state
            next.current = current
            next.requestsSent += sent ? 1 : 0
            if retryOnce, current.attempts <= limits.maxRetriesPerCall, next.requestsSent < limits.maxSearchRequestsPerReply {
                return (next, .send(retry: true, activity: .init(serviceName: next.service.name, query: current.query)))
            }
            let finished = finishCall(next, outcome)
            return (finished.0, finished.1)
        }
    }

        // MARK: Finish

        /// Reply finish: message facts, source line, error card, sources to persist.
    static func finishSearchReply(_ state: SearchReplyState) -> SearchReplyFinish {
        let calls = state.calls.map { SearchFactCall(outcome: $0.outcome, delivered: $0.delivered) }
        let presearch = state.path == "presearch"
        let facts = SearchInject.summarizeSearchFacts(presearch
            ? .init(path: .externalPresearch, webOn: true, presearch: calls.first, serviceName: state.service.name)
            : .init(path: .externalTool, webOn: true, calls: calls, serviceName: state.service.name))
        let sourcesLine: SearchSourcesLine? = facts.searchCount > 0 && facts.state != "failed"
            ? .init(
                searchCount: facts.searchCount, serviceName: state.service.name, sourceCount: facts.sourceCount,
                reused: state.calls.allSatisfy(\.reused), custom: state.service.custom
            )
            : nil
        var errorCard: SearchReplyErrorCard?
        if facts.state == "failed", let last = state.calls.last(where: { $0.errorClass != nil }), let errorClass = last.errorClass {
            let card = SearchTransport.searchErrorCard(
                errorClass, custom: state.service.custom, otherServices: state.otherServices.count
            )
            let other = state.otherServices.first(where: \.isDefault) ?? state.otherServices.first
            errorCard = SearchReplyErrorCard(
                errorClass: errorClass,
                headline: card.headline,
                primaryAction: card.primaryAction,
                secondaryAction: card.secondaryAction,
                serviceName: state.service.name,
                switchTo: card.secondaryAction == "switch_to_other_service" ? other.map { .init(id: $0.id, name: $0.name) } : nil
            )
        }
        return SearchReplyFinish(
            facts: facts, sourcesLine: sourcesLine, errorCard: errorCard, notice: state.notice,
            citations: state.citations, webResultsPresent: state.webResultsPresent
        )
    }

        /// Compact record of a historical assistant message: derived from its persisted external_search sources, containing only the query, titles and URLs, not snippets.
        /// Appended after the message body with one blank line between; returns nil if there are no external sources.
    static func searchedRecordLine(_ citations: [SearchWebCitation]) -> String? {
        var groups: [(query: String, items: [String])] = []
        var indexByQuery: [String: Int] = [:]
        for citation in citations where citation.source == "external_search" {
            if indexByQuery[citation.query] == nil {
                indexByQuery[citation.query] = groups.count
                groups.append((citation.query, []))
            }
            groups[indexByQuery[citation.query]!].items.append("\(citation.title) (\(citation.url))")
        }
        guard !groups.isEmpty else { return nil }
        let body = groups.map { "\"\($0.query)\" → \($0.items.joined(separator: ", "))" }.joined(separator: "; ")
        return "Web searches used for this reply (titles and URLs only): \(body)"
    }
}
