import Foundation
import OriveoProviderKit
import Testing

// Runs cases of `shared/context-contracts/wire-system.v1.json` case by case: the plan is projected through production ContextWireAdapter.project
// onto the 8 protocol families and compared semantically with expected (key order ignored, strings byte for byte); the test name is wire_<case id>.

private struct WireSystemContract: Decodable {
    struct Block: Decodable {
        var kind: String
        var text: String
    }

    struct Message: Decodable {
        var role: String
        var blocks: [Block]
    }

    struct Plan: Decodable {
        var system: String?
        var messages: [Message]
    }

    struct ToolCall: Decodable {
        var id: String
        var name: String
        var arguments: String
    }

    struct ToolResult: Decodable {
        var callId: String
        var name: String
        var output: String
    }

    struct ToolLeg: Decodable {
        var calls: [ToolCall]
        var results: [ToolResult]
        var notice: String?

        var wireLeg: ContextWireToolLeg {
            ContextWireToolLeg(
                calls: calls.map { ContextWireToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                results: results.map { ContextWireToolResult(callId: $0.callId, name: $0.name, output: $0.output) },
                notice: notice
            )
        }
    }

    struct Case: Decodable {
        var id: String
        var plan: Plan?
        var turns: [Plan]?
        var toolLeg: ToolLeg?
        var expected: ProviderRecipeValue
    }

    var families: [String: String]
    var cases: [Case]

    static func load() throws -> WireSystemContract {
        try ContextContractFixture.load("wire-system.v1.json")
    }

    static func wireCase(_ id: String) throws -> Case {
        try #require(try load().cases.first { $0.id == id }, "\(id)")
    }
}

private extension WireSystemContract.Plan {
    func wirePlan() throws -> ContextWirePlan {
        ContextWirePlan(system: system, messages: try messages.map { message in
            ContextWireMessage(
                role: try #require(ContextMessageRole(rawValue: message.role)),
                blocks: try message.blocks.map { block in
                    ContextWireBlock(kind: try #require(ContextBlockKind(rawValue: block.kind)), text: block.text)
                }
            )
        })
    }
}

private func family(_ raw: String) throws -> ContextWireFamily {
    try #require(ContextWireFamily(rawValue: raw), "\(raw)")
}

private func object(_ value: ProviderRecipeValue?) throws -> [String: ProviderRecipeValue] {
    try #require(value?.objectValue)
}

/// Keys under which each family holds messages.
private func listKey(_ family: ContextWireFamily) -> String {
    switch family {
    case .openaiResponses: "input"
    case .gemini: "contents"
    default: "messages"
    }
}

/// Strip Anthropic cache_control (the assert declaration of two_turn ignores it when comparing).
private func withoutCacheControl(_ value: ProviderRecipeValue) -> ProviderRecipeValue {
    switch value {
    case .object(let object):
        .object(object.filter { $0.key != "cache_control" }.mapValues(withoutCacheControl))
    case .array(let array):
        .array(array.map(withoutCacheControl))
    default:
        value
    }
}

/// Cases whose expectation is "one request-body fragment per family": compare each family's projection with expected.
private func expectEveryFamily(_ caseId: String) throws {
    let item = try WireSystemContract.wireCase(caseId)
    let plan = try #require(item.plan).wirePlan()
    let expected = try object(item.expected)
    #expect(Set(expected.keys) == Set(ContextWireFamily.allCases.map(\.rawValue)), "\(caseId)")
    for (raw, body) in expected {
        let actual = try ContextWireAdapter.project(plan: plan, family: try family(raw))
        #expect(actual == body, "\(caseId) \(raw)")
    }
}

@Suite("ContextContractWireSystem")
struct ContextContractWireSystemTests {
    @Test("families_and_cases")
    func familiesAndCases() throws {
        let contract = try WireSystemContract.load()
        #expect(Set(contract.families.keys) == Set(ContextWireFamily.allCases.map(\.rawValue)))
        #expect(contract.families.count == 8)
        #expect(contract.cases.map(\.id) == [
            "system_history_and_dynamic_block",
            "no_system_field_when_plan_has_none",
            "two_turn_prefix_is_stable",
            "checkpoint_merges_with_first_tail_user",
            "host_loop_notice_after_tool_results",
            "host_loop_leg_bodies",
            "host_loop_leg_bodies_with_dynamic",
        ])
    }

