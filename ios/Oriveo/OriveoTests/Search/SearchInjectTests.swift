import Foundation
import Testing
@testable import Oriveo

/// Injection budget, <oriveo-web> envelope, unified citation numbering, message facts (external search services contract): reads
/// the originals shared/search-contracts/injection-budget.v1.json, citation-allocator.v1.json, result-facts.v1.json,
/// calls the production functions and compares expect as a whole by JSON semantics (an omitted field differs from null), with the envelope compared byte for byte.
@Suite("External search injection budget, envelope, citation numbering and message facts")
struct SearchInjectTests {
    private static let budgetPath = "shared/search-contracts/injection-budget.v1.json"
    private static let citationPath = "shared/search-contracts/citation-allocator.v1.json"
    private static let factsPath = "shared/search-contracts/result-facts.v1.json"

    private static func cases(_ path: String, _ key: String) throws -> [SearchJSON] {
        let cases = try #require(try SearchContractSupport.load(path)[key]?.arrayValue, "fixture missing \(key)")
        #expect(!cases.isEmpty, "\(key) is empty")
        return cases
    }

    private static func caseID(_ testCase: SearchJSON) -> String { testCase["caseId"]?.stringValue ?? "?" }

    private static func expectEqual<T: Encodable>(_ actual: T, _ testCase: SearchJSON) throws {
        let json = try SearchContractSupport.json(actual)
        #expect(json == testCase["expect"], "\(caseID(testCase)): \(json.encodedString())")
    }

    static func results(_ value: SearchJSON?) -> [SearchResultItem] {
        (value?.arrayValue ?? []).map {
            SearchResultItem(
                title: $0["title"]?.stringValue ?? "", url: $0["url"]?.stringValue ?? "",
                snippet: $0["snippet"]?.stringValue ?? "", site: $0["site"]?.stringValue, date: $0["date"]?.stringValue
            )
        }
    }

    @Test("Injection budget matches budgetCases, and constants match the fixture")
    func SRCH_INJ_01_budgetCases() throws {
        let constants = try #require(try SearchContractSupport.load(Self.budgetPath)["constants"])
        #expect(constants["caps"]?["perSearch"]?.safeIntegerValue == SearchInject.caps.perSearch)
        #expect(constants["caps"]?["perReply"]?.safeIntegerValue == SearchInject.caps.perReply)
        #expect(constants["caps"]?["perSearchRatio"]?.numberValue == SearchInject.caps.perSearchRatio)
        #expect(constants["caps"]?["perReplyRatio"]?.numberValue == SearchInject.caps.perReplyRatio)
        #expect(constants["note"]?.stringValue == SearchInject.webEnvelopeNote)
        for testCase in try Self.cases(Self.budgetPath, "budgetCases") {
            try Self.expectEqual(SearchInject.searchInjectionBudget(testCase["input"]?["B"]?.numberValue), testCase)
        }
    }

    @Test("Budget available for the next search matches nextCases")
    func SRCH_INJ_02_nextCases() throws {
        for testCase in try Self.cases(Self.budgetPath, "nextCases") {
            let input = try #require(testCase["input"])
            let budget = SearchInject.budgetForNextSearch(
                windowTokens: input["B"]?.numberValue, usedTokens: input["usedTokens"]?.safeIntegerValue ?? 0
            )
            #expect(SearchJSON.int(Int64(budget)) == testCase["expect"]?["budgetTokens"], "\(Self.caseID(testCase)): \(budget)")
        }
    }

    @Test("Fitting results to the budget matches fitCases, with byte-identical envelopes")
    func SRCH_INJ_03_fitCases() throws {
        for testCase in try Self.cases(Self.budgetPath, "fitCases") {
            let input = try #require(testCase["input"])
            let fit = SearchInject.fitWebResults(
                provider: input["provider"]?.stringValue ?? "",
                query: input["query"]?.stringValue ?? "",
                retrievedAt: input["retrievedAt"]?.stringValue ?? "",
                results: Self.results(input["results"]),
                firstId: try #require(input["firstId"]?.safeIntegerValue),
                budgetTokens: try #require(input["budgetTokens"]?.safeIntegerValue),
                rhoHi: try #require(input["rhoHi"]?.numberValue)
            )
            let envelope = testCase["expect"]?["envelope"]?.stringValue
            #expect(fit.envelope.map { Data($0.utf8) } == envelope.map { Data($0.utf8) }, "\(Self.caseID(testCase)) envelope")
            try Self.expectEqual(fit, testCase)
        }
    }

    @Test("One allocator per message, matching citation-allocator")
    func SRCH_CITE_01_citationCases() throws {
        for testCase in try Self.cases(Self.citationPath, "cases") {
            let batches = (testCase["input"]?["batches"]?.arrayValue ?? []).map { batch in
                SearchCitationBatch(
                    source: batch["source"]?.stringValue ?? "",
                    items: (batch["items"]?.arrayValue ?? []).map {
                        SearchCitationItem(libraryKey: $0["libraryKey"]?.stringValue, url: $0["url"]?.stringValue)
                    }
                )
            }
            try Self.expectEqual(SearchInject.allocateCitations(batches), testCase)
        }
    }

    @Test("Message facts match result-facts")
    func SRCH_FACT_01_factCases() throws {
        let fixture = try SearchContractSupport.load(Self.factsPath)
        if let states = fixture["constants"]?["states"]?.arrayValue {
            #expect(states.compactMap(\.stringValue) == SearchInject.factStates)
        }
        let call = { (value: SearchJSON) in
            SearchFactCall(outcome: value["outcome"]?.stringValue ?? "", delivered: value["delivered"]?.safeIntegerValue)
        }
        for testCase in try Self.cases(Self.factsPath, "cases") {
            let input = try #require(testCase["input"])
            let facts = SearchInject.summarizeSearchFacts(.init(
                path: input["path"]?.stringValue.flatMap(WebSearchRoute.Path.init(rawValue:)),
                webOn: input["webOn"]?.boolValue == true,
                calls: (input["calls"]?.arrayValue ?? []).map(call),
                presearch: input["presearch"].flatMap { $0.isNull ? nil : call($0) },
                serviceName: input["serviceName"]?.stringValue
            ))
            try Self.expectEqual(facts, testCase)
        }
    }
}
