import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract `shared/context-contracts/sanitize.v1.json`: runs each case's input through the
/// production sanitizer and compares it with expected.
@Suite("Context sanitize contract v1")
struct ContextSanitizeContractTests {

    @Test("production envelope note matches the contract verbatim")
    func envelopeNoteMatchesContract() throws {
        let contract = try Self.loadContract()
        #expect(contract.unansweredEnvelope.tag == "oriveo-unanswered")
        #expect(ChatRequestBuilder.unansweredEnvelopeNote == contract.unansweredEnvelope.note)
    }

    @Test("every contract case yields expected through production sanitizeOutbound")
    func everyCaseMatchesExpected() throws {
        let contract = try Self.loadContract()
        #expect(contract.schema == "oriveo.context.sanitize")
        #expect(contract.version == 1)
        #expect(!contract.cases.isEmpty)

        for contractCase in contract.cases {
            // Contract ids are short strings while iOS ids are UUIDs: map them stably per case
            var ids: [String: UUID] = [:]
            func uuid(_ key: String) -> UUID {
                if let existing = ids[key] { return existing }
                let created = UUID()
                ids[key] = created
                return created
            }

            let messages = try contractCase.input.messages.map { input -> ChatMessage in
                let role = try #require(ChatRole(rawValue: input.role), "\(contractCase.id): role \(input.role)")
                let state = try #require(ChatMessageState(rawValue: input.state), "\(contractCase.id): state \(input.state)")
                let attachments = try (input.attachments ?? []).map { attachment -> Oriveo.Attachment in
                    let kind = try #require(AttachmentKind(rawValue: attachment.kind), "\(contractCase.id): kind \(attachment.kind)")
                    return Oriveo.Attachment(
                        id: uuid(attachment.id),
                        kind: kind,
                        fileName: attachment.id,
                        mimeType: kind == .image ? "image/png" : "text/plain"
                    )
                }
                var message = TestFactories.makeMessage(
                    id: uuid(input.id),
                    role: role,
                    text: input.text,
                    state: state
                )
                message.attachments = attachments.isEmpty ? nil : attachments
                return message
            }
            let keepAssistantID = contractCase.input.keepAssistantId.map(uuid)

            let output = ChatRequestBuilder.sanitizeOutbound(messages, keepAssistantID: keepAssistantID)

            var reverse: [UUID: String] = [:]
            for (key, value) in ids { reverse[value] = key }
            #expect(output.count == contractCase.expected.count, "\(contractCase.id): count")
            for (actual, expected) in zip(output, contractCase.expected) {
                #expect(reverse[actual.id] == expected.id, "\(contractCase.id): id")
                #expect(actual.role.rawValue == expected.role, "\(contractCase.id): role")
                #expect(actual.text == expected.text, "\(contractCase.id): text")
                let actualAttachmentIDs: [String] = (actual.attachments ?? []).map { attachment in
                    reverse[attachment.id] ?? "?"
                }
                #expect(actualAttachmentIDs == expected.attachments, "\(contractCase.id): attachments")
            }
        }
    }

    // MARK: - Contract loading

    private struct Contract: Decodable {
        let schema: String
        let version: Int
        let unansweredEnvelope: Envelope
        let cases: [Case]
    }

    private struct Envelope: Decodable {
        let tag: String
        let note: String
    }

    private struct Case: Decodable {
        let id: String
        let input: Input
        let expected: [ExpectedMessage]
    }

    private struct Input: Decodable {
        let messages: [InputMessage]
        let keepAssistantId: String?
    }

    private struct InputMessage: Decodable {
        let id: String
        let role: String
        let text: String
        let state: String
        let attachments: [InputAttachment]?
    }

    private struct InputAttachment: Decodable {
        let id: String
        let kind: String
    }

    private struct ExpectedMessage: Decodable {
        let id: String
        let role: String
        let text: String
        let attachments: [String]
    }

    /// Walks up from the test source location to find `shared/context-contracts/` in the repository,
/// the same way the other cross-platform contract tests locate their fixtures.
    private static func loadContract() throws -> Contract {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent("shared/context-contracts/sanitize.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: candidate))
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
