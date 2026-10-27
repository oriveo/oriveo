import Foundation
import Testing
@testable import Oriveo

/// Execution-side composed entry (external search services contract): reads the original shared/search-contracts/search-turn.v1.json.
/// planCases call planSearchTurn; replyCases first startSearchReply, then applySearchEvent one by one comparing each step's effect, then finishSearchReply
/// compares the finish; recordCases call searchedRecordLine. Everything is compared as a whole by JSON semantics (an omitted field differs from null).
@Suite("External search execution-side composed entry (planning, step by step, finish, history record)")
struct SearchTurnTests {
    private static let fixturePath = "shared/search-contracts/search-turn.v1.json"

    private static func load() throws -> SearchJSON { try SearchContractSupport.load(fixturePath) }

    private static func cases(_ key: String) throws -> [SearchJSON] {
        let cases = try #require(try load()[key]?.arrayValue, "fixture missing \(key)")
        #expect(!cases.isEmpty, "\(key) is empty")
        return cases
    }

    private static func caseID(_ testCase: SearchJSON) -> String { testCase["caseId"]?.stringValue ?? "?" }

    private static func service(_ value: SearchJSON?) -> SearchTurnService? {
        guard let value, !value.isNull else { return nil }
        return SearchTurnService(
            id: value["id"]?.stringValue ?? "", name: value["name"]?.stringValue ?? "",
            protocolID: value["protocol"]?.stringValue ?? "", custom: value["custom"]?.boolValue == true
        )
    }

    private static func items(_ value: SearchJSON?) -> [SearchCitationItem] {
        (value?.arrayValue ?? []).map { SearchCitationItem(libraryKey: $0["libraryKey"]?.stringValue, url: $0["url"]?.stringValue) }
    }

    private static func event(_ value: SearchJSON) throws -> SearchReplyEvent {
        switch value["type"]?.stringValue {
        case "call":
            return .call(query: value["query"]?.stringValue, count: value["count"]?.safeIntegerValue)
        case "result":
            let outcome = try #require(value["outcome"])
            let kind: SearchCallOutcome.Kind
            if let error = outcome["error"], !error.isNull {
                kind = .error(errorClass: error["errorClass"]?.stringValue ?? "", retryOnce: error["retryOnce"]?.boolValue == true)
            } else if let results = outcome["results"], !results.isNull {
                kind = .results(SearchInjectTests.results(results))
            } else {
                #expect(outcome["empty"]?.boolValue == true, "result outcome")
                kind = .empty
            }
            return .result(.init(kind: kind, latencyMs: outcome["latencyMs"]?.safeIntegerValue ?? 0, sent: outcome["sent"]?.boolValue))
        case "reuse":
            return .reuse(query: value["query"]?.stringValue ?? "", results: SearchInjectTests.results(value["results"]))
        case "other_sources":
            return .otherSources(source: value["source"]?.stringValue ?? "", items: items(value["items"]))
        case "stopped":
            return .stopped
        default:
            throw SearchTurnTestError.unknownEvent(value.encodedString())
        }
    }

    private enum SearchTurnTestError: Error { case unknownEvent(String) }

