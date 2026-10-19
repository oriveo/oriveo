import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/sanitize.v1.json` case by case: inputs are mapped to ProviderKit's ContextMessage,
// run through production ContextSanitizer.sanitize and compared byte for byte; the test name is the fixture case id.

private struct SanitizeContract: Decodable {
    struct Attachment: Decodable {
        var id: String
        var kind: String
    }

    struct Message: Decodable {
        var id: String
        var role: String
        var text: String
        var state: String
        var attachments: [Attachment]?
    }

    struct Input: Decodable {
        var messages: [Message]
        var keepAssistantId: String?
    }

    struct Expected: Decodable {
        var id: String
        var role: String
        var text: String
        var attachments: [String]
    }

    struct Case: Decodable {
        var id: String
        var input: Input
        var expected: [Expected]
    }

    struct Envelope: Decodable {
        var tag: String
        var note: String
    }

    var unansweredEnvelope: Envelope
    var cases: [Case]

    static func load() throws -> SanitizeContract {
        try ContextContractFixture.load("sanitize.v1.json")
    }

    static let caseIds: [String] = (try? load())?.cases.map(\.id) ?? []
}

private func contextMessage(_ message: SanitizeContract.Message, caseId: String) throws -> ContextMessage {
    let role = try #require(ContextMessageRole(rawValue: message.role), "\(caseId)")
    let state = try #require(ContextMessageState(rawValue: message.state), "\(caseId)")
    let attachments = try (message.attachments ?? []).map { attachment in
        let kind = try #require(ContextAttachmentKind(rawValue: attachment.kind), "\(caseId)")
        return ContextAttachmentRef(id: attachment.id, kind: kind)
    }
    return ContextMessage(id: message.id, role: role, text: message.text, state: state, attachments: attachments)
}

@Suite("ContextContractSanitize")
struct ContextContractSanitizeTests {
    @Test("unansweredEnvelope")
    func unansweredEnvelope() throws {
        let contract = try SanitizeContract.load()
        #expect(SanitizeContract.caseIds.count == 11)
        #expect(ContextSanitizer.unansweredTag == contract.unansweredEnvelope.tag)
        #expect(Array(ContextSanitizer.unansweredNote.utf8) == Array(contract.unansweredEnvelope.note.utf8))
    }

    @Test(arguments: SanitizeContract.caseIds)
    func sanitizeCase(_ caseId: String) throws {
        let contract = try SanitizeContract.load()
        let item = try #require(contract.cases.first { $0.id == caseId })
        let input = try item.input.messages.map { try contextMessage($0, caseId: caseId) }
        let actual = ContextSanitizer.sanitize(input, keepAssistantId: item.input.keepAssistantId)

        #expect(actual.count == item.expected.count, "\(caseId): count")
        for (index, (message, expected)) in zip(actual, item.expected).enumerated() {
            #expect(message.id == expected.id, "\(caseId)[\(index)]: id")
            #expect(message.role.rawValue == expected.role, "\(caseId)[\(index)]: role")
            #expect(Array(message.text.utf8) == Array(expected.text.utf8), "\(caseId)[\(index)]: text \(message.text)")
            #expect(message.attachments.map(\.id) == expected.attachments, "\(caseId)[\(index)]: attachments")
        }
    }
}