    @Test("wire_system_history_and_dynamic_block")
    func systemHistoryAndDynamicBlock() throws {
        try expectEveryFamily("system_history_and_dynamic_block")
    }

    @Test("wire_no_system_field_when_plan_has_none")
    func noSystemFieldWhenPlanHasNone() throws {
        try expectEveryFamily("no_system_field_when_plan_has_none")
    }

    @Test("wire_checkpoint_merges_with_first_tail_user")
    func checkpointMergesWithFirstTailUser() throws {
        try expectEveryFamily("checkpoint_merges_with_first_tail_user")
    }

    @Test("wire_two_turn_prefix_is_stable")
    func twoTurnPrefixIsStable() throws {
        let item = try WireSystemContract.wireCase("two_turn_prefix_is_stable")
        let turns = try #require(item.turns)
        #expect(turns.count == 2)
        let expected = try object(item.expected)
        #expect(Set(expected.keys) == Set(ContextWireFamily.allCases.map(\.rawValue)))
        let turn1Raw = turns[0]
        // The plan of turn1 with the [D] block removed, used to get the wire shape of "the k-th message of turn1 without [D]".
        let turn1Stripped = WireSystemContract.Plan(
            system: turn1Raw.system,
            messages: turn1Raw.messages.map { message in
                WireSystemContract.Message(role: message.role, blocks: message.blocks.filter { $0.kind != "dynamic" })
            }
        )
        for (raw, bodies) in expected {
            let wireFamily = try family(raw)
            let actual = try turns.map { try ContextWireAdapter.project(plan: $0.wirePlan(), family: wireFamily) }
            #expect(.array(actual) == bodies, "\(raw)")

            // assert: the system carrier is equal across turns; messages before turn1's last user message are equal one by one; that message equals turn1 with [D] removed.
            let key = listKey(wireFamily)
            let first = try object(withoutCacheControl(actual[0]))
            let second = try object(withoutCacheControl(actual[1]))
            #expect(first.filter { $0.key != key } == second.filter { $0.key != key }, "\(raw)")
            let list1 = try #require(first[key]?.arrayValue)
            let list2 = try #require(second[key]?.arrayValue)
            let k = try #require(list1.lastIndex { $0.objectValue?["role"]?.stringValue == "user" }, "\(raw)")
            #expect(Array(list2.prefix(k)) == Array(list1.prefix(k)), "\(raw)")
            let stripped = try object(withoutCacheControl(
                ContextWireAdapter.project(plan: turn1Stripped.wirePlan(), family: wireFamily)
            ))
            #expect(list2[k] == stripped[key]?.arrayValue?[k], "\(raw)")
        }
    }

