import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Search request stub that returns a fixed batch of results (no network).
private struct FixedSearchRequester: ExternalSearchRequesting {
    var results: [SearchResultItem]

    func run(_ target: ExternalSearchTarget, query: String, count: Int?, otherServices: Int) async -> SearchExecutionReport {
        SearchExecutionReport(outcome: results.isEmpty ? .empty : .results(results), sent: true)
    }
}

/// External search chat presentation mapping: headline → copy key, primaryAction → button and destination, sourcesLine → three segments,
/// switchTo show/hide, regenerate-type buttons only on the last answer, activity row chips.
@Suite("External search chat presentation mapping")
@MainActor
struct ExternalSearchChatPresentationTests {
    private static func card(
        headline: String, primaryAction: String, switchTo: ExternalSearchMessageRecord.SwitchTarget? = nil
    ) -> ExternalSearchMessageRecord.ErrorCard {
        ExternalSearchMessageRecord.ErrorCard(
            errorClass: "x", headline: headline, primaryAction: primaryAction, secondaryAction: switchTo == nil ? nil : "switch_to_other_service",
            serviceId: "s-deepseek", serviceName: "DeepSeek", switchTo: switchTo
        )
    }

    private static func turn(target: ExternalSearchTarget, results: [SearchResultItem]) throws -> ExternalSearchTurn {
        let service = SearchTurnService(id: "s-deepseek", name: "DeepSeek", protocolID: "catalog", custom: false)
        let plan = try SearchTurn.planSearchTurn(SearchTurnPlanInput(
            path: .externalTool, service: service, toolCall: .supported, userText: "q", windowTokens: 128_000, today: "2026-10-27"
        ))
        let turn = ExternalSearchTurn(
            plan: plan,
            context: ExternalSearchServiceContext(
                path: .externalTool, service: service, telemetryServiceID: "deepseek", otherServices: [
                    SearchOtherService(id: "s-tavily", name: "Tavily", isDefault: true),
                ],
                target: target, resultCount: 5, toolCall: .supported
            ),
            windowTokens: 128_000, rhoHi: 0.5, retrievedAt: "2026-10-27T00:00:00Z",
            requester: FixedSearchRequester(results: results)
        )
        turn.onTelemetry = { _ in }
        return turn
    }

    private static func presetTarget(key: String?) throws -> ExternalSearchTarget {
        let catalog = try #require(try SearchContractSupport.load("shared/search-contracts/search_catalog_contract.v1.json")["catalog"])
        let entry = try #require(SearchContractSupport.service("deepseek", in: catalog))
        return .preset(entry: entry, regionId: "cn", boundHost: "api.deepseek.com", withdrawn: false, key: key)
    }

