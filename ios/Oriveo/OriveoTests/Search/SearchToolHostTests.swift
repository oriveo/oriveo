import Foundation
import Testing
@testable import Oriveo

/// Tool host table for ordinary chat (external search services contract): reads the original shared/search-contracts/tool-host.v1.json,
/// calls resolveSearchToolHost and compares expect as a whole by JSON semantics; the continuation step count comes from this platform's continuation table and is checked against the fixture constants.
@Suite("External search tool host")
struct SearchToolHostTests {
    private static let fixturePath = "shared/search-contracts/tool-host.v1.json"

    static func hostInput(_ input: SearchJSON?, path: WebSearchRoute.Path) -> SearchToolHostInput {
        SearchToolHostInput(
            path: path,
            library: input?["library"]?.boolValue == true,
            mcp: input?["mcp"]?.boolValue == true,
            memoryTools: input?["memoryTools"]?.boolValue == true,
            nativeMoonshotLoop: input?["nativeMoonshotLoop"]?.boolValue == true,
            serverMaxSteps: input?["serverMaxSteps"]?.safeIntegerValue,
            continuationKind: input?["continuationKind"]?.stringValue ?? ""
        )
    }

    @Test("Host, tools, step count and circuit breaker match the tool-host cases, and constants match this platform's table")
    func SRCH_HOST_01_cases() throws {
        let fixture = try SearchContractSupport.load(Self.fixturePath)
        let constants = try #require(fixture["constants"])
        #expect(constants["loopLimits"]?["hardCap"]?.safeIntegerValue == SearchToolHosts.loopLimits.hardCap)
        #expect(constants["loopLimits"]?["defaultMaxSteps"]?.safeIntegerValue == SearchToolHosts.loopLimits.defaultMaxSteps)
        for (kind, steps) in constants["continuationMaxSteps"]?.objectValue?.entries ?? [] {
            let local = RequestContinuationKind(rawValue: kind).flatMap { RequestPreferenceResolver.continuationSpecs[$0]?.maxSteps }
            #expect(local == steps.safeIntegerValue, "continuation \(kind)")
        }
        let rules = try #require(constants["thinkingRules"]?.objectValue)
        #expect(Set(rules.keys) == Set(SearchToolHosts.thinkingToolRules.keys))
        for (name, rule) in rules.entries {
            #expect(rule["thinkingWithTools"]?.stringValue == SearchToolHosts.thinkingToolRules[name]?.thinkingWithTools, "\(name)")
            #expect(rule["replay"]?.stringValue == SearchToolHosts.thinkingToolRules[name]?.replay, "\(name)")
        }
        for (name, prompt) in constants["prompts"]?.objectValue?.entries ?? [] {
            #expect(prompt["stoppedErrorCode"]?.stringValue == SearchToolHosts.hostPrompts[name], "prompts \(name)")
        }
        #expect(constants["maxSearchRequestsPerReply"]?.safeIntegerValue == SearchRoute.searchCallLimits.maxSearchRequestsPerReply)

        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseID = testCase["caseId"]?.stringValue ?? "?"
            let input = try #require(testCase["input"])
            let path = try #require(WebSearchRoute.Path(rawValue: input["path"]?.stringValue ?? ""), "\(caseID) path")
            let host = try SearchToolHosts.resolveSearchToolHost(Self.hostInput(input, path: path))
            let json = try SearchContractSupport.json(host)
            #expect(json == testCase["expect"], "\(caseID): \(json.encodedString())")
        }
    }
}
