import Foundation
import Testing
@testable import Oriveo

@Suite("ChatBubble")
struct ChatBubbleTests {
    @Test("bubble width participates in equality")
    func bubbleWidthParticipatesInEquality() {
        let message = TestFactories.makeMessage(role: .user, text: "hello")

        let baseline = ChatBubble(message: message, maxBubbleWidth: 320)
        let same = ChatBubble(message: message, maxBubbleWidth: 320)
        let differentWidth = ChatBubble(message: message, maxBubbleWidth: 280)

        #expect(baseline == same)
        #expect(baseline != differentWidth)
    }

    @Test("same-length text changes participate in equality")
    func sameLengthTextChangesParticipateInEquality() {
        let baselineMessage = TestFactories.makeMessage(role: .assistant, text: "abcd")
        var updatedMessage = baselineMessage
        updatedMessage.text = "wxyz"

        let baseline = ChatBubble(message: baselineMessage)
        let updated = ChatBubble(message: updatedMessage)

        #expect(baseline != updated)
    }

    @Test("attachment metadata changes participate in equality")
    func attachmentMetadataChangesParticipateInEquality() {
        let attachmentID = UUID()
        let baselineAttachment = Attachment(
            id: attachmentID,
            kind: .image,
            fileName: "image.png",
            mimeType: "image/png",
            localImageID: "local-image"
        )
        let updatedAttachment = Attachment(
            id: attachmentID,
            kind: .image,
            fileName: "image.png",
            mimeType: "image/png",
            localImageID: "local-image-updated"
        )

        var baselineMessage = TestFactories.makeMessage(role: .assistant, text: "image")
        baselineMessage.attachments = [baselineAttachment]
        var updatedMessage = baselineMessage
        updatedMessage.attachments = [updatedAttachment]

        let baseline = ChatBubble(message: baselineMessage)
        let updated = ChatBubble(message: updatedMessage)

        #expect(baseline != updated)
    }

    @Test("retry capability selection participates in equality")
    func retryCapabilitySelectionParticipatesInEquality() {
        let message = TestFactories.makeMessage(role: .assistant, text: "hello")

        let baseline = ChatBubble(
            message: message,
            retryCapabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: true),
            onRetry: {}
        )
        let updated = ChatBubble(
            message: message,
            retryCapabilitySelection: ChatCapabilitySelection(reasoningMode: .deep, webSearchEnabled: false),
            onRetry: {}
        )

        #expect(baseline != updated)
    }
}