    @Test("headline → chatError.<camelCase> copy key; all nine keys exist in the WebSearch table and carry {name}")
    func headlineMapsToChatErrorKey() {
        let expected = [
            "key_rejected": "chatError.keyRejected", "insufficient_balance": "chatError.insufficientBalance",
            "rate_limited": "chatError.rateLimited", "no_response": "chatError.noResponse",
            "service_error": "chatError.serviceError", "format_mismatch": "chatError.formatMismatch",
            "searxng_json_disabled": "chatError.searxngJsonDisabled", "host_changed": "chatError.hostChanged",
            "service_withdrawn": "chatError.serviceWithdrawn",
        ]
        for (headline, key) in expected {
            let presentation = SearchErrorCardPresentation.make(
                card: Self.card(headline: headline, primaryAction: "retry"), isLastAssistant: true
            )
            #expect(presentation.titleKey == key)
            let raw = L10n.tr("webSearch.\(key)", table: .webSearch)
            #expect(raw != "webSearch.\(key)", "missing copy \(key)")
            #expect(presentation.title.contains("DeepSeek"), "\(key) did not substitute the service name")
            #expect(!presentation.title.contains("%"))
        }
        #expect(SearchErrorCardPresentation.make(card: Self.card(headline: "no_response", primaryAction: "retry"), isLastAssistant: true)
            .detailKey == "chat.errorDetail")
        // An unknown headline falls back to the service_error title (same on all platforms).
        #expect(SearchErrorCardPresentation.make(card: Self.card(headline: "brand_new", primaryAction: "retry"), isLastAssistant: true)
            .titleKey == "chatError.serviceError")
    }

    @Test("primaryAction → button key, action and external-link icon; retry types only on the last answer")
    func primaryActionMapping() {
        let cases: [(String, String, ExternalSearchCardAction, Bool)] = [
            ("update_key", "action.updateKey", .updateKey(serviceID: "s-deepseek"), false),
            ("top_up", "action.topUp", .topUp(serviceID: "s-deepseek"), true),
            ("retry", "action.retry", .retry, false),
            ("retry_later", "action.retry", .retry, false),
            ("switch_service", "action.switchService", .switchService, false),
            ("check_settings", "action.checkSettings", .checkSettings(serviceID: "s-deepseek"), false),
            ("view_setup_guide", "action.viewSetupGuide", .viewSetupGuide, true),
            ("reconfirm", "action.reconfirm", .reconfirm(serviceID: "s-deepseek"), false),
        ]
        for (raw, key, action, external) in cases {
            let last = SearchErrorCardPresentation.make(card: Self.card(headline: "service_error", primaryAction: raw), isLastAssistant: true)
            #expect(last.primary?.titleKey == key, "\(raw)")
            #expect(last.primary?.action == action, "\(raw)")
            #expect(last.primary?.external == external, "\(raw)")
            let old = SearchErrorCardPresentation.make(card: Self.card(headline: "service_error", primaryAction: raw), isLastAssistant: false)
            #expect((old.primary == nil) == action.regenerates, "old messages keep only jump types: \(raw)")
        }
    }

    @Test("non-empty switchTo → secondary button \"Answer again with X\", only on the last message; none when empty")
    func secondaryAnswerWith() {
        let target = ExternalSearchMessageRecord.SwitchTarget(id: "s-tavily", name: "Tavily")
        let last = SearchErrorCardPresentation.make(
            card: Self.card(headline: "insufficient_balance", primaryAction: "top_up", switchTo: target), isLastAssistant: true
        )
        #expect(last.secondary?.titleKey == "action.answerWith")
        #expect(last.secondary?.action == .answerWith(serviceID: "s-tavily", name: "Tavily"))
        #expect(last.secondary?.title.contains("Tavily") == true)
        let old = SearchErrorCardPresentation.make(
            card: Self.card(headline: "insufficient_balance", primaryAction: "top_up", switchTo: target), isLastAssistant: false
        )
        #expect(old.secondary == nil)
        // The replacement service no longer exists locally: no secondary button.
        #expect(SearchErrorCardPresentation.make(
            card: Self.card(headline: "insufficient_balance", primaryAction: "top_up", switchTo: target),
            isLastAssistant: true, switchTargetExists: { $0 != "s-tavily" }
        ).secondary == nil)
        #expect(old.primary?.action == .topUp(serviceID: "s-deepseek"))
        #expect(SearchErrorCardPresentation.make(
            card: Self.card(headline: "no_response", primaryAction: "retry"), isLastAssistant: true
        ).secondary == nil)
    }

    @Test("action destinations: when the service no longer exists locally, jump types open the \"Web search\" settings page; top-up goes to the pricing page; switch service opens the search method")
    func routeResolution() throws {
        #expect(ExternalSearchChatRoute.resolve(.updateKey(serviceID: "s1"), serviceExists: true, pricingURL: nil)
            == .updateKey(serviceID: "s1"))
        #expect(ExternalSearchChatRoute.resolve(.checkSettings(serviceID: "s1"), serviceExists: true, pricingURL: nil)
            == .editCustomService(serviceID: "s1"))
        #expect(ExternalSearchChatRoute.resolve(.reconfirm(serviceID: "s1"), serviceExists: true, pricingURL: nil)
            == .serviceDetail(serviceID: "s1"))
        #expect(ExternalSearchChatRoute.resolve(.answerWith(serviceID: "s2", name: "Tavily"), serviceExists: false, pricingURL: nil)
            == .webSearchSettings)
        for action: ExternalSearchCardAction in [.updateKey(serviceID: "s1"), .checkSettings(serviceID: "s1"), .reconfirm(serviceID: "s1"), .topUp(serviceID: "s1")] {
            #expect(ExternalSearchChatRoute.resolve(action, serviceExists: false, pricingURL: "https://x.example/p") == .webSearchSettings)
        }
        let pricing = try #require(URL(string: "https://platform.deepseek.com/pricing"))
        #expect(ExternalSearchChatRoute.resolve(.topUp(serviceID: "s1"), serviceExists: true, pricingURL: pricing.absoluteString) == .openURL(pricing))
        #expect(ExternalSearchChatRoute.resolve(.viewSetupGuide, serviceExists: false, pricingURL: nil)
            == .openURL(try #require(URL(string: SearchSettings.searxngSetupGuideUrl))))
        #expect(ExternalSearchChatRoute.resolve(.switchService, serviceExists: true, pricingURL: nil) == .searchSource)
        #expect(ExternalSearchChatRoute.resolve(.retry, serviceExists: false, pricingURL: nil) == .regenerateWithSearch)
        #expect(ExternalSearchChatRoute.resolve(.answerWith(serviceID: "s2", name: "Tavily"), serviceExists: true, pricingURL: nil)
            == .pickServiceAndRegenerate(serviceID: "s2", name: "Tavily"))
    }

    @Test("sourcesLine → three segments: Searched N times / Reused the previous search · service name [custom] · N sources / none found (not expandable at 0)")
    func sourcesHeaderSegments() {
        let searched = SearchSourcesHeaderPresentation.make(.init(
            searchCount: 2, serviceName: "NAS", sourceCount: 5, reused: false, custom: true
        ))
        #expect(searched.lead == .searched(count: 2))
        #expect(searched.count == .sources(5))
        #expect(searched.showsCustomBadge)
        #expect(searched.expandable)
        #expect(searched.customBadgeText != nil)
        for text in [searched.leadText, searched.countText] {
            #expect(!text.isEmpty && !text.contains("%") && !text.contains("webSearch."))
        }
        let reused = SearchSourcesHeaderPresentation.make(.init(
            searchCount: 1, serviceName: "DeepSeek", sourceCount: 0, reused: true, custom: false
        ))
        #expect(reused.lead == .reused)
        #expect(reused.count == .none)
        #expect(!reused.expandable)
        #expect(reused.customBadgeText == nil)
        #expect(reused.leadText == L10n.tr("webSearch.chat.reusedSearch", table: .webSearch))
        #expect(reused.countText == L10n.tr("webSearch.chat.noSources", table: .webSearch))
    }

    @Test("production path: one search with two results → persisted sourcesLine → title \"Searched 1 time · DeepSeek · 2 sources\", menu gains \"Search again\"")
    func productionFinishFeedsSourcesHeader() async throws {
        let turn = try Self.turn(target: try Self.presetTarget(key: "sk-test"), results: [
            SearchResultItem(title: "A", url: "https://a.example/1", snippet: "a", site: nil, date: nil),
            SearchResultItem(title: "B", url: "https://b.example/2", snippet: "b", site: nil, date: nil),
        ])
        _ = await turn.search(query: "Oriveo", count: nil)
        var message = TestFactories.makeMessage(role: .assistant, text: "Answer [1][2]")
        ChatManager.applyExternalSearchFinish(turn.finish(stopped: false), serviceID: "s-deepseek", to: &message)
        let header = try #require(ExternalSearchChatPresentation.sourcesHeader(message))
        #expect(header == SearchSourcesHeaderPresentation(
            lead: .searched(count: 1), serviceName: "DeepSeek", showsCustomBadge: false, count: .sources(2)
        ))
        #expect(ExternalSearchChatPresentation.errorCard(message, isLastAssistant: true) == nil)
        #expect(ExternalSearchChatPresentation.offersRegenerateWithSearch(message))
        #expect(!ExternalSearchChatPresentation.offersRegenerateWithSearch(TestFactories.makeMessage(role: .assistant, text: "x")))

        // Persist and read back: sourcesLine is stored and loaded with capabilityExecution.
        let encoded = RecordMappers.encodeCapabilityExecution(message.capabilityExecution)
        #expect(RecordMappers.decodeCapabilityExecution(encoded)?.externalSearch?.sourcesLine
            == message.capabilityExecution?.externalSearch?.sourcesLine)
    }

    @Test("production path: preset missing key → error card \"DeepSeek rejected this Key\" + \"Update Key\"; with another service, \"Answer again with Tavily\"")
    func productionErrorCard() async throws {
        let turn = try Self.turn(target: try Self.presetTarget(key: nil), results: [])
        _ = await turn.search(query: "Oriveo", count: nil)
        var message = TestFactories.makeMessage(role: .assistant, text: "Answer")
        ChatManager.applyExternalSearchFinish(turn.finish(stopped: false), serviceID: "s-deepseek", to: &message)
        let card = try #require(ExternalSearchChatPresentation.errorCard(message, isLastAssistant: true))
        #expect(card.titleKey == "chatError.keyRejected")
        #expect(card.primary?.action == .updateKey(serviceID: "s-deepseek"))
        #expect(card.secondary?.action == .answerWith(serviceID: "s-tavily", name: "Tavily"))
        #expect(ExternalSearchChatPresentation.sourcesHeader(message) == nil)
    }

    @Test("rejection falls back to pre-search: persisted notice == tools_rejected → reply notice row; old records without sourcesLine still decode")
    func toolsRejectedNoticeAndLegacyDecode() throws {
        var message = TestFactories.makeMessage(role: .assistant, text: "Answer")
        message.capabilityExecution = CapabilityExecutionResult(
            states: [:], recoveryDescriptors: nil,
            externalSearch: ExternalSearchMessageRecord(
                facts: .init(state: "observed", searchCount: 1, sourceCount: 1), notice: "tools_rejected"
            )
        )
        #expect(ExternalSearchChatPresentation.replyNotice(message) == .searchToolsRejected)
        #expect(AssistantMessageCell.replyNoticeText(.searchToolsRejected)
            == L10n.tr("webSearch.chat.toolsRejectedNotice", table: .webSearch))
        #expect(ExternalSearchChatPresentation.replyNotice(TestFactories.makeMessage(role: .assistant, text: "x")) == nil)

        let legacy = Data(#"{"facts":{"state":"observed","searchCount":1,"sourceCount":2}}"#.utf8)
        let decoded = try JSONDecoder().decode(ExternalSearchMessageRecord.self, from: legacy)
        #expect(decoded.sourcesLine == nil)
        #expect(decoded.facts.sourceCount == 2)
    }

    @Test("activity row: send appends a chip and marks it in flight, retry does not duplicate, at most 3; after deliver the copy becomes \"Answering from search results\"; chip takes the first line, at most 40 characters")
    func activityTrail() {
        var trail = ExternalSearchActivityTrail(serviceName: "DeepSeek")
        trail.send(serviceName: "DeepSeek", query: "a")
        trail.send(serviceName: "DeepSeek", query: "a")
        #expect(trail.queries == ["a"])
        #expect(trail.inFlight)
        #expect(trail.caption == WebSearchCopy.format("chat.searching", "DeepSeek"))
        #expect(trail.caption.contains("DeepSeek"))
        trail.deliver()
        #expect(!trail.inFlight)
        #expect(trail.caption == L10n.tr("webSearch.chat.answeringFromResults", table: .webSearch))
        for query in ["b", "c", "d"] {
            trail.send(serviceName: "DeepSeek", query: query)
            trail.deliver()
        }
        #expect(trail.queries == ["b", "c", "d"])

        let long = String(repeating: "x", count: 45) + "\nsecond line"
        #expect(ExternalSearchActivityTrail.chipText(long) == String(repeating: "x", count: 40) + "…")
        #expect(ExternalSearchActivityTrail.chipText("  short  \nmore") == "short")
        #expect(ExternalSearchActivityTrail.chipText("\n   \n  second line is the query  \nthird line") == "second line is the query")
        // Truncate by grapheme: a composed emoji counts as one.
        let family = String(repeating: "👨‍👩‍👧", count: 41)
        #expect(ExternalSearchActivityTrail.chipText(family) == String(repeating: "👨‍👩‍👧", count: 40) + "…")
    }

    @Test("source card holds only external_search sources; other sources still go through the normal citation block")
    func sourcesCardOnlyHoldsWebSources() {
        let web = Citation(url: "https://a.example/1", title: "A", index: 2, source: Citation.externalSearchSource)
        let library = Citation(url: "https://www.notion.so/doc", title: "Doc", index: 1, source: "notion")
        let mcp = Citation(url: "https://mcp.example/x", title: "M", index: 3, source: "mcp")
        let split = CitationsBlock.splitSearchSources([library, web, mcp])
        #expect(split.web == [web])
        #expect(split.others == [library, mcp])
    }

    @Test("chip view: the in-flight one shows a spinner, the count follows the queries; the error card view gives buttons per presentation")
    func chipsAndCardViews() {
        let chips = UIKitSearchQueryChips()
        var trail = ExternalSearchActivityTrail(serviceName: "DeepSeek")
        trail.send(serviceName: "DeepSeek", query: "a")
        #expect(chips.apply(trail))
        #expect(chips._testChipCount == 1)
        #expect(!chips.apply(trail))

        let card = UIKitSearchErrorCard()
        let presentation = SearchErrorCardPresentation.make(
            card: Self.card(headline: "insufficient_balance", primaryAction: "top_up",
                            switchTo: .init(id: "s-tavily", name: "Tavily")),
            isLastAssistant: true
        )
        card.apply(presentation)
        #expect(!card.isHidden)
        #expect(card._testPrimaryTitle == WebSearchCopy.tr("action.topUp"))
        #expect(card._testSecondaryTitle?.contains("Tavily") == true)
        card.apply(nil)
        #expect(card.isHidden)
    }
}
