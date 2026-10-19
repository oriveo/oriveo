import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Cross-platform regression lock: a user message in the current turn that sends only images (empty body) is still outbound and carries its attachments.
/// Web once regressed here (the current turn with an empty body was dropped); the iOS projection re-attaches attachments by id and is unaffected, so this case is expected to pass as-is.
extension ContextPipelineTests {

    @Test("image_only_message_reaches_wire")
    func image_only_message_reaches_wire() throws {
        let history = TestFactories.makeMessage(role: .user, text: "Earlier question")
        let historyReply = TestFactories.makeMessage(role: .assistant, text: "Earlier answer")
        let imageAttachment = TestFactories.makeImageAttachment(fileName: "photo.png")
        let imageOnly = TestFactories.makeMessage(role: .user, text: "", attachments: [imageAttachment])
        let generatingID = UUID()
        let generating = TestFactories.makeMessage(id: generatingID, role: .assistant, text: "", state: .generating)

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: true, skillID: nil),
            messages: [history, historyReply, imageOnly, generating],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: generatingID)
        )

        // Production path: ChatRequestBuilder.build -> PlannedChatRequest.transportInput.
        let built = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)
        let transport = built.planned.transportInput(built.requestOptions)

        let lastUser = try #require(transport.messages.last(where: { $0.role == .user }))
        #expect(lastUser.id == imageOnly.id)
        #expect(lastUser.attachments?.count == 1)
        #expect(lastUser.attachments?.first?.fileName == "photo.png")
        // The body is empty; if [D] is present, it is empty once [D] is stripped.
        let dynamic = built.planned.dynamicText
        var body = lastUser.text
        if !dynamic.isEmpty, let range = body.range(of: dynamic) {
            body.removeSubrange(range)
        }
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
