import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Counting search request stub: replies with the same results each time and records how many requests were actually sent.
private final class CountingSearchRequester: ExternalSearchRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let results: [SearchResultItem]

    init(results: [SearchResultItem]) {
        self.results = results
    }

    var requestCount: Int { lock.withLock { count } }

    func run(_ target: ExternalSearchTarget, query: String, count: Int?, otherServices: Int) async -> SearchExecutionReport {
        lock.withLock { self.count += 1 }
        return SearchExecutionReport(outcome: .results(results), sent: true)
    }
}

/// Wiring patch: a preset with a missing key sends no request, the first leg of a library / MCP loop being rejected falls back to pre-search, an internal resend within the turn reuses results.
@Suite("External search execution wiring patch (missing key / rejection / internal resend / shared numbering)")
@MainActor
struct ExternalSearchTurnResendTests {
    private static let service = SearchTurnService(id: "stored-deepseek", name: "DeepSeek", protocolID: "catalog", custom: false)
    private static let results = [
        SearchResultItem(title: "A", url: "https://a.example/1", snippet: "alpha", site: "a.example", date: nil),
        SearchResultItem(title: "B", url: "https://b.example/2", snippet: "beta", site: "b.example", date: nil),
    ]

    private static func presetTarget(key: String?) throws -> ExternalSearchTarget {
        let catalog = try #require(try SearchContractSupport.load("shared/search-contracts/search_catalog_contract.v1.json")["catalog"])
        let entry = try #require(SearchContractSupport.service("deepseek", in: catalog))
        return .preset(entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, key: key)
    }

    private static func context(
        _ target: ExternalSearchTarget, path: WebSearchRoute.Path = .externalTool, service: SearchTurnService = service
    ) -> ExternalSearchServiceContext {
        ExternalSearchServiceContext(
            path: path, service: service, telemetryServiceID: "deepseek", otherServices: [], target: target,
            resultCount: 5, toolCall: .supported
        )
    }

    private static func plan(
        path: WebSearchRoute.Path = .externalTool,
        service: SearchTurnService = service,
        toolCall: WebSearchRouteInput.ToolCall = .supported,
        library: Bool = false,
        mcp: Bool = false,
        upstreamRejection: SearchUpstreamRejection? = nil,
        regenerateAction: SearchRegenerateAction = .send,
        previousResultsPersisted: Bool = false
    ) throws -> SearchTurnPlan {
        try SearchTurn.planSearchTurn(SearchTurnPlanInput(
            path: path,
            service: service,
            toolCall: toolCall,
            host: SearchToolHostInput(path: path, library: library, mcp: mcp),
            upstreamRejection: upstreamRejection,
            regenerateAction: regenerateAction,
            previousResultsPersisted: previousResultsPersisted,
            userText: "Oriveo 联网搜索",
            windowTokens: 128_000,
            today: "2026-10-27"
        ))
    }

    private static func turn(
        plan: SearchTurnPlan, context: ExternalSearchServiceContext, requester: CountingSearchRequester
    ) -> ExternalSearchTurn {
        let turn = ExternalSearchTurn(
            plan: plan, context: context, windowTokens: 128_000, rhoHi: 0.5,
            retrievedAt: "2026-10-27T00:00:00Z", requester: requester
        )
        turn.onTelemetry = { _ in }
        return turn
    }

    @Test("Preset service whose key cannot be read: no request is sent, one auth_invalid is recorded, and the error card's primary button is \"Update Key\"; a custom service's key is optional and requests go out as usual")
    func presetWithoutKeyDoesNotSend() async throws {
        let requester = CountingSearchRequester(results: Self.results)
        let turn = Self.turn(plan: try Self.plan(), context: Self.context(try Self.presetTarget(key: nil)), requester: requester)
        let content = await turn.search(query: "Oriveo", count: nil)
        #expect(requester.requestCount == 0)
        #expect(!content.isEmpty)
        let finish = turn.finish(stopped: false)
        let card = try #require(finish.errorCard)
        #expect(card.errorClass == "auth_invalid")
        #expect(card.primaryAction == "update_key")
        #expect(finish.citations.isEmpty)

        // An empty string counts as unreadable.
        let blank = CountingSearchRequester(results: Self.results)
        let blankTurn = Self.turn(plan: try Self.plan(), context: Self.context(try Self.presetTarget(key: "")), requester: blank)
        _ = await blankTurn.search(query: "Oriveo", count: nil)
        #expect(blank.requestCount == 0)

        let customService = SearchTurnService(id: "s-nas", name: "NAS", protocolID: "searxng", custom: true)
        let address = try #require(SearchTransport.parseServiceAddress("https://nas.example/search"))
        let custom = CountingSearchRequester(results: Self.results)
        let customTurn = Self.turn(
            plan: try Self.plan(service: customService),
            context: Self.context(
                .custom(spec: SearchTransport.searxngSpec, address: address, requestPath: "/search", key: nil),
                service: customService
            ),
            requester: custom
        )
        _ = await customTurn.search(query: "Oriveo", count: nil)
        #expect(custom.requestCount == 1)
        #expect(customTurn.finish(stopped: false).errorCard == nil)
    }