    @Test("Constants match the fixture constants")
    func turnConstants() throws {
        let constants = try #require(try Self.load()["constants"])
        let presearch = (constants["presearchMessages"]?.objectValue?.entries ?? []).reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue }
        #expect(presearch == SearchTurn.presearchMessages)
        let tool = (constants["toolMessages"]?.objectValue?.entries ?? []).reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue }
        #expect(tool == SearchTransport.toolMessages)
        #expect(try SearchContractSupport.json(SearchTurn.webSearchTool) == constants["webSearchTool"])
        #expect(constants["toolsRejectedStatuses"]?.arrayValue?.compactMap(\.safeIntegerValue) == SearchTurn.toolsRejectedStatuses)
        #expect(constants["minSearchBudgetTokens"]?.safeIntegerValue == SearchTurn.minSearchBudgetTokens)
        #expect(constants["resultBuckets"]?.arrayValue?.compactMap(\.stringValue) == SearchTurn.resultBuckets)
        #expect(constants["latencyBuckets"]?.arrayValue?.compactMap(\.stringValue) == SearchTurn.latencyBuckets)
        #expect(constants["maxSearchRequestsPerReply"]?.safeIntegerValue == SearchRoute.searchCallLimits.maxSearchRequestsPerReply)
    }

    @Test("Pre-send planning matches planCases (including the error for an external path with no service)")
    func SRCH_TURN_01_planCases() throws {
        for testCase in try Self.cases("planCases") {
            let id = Self.caseID(testCase)
            let input = try #require(testCase["input"])
            let path = try #require(WebSearchRoute.Path(rawValue: input["path"]?.stringValue ?? ""), "\(id) path")
            let thinking = input["thinking"]
            let rejection = input["upstreamRejection"].flatMap { value -> SearchUpstreamRejection? in
                guard let status = value["status"]?.safeIntegerValue, let leg = value["leg"]?.safeIntegerValue else { return nil }
                return SearchUpstreamRejection(status: status, leg: leg)
            }
            let planInput = SearchTurnPlanInput(
                path: path,
                service: Self.service(input["service"]),
                toolCall: try #require(WebSearchRouteInput.ToolCall(rawValue: input["toolCall"]?.stringValue ?? ""), "\(id) toolCall"),
                host: SearchToolHostTests.hostInput(input["host"], path: path),
                thinking: SearchTurnThinking(
                    on: thinking?["on"]?.boolValue == true,
                    protocolID: thinking?["protocol"]?.stringValue,
                    continuationStateAvailable: thinking?["continuationStateAvailable"]?.boolValue != false
                ),
                upstreamRejection: rejection,
                toolsRejectedBefore: input["toolsRejectedBefore"]?.boolValue == true,
                regenerateAction: try #require(
                    SearchRegenerateAction(rawValue: input["regenerate"]?["action"]?.stringValue ?? "send"), "\(id) action"
                ),
                previousResultsPersisted: input["regenerate"]?["previousResultsPersisted"]?.boolValue == true,
                userText: input["userText"]?.stringValue,
                windowTokens: input["B"]?.numberValue,
                today: input["today"]?.stringValue ?? ""
            )
            let expect = try #require(testCase["expect"])
            if let message = expect["error"]?.stringValue {
                #expect(throws: SearchTurnError.self, "\(id)") { try SearchTurn.planSearchTurn(planInput) }
                do {
                    _ = try SearchTurn.planSearchTurn(planInput)
                } catch let error as SearchTurnError {
                    #expect(error.message == message, "\(id)")
                }
                continue
            }
            let json = try SearchContractSupport.json(try SearchTurn.planSearchTurn(planInput))
            #expect(json == expect, "\(id): \(json.encodedString())")
        }
    }

    @Test("Per-step effects and finish of one reply match replyCases")
    func SRCH_TURN_02_replyCases() throws {
        for testCase in try Self.cases("replyCases") {
            let id = Self.caseID(testCase)
            let start = try #require(testCase["input"]?["start"])
            let plan = start["plan"]
            var state = SearchTurn.startSearchReply(SearchReplyStartInput(
                path: try #require(WebSearchRoute.Path(rawValue: plan?["path"]?.stringValue ?? ""), "\(id) plan.path"),
                fallbackReason: plan?["fallbackReason"]?.stringValue,
                noticeOnce: plan?["noticeOnce"]?.boolValue == true,
                service: try #require(Self.service(start["service"]), "\(id) service"),
                otherServices: (start["otherServices"]?.arrayValue ?? []).map {
                    SearchOtherService(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "", isDefault: $0["isDefault"]?.boolValue == true)
                },
                windowTokens: start["B"]?.numberValue,
                rhoHi: try #require(start["rhoHi"]?.numberValue, "\(id) rhoHi"),
                retrievedAt: start["retrievedAt"]?.stringValue ?? "",
                priorBatches: (start["priorBatches"]?.arrayValue ?? []).map {
                    SearchCitationBatch(source: $0["source"]?.stringValue ?? "", items: Self.items($0["items"]))
                }
            ))
            let events = testCase["input"]?["events"]?.arrayValue ?? []
            let expectedEffects = testCase["expect"]?["effects"]?.arrayValue ?? []
            #expect(events.count == expectedEffects.count, "\(id) effects count")
            for (index, raw) in events.enumerated() {
                let step = try SearchTurn.applySearchEvent(state, try Self.event(raw))
                state = step.state
                let json = try SearchContractSupport.json(step.effect)
                #expect(index < expectedEffects.count && json == expectedEffects[index], "\(id) effect \(index): \(json.encodedString())")
            }
            let finish = try SearchContractSupport.json(SearchTurn.finishSearchReply(state))
            #expect(finish == testCase["expect"]?["finish"], "\(id) finish: \(finish.encodedString())")
        }
    }

    @Test("Compact history message record matches recordCases")
    func SRCH_TURN_03_recordCases() throws {
        for testCase in try Self.cases("recordCases") {
            let citations = (testCase["input"]?["citations"]?.arrayValue ?? []).map {
                SearchWebCitation(
                    number: $0["number"]?.safeIntegerValue ?? 0, source: $0["source"]?.stringValue ?? "",
                    title: $0["title"]?.stringValue ?? "", url: $0["url"]?.stringValue ?? "",
                    snippet: $0["snippet"]?.stringValue ?? "", query: $0["query"]?.stringValue ?? "",
                    serviceId: $0["serviceId"]?.stringValue ?? "", serviceName: $0["serviceName"]?.stringValue ?? "",
                    retrievedAt: $0["retrievedAt"]?.stringValue ?? "", site: $0["site"]?.stringValue, date: $0["date"]?.stringValue
                )
            }
            let line = SearchTurn.searchedRecordLine(citations)
            let expect = testCase["expect"]?["line"]
            #expect((line.map(SearchJSON.string) ?? .null) == expect, "\(Self.caseID(testCase)): \(line ?? "nil")")
        }
    }
}