    @Test("wire_host_loop_notice_after_tool_results")
    func hostLoopNoticeAfterToolResults() throws {
        let item = try WireSystemContract.wireCase("host_loop_notice_after_tool_results")
        let expected = try object(item.expected)
        let all = try object(expected["all"])
        #expect(all["systemEqualsFirstLeg"] == .bool(true))
        #expect(all["noSystemRoleMessagesAdded"] == .bool(true))
        #expect(Set(expected.keys) == Set(ContextWireFamily.allCases.map(\.rawValue) + ["all"]))

        let plan = ContextWirePlan(system: "You are a meticulous editor.", messages: [
            ContextWireMessage(role: .user, blocks: [ContextWireBlock(kind: .text, text: "Weather in Paris?")]),
        ])
        let notice = "Tool step limit reached. Answer the user in text now."
        let leg = ContextWireToolLeg(
            calls: [ContextWireToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Paris"}"#)],
            results: [ContextWireToolResult(callId: "call_1", name: "get_weather", output: #"{"temp_c":18}"#)],
            notice: notice
        )

        for (raw, rule) in expected where raw != "all" {
            let wireFamily = try family(raw)
            let placement = try #require(try object(rule)["noticePlacement"]?.stringValue)
            if wireFamily == .free {
                #expect(placement.hasPrefix("n/a"))
                #expect(throws: ContextWireAdapterError.toolsUnsupported(.free)) {
                    try ContextWireAdapter.project(plan: plan, family: .free, toolLeg: leg)
                }
                continue
            }
            let key = listKey(wireFamily)
            let first = try object(ContextWireAdapter.project(plan: plan, family: wireFamily))
            let second = try object(ContextWireAdapter.project(plan: plan, family: wireFamily, toolLeg: leg))
            #expect(first.filter { $0.key != key } == second.filter { $0.key != key }, "\(raw)")
            let list1 = try #require(first[key]?.arrayValue)
            let list2 = try #require(second[key]?.arrayValue)
            func systemCount(_ list: [ProviderRecipeValue]) -> Int {
                list.filter { $0.objectValue?["role"]?.stringValue == "system" }.count
            }
            #expect(systemCount(list2) == systemCount(list1), "\(raw)")
            // The Anthropic breakpoint moves with the tool leg to the tool_result turn (host_loop_leg_bodies is locked byte for byte), so only the shape is compared here.
            #expect(Array(list2.prefix(list1.count)).map(withoutCacheControl) == list1.map(withoutCacheControl), "\(raw)")

            let items = list2.map { $0.objectValue ?? [:] }
            switch placement {
            case "separate user message right after the last role=tool message":
                let lastTool = try #require(items.lastIndex { $0["role"] == .string("tool") }, "\(raw)")
                #expect(lastTool == items.count - 2, "\(raw)")
                #expect(items.last == ["role": .string("user"), "content": .string(notice)], "\(raw)")
            case "user input item right after the last function_call_output item":
                let lastOutput = try #require(
                    items.lastIndex { $0["type"] == .string("function_call_output") }, "\(raw)"
                )
                #expect(lastOutput == items.count - 2, "\(raw)")
                #expect(items.last == ["role": .string("user"), "content": .string(notice)], "\(raw)")
            case "text block after the tool_result blocks in the same user turn":
                let turn = try #require(items.last)
                #expect(turn["role"] == .string("user"), "\(raw)")
                let blocks = try #require(turn["content"]?.arrayValue).map { withoutCacheControl($0).objectValue ?? [:] }
                #expect(blocks.last == ["type": .string("text"), "text": .string(notice)], "\(raw)")
                #expect(!blocks.dropLast().isEmpty, "\(raw)")
                #expect(blocks.dropLast().allSatisfy { $0["type"] == .string("tool_result") }, "\(raw)")
            case "text part after the functionResponse parts in the same user content":
                let turn = try #require(items.last)
                #expect(turn["role"] == .string("user"), "\(raw)")
                let parts = try #require(turn["parts"]?.arrayValue).map { $0.objectValue ?? [:] }
                #expect(parts.last == ["text": .string(notice)], "\(raw)")
                #expect(!parts.dropLast().isEmpty, "\(raw)")
                #expect(parts.dropLast().allSatisfy { $0["functionResponse"] != nil }, "\(raw)")
            default:
                Issue.record("unknown noticePlacement for \(raw): \(placement)")
            }
        }
    }

    @Test("wire_host_loop_leg_bodies")
    func hostLoopLegBodies() throws {
        try expectLegBodies("host_loop_leg_bodies")
    }

    /// Tool leg whose current user carries [D]: every leg strips [D] from the current user, and the breakpoint is on the tool_result turn.
    @Test("wire_host_loop_leg_bodies_with_dynamic")
    func hostLoopLegBodiesWithDynamic() throws {
        try expectLegBodies("host_loop_leg_bodies_with_dynamic")
    }

    private func expectLegBodies(_ caseId: String) throws {
        let item = try WireSystemContract.wireCase(caseId)
        let plan = try #require(item.plan).wirePlan()
        let leg = try #require(item.toolLeg).wireLeg
        let expected = try object(item.expected)
        #expect(Set(expected.keys) == Set(ContextWireFamily.allCases.map(\.rawValue)))
        for (raw, body) in expected {
            let wireFamily = try family(raw)
            if wireFamily == .free {
                #expect(try object(body)["throws"] == .bool(true))
                #expect(throws: ContextWireAdapterError.toolsUnsupported(.free)) {
                    try ContextWireAdapter.project(plan: plan, family: .free, toolLeg: leg)
                }
                continue
            }
            let actual = try ContextWireAdapter.project(plan: plan, family: wireFamily, toolLeg: leg)
            #expect(actual == body, "\(caseId) \(raw)")
        }
    }

    @Test("empty_plan_throws")
    func emptyPlanThrows() {
        for wireFamily in ContextWireFamily.allCases {
            #expect(throws: ContextWireAdapterError.noMessages) {
                try ContextWireAdapter.project(plan: ContextWirePlan(system: "S", messages: nil), family: wireFamily)
            }
            #expect(throws: ContextWireAdapterError.noMessages) {
                try ContextWireAdapter.project(plan: ContextWirePlan(system: "S", messages: []), family: wireFamily)
            }
        }
    }
}