    @Test("First leg of a library / MCP loop carrying web_search rejected with 400: hand back to the send task, recompute the plan to use pre-search, no tools attached")
    func libraryAndMcpFirstLegRejectionFallsBackToPresearch() throws {
        let rejected = ToolsRejectedByUpstreamError(
            statusCode: 400, underlying: .upstream(statusCode: 400, detail: "tools unsupported"), legIndex: 0
        )
        let mapped = try #require(ChatManager.externalSearchToolsRejection(rejected, webSearchRegistered: true))
        #expect(mapped.status == 400)
        #expect(ChatManager.externalSearchToolsRejection(rejected, webSearchRegistered: false) == nil)
        // The criterion looks only at the first leg and the status code: even if structured tool_calls were seen, it is still handed back for recomputation.
        var sawToolCalls = rejected
        sawToolCalls.receivedStructuredToolCalls = true
        #expect(ChatManager.externalSearchToolsRejection(sawToolCalls, webSearchRegistered: true)?.status == 400)
        var laterLeg = rejected
        laterLeg.legIndex = 1
        #expect(ChatManager.externalSearchToolsRejection(laterLeg, webSearchRegistered: true) == nil)

        for (library, mcp) in [(true, false), (false, true), (true, true)] {
            // Only when the connection's tool-call capability is unverified (toolCall = unknown) is it treated as a rejection and switched to pre-search; a verified-supported one reports the error as usual.
            let first = try Self.plan(toolCall: .unknown, library: library, mcp: mcp)
            #expect(first.requestHasWebSearchTool, "library=\(library) mcp=\(mcp)")
            let replanned = try Self.plan(
                toolCall: .unknown, library: library, mcp: mcp, upstreamRejection: SearchUpstreamRejection(status: mapped.status, leg: 0)
            )
            #expect(!replanned.requestHasWebSearchTool, "library=\(library) mcp=\(mcp)")
            #expect(replanned.presearch?.query == "Oriveo 联网搜索", "library=\(library) mcp=\(mcp)")
        }
    }

    @Test("If a first-leg 400 is recognized by the overflow check as context too long: take overflow recovery, not counted as a tools rejection")
    func contextOverflowIsNotToolsRejection() throws {
        let overflowBody = #"{"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#
        let overflow = ToolsRejectedByUpstreamError(
            statusCode: 400, underlying: .upstream(statusCode: 400, detail: overflowBody), legIndex: 0, rawBody: overflowBody
        )
        #expect(ChatManager.toolRejectionIsContextOverflow(overflow, status: 400, family: .openaiChat))
        #expect(ChatManager.externalSearchToolsRejection(overflow, webSearchRegistered: true, family: .openaiChat) == nil)
        let plainBody = #"{"error":{"message":"tools is not supported","type":"invalid_request_error"}}"#
        let plain = ToolsRejectedByUpstreamError(
            statusCode: 400, underlying: .upstream(statusCode: 400, detail: plainBody), legIndex: 0, rawBody: plainBody
        )
        #expect(!ChatManager.toolRejectionIsContextOverflow(plain, status: 400, family: .openaiChat))
        #expect(ChatManager.externalSearchToolsRejection(plain, webSearchRegistered: true, family: .openaiChat)?.status == 400)
    }

