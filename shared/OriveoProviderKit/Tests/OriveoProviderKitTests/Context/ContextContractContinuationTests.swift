import Foundation
import OriveoProviderKit
import Testing

// Runs continuationCases of `shared/context-contracts/wire-system.v1.json` case by case: state is decided by production
// ContextContinuation.decide, then continuationPlan is projected through ContextContinuation.project into
// instructions / previous_response_id / input and compared field by field with expected; the test name is the fixture case id.

private struct ContinuationContract: Decodable {
    struct Message: Decodable {
        var role: String
        var text: String
    }

    struct Plan: Decodable {
        var system: String?
        var history: [Message]
        var current: String
    }

    struct State: Decodable {
        var previousResponseId: String?
        var instructionsMode: String?
        var systemChangedSinceLastLeg: Bool
        var modelChanged: Bool
        var checkpointChanged: Bool
    }

    struct InputItem: Decodable, Equatable {
        var role: String
        var content: String
    }

    struct Expected: Decodable {
        var instructions: String?
        var previous_response_id: String?
        var input: [InputItem]
    }

    struct Case: Decodable {
        var id: String
        var state: State
        var expected: Expected
    }

    var continuationPlan: Plan
    var continuationCases: [Case]

    static func load() throws -> ContinuationContract {
        try ContextContractFixture.load("wire-system.v1.json")
    }

    static let caseIds: [String] = (try? load())?.continuationCases.map(\.id) ?? []
}

@Suite("ContextContractContinuation")
struct ContextContractContinuationTests {
    @Test("caseCount")
    func caseCount() {
        #expect(ContinuationContract.caseIds.count == 6)
    }

    @Test(arguments: ContinuationContract.caseIds)
    func continuationCase(_ caseId: String) throws {
        let contract = try ContinuationContract.load()
        let item = try #require(contract.continuationCases.first { $0.id == caseId })
        let mode: ContextInstructionsMode? = try item.state.instructionsMode.map {
            try #require(ContextInstructionsMode(rawValue: $0), "\(caseId)")
        }
        let state = ContextContinuationState(
            previousResponseId: item.state.previousResponseId,
            instructionsMode: mode,
            systemChangedSinceLastLeg: item.state.systemChangedSinceLastLeg,
            modelChanged: item.state.modelChanged,
            checkpointChanged: item.state.checkpointChanged
        )
        let plan = contract.continuationPlan
        let history = try plan.history.map { message in
            ContextContinuationMessage(
                role: try #require(ContextMessageRole(rawValue: message.role), "\(caseId)"),
                content: message.text
            )
        }
        let request = ContextContinuation.project(
            ContextContinuation.decide(state),
            system: plan.system,
            history: history,
            current: plan.current
        )
        #expect(request.instructions == item.expected.instructions, "\(caseId)")
        #expect(request.previousResponseId == item.expected.previous_response_id, "\(caseId)")
        let input = request.input.map { ContinuationContract.InputItem(role: $0.role.rawValue, content: $0.content) }
        #expect(input == item.expected.input, "\(caseId)")
    }
}