    @Test("Internal resend within the turn (overflow / memory downgrade): rebuild from the web sources already produced this turn via reuse, without calling the executor again")
    func internalResendReusesTurnResults() async throws {
        let requester = CountingSearchRequester(results: Self.results)
        let first = Self.turn(plan: try Self.plan(), context: Self.context(try Self.presetTarget(key: "sk-test")), requester: requester)
        let delivered = await first.search(query: "Oriveo", count: nil)
        #expect(delivered.hasPrefix("<oriveo-web"))
        #expect(requester.requestCount == 1)

        let carry = ChatManager.internalResendSearchCarry(turnCitations: first.state.citations, action: .send, previous: [])
        #expect(carry.action == .regenerate)
        #expect(carry.citations.count == Self.results.count)
        #expect(carry.citations.allSatisfy { $0.source == Citation.externalSearchSource })

        let replanned = try Self.plan(
            regenerateAction: carry.action,
            previousResultsPersisted: carry.citations.contains { $0.source == Citation.externalSearchSource }
        )
        #expect(replanned.reuse)
        #expect(!replanned.requestHasWebSearchTool)
        // Internal resend: the reply state continues from the previous attempt, and the [D] envelope is rebuilt on a separate state, so source rows and facts keep this turn's real values.
        let resend = ExternalSearchTurn(plan: replanned, carrying: first, requester: requester)
        resend.onTelemetry = { _ in }
        #expect(resend.carriesPriorAttempt)
        let rebuilt = try #require(resend.reuseEnvelope(carry.citations.compactMap(\.webCitation)))
        #expect(rebuilt == delivered)
        #expect(requester.requestCount == 1)
        let finish = resend.finish(stopped: false)
        #expect(finish.citations.map(\.url) == Self.results.map(\.url))
        #expect(finish.sourcesLine?.reused == false)
        #expect(finish.sourcesLine?.searchCount == 1)
        #expect(finish.facts.searchCount == 1)

        // Reuse when the user taps "Regenerate": the new state is rebuilt from the reuse event, and the source row is marked as reusing the previous search.
        let regenerated = Self.turn(plan: replanned, context: Self.context(try Self.presetTarget(key: "sk-test")), requester: requester)
        _ = try #require(regenerated.reuse(carry.citations.compactMap(\.webCitation)))
        #expect(requester.requestCount == 1)
        #expect(regenerated.finish(stopped: false).sourcesLine?.reused == true)

        // This turn has no web results yet: keep this send's semantics (a re-search stays a re-search).
        let untouched = ChatManager.internalResendSearchCarry(turnCitations: [], action: .reSearch, previous: [])
        #expect(untouched.action == .reSearch)
        #expect(untouched.citations.isEmpty)
    }

    @Test("Reasoning outbound decision: fast / auto / explicit tier / reasoning fields stripped → thinking.on")
    func outboundReasoningDecidesThinking() {
        let automaticKeys = OutboundReasoning.capabilityKeys(requested: .automatic)
        #expect(automaticKeys.keys == Set(["fast", "balanced", "deep", "max"].map { "reasoning_level/\($0)" }))
        #expect(automaticKeys.explicit.isEmpty)
        #expect(OutboundReasoning.capabilityKeys(requested: .deep).explicit == ["reasoning_level/deep"])

        let all: (String) -> Bool = { _ in true }
        // Explicit fast: parameters are sent but it does not count as thinking.
        let fast = OutboundReasoning.selectedMode(requested: .fast, declaredDefault: nil, permits: all)
        #expect(fast == .fast)
        #expect(!OutboundReasoning.thinkingOn(fast))
        // Explicit deep, passes the outbound gate: thinking on.
        let deep = OutboundReasoning.selectedMode(requested: .deep, declaredDefault: nil, permits: all)
        #expect(deep == .deep)
        #expect(OutboundReasoning.thinkingOn(deep))
        // Reasoning fields stripped (negative cache / missing evidence folded into the outbound gate): not sent, thinking off.
        let stripped = OutboundReasoning.selectedMode(
            requested: .deep, declaredDefault: nil, permits: { $0 != "reasoning_level/deep" }
        )
        #expect(stripped == nil)
        #expect(!OutboundReasoning.thinkingOn(stripped))
        // Auto: take the default tier declared by the projection; if none is declared, send nothing.
        let auto = OutboundReasoning.selectedMode(requested: .automatic, declaredDefault: .balanced, permits: all)
        #expect(auto == .balanced)
        #expect(OutboundReasoning.thinkingOn(auto))
        #expect(OutboundReasoning.selectedMode(requested: .automatic, declaredDefault: nil, permits: all) == nil)
        #expect(!OutboundReasoning.thinkingOn(
            OutboundReasoning.selectedMode(requested: .automatic, declaredDefault: .fast, permits: all)
        ))
    }
}
