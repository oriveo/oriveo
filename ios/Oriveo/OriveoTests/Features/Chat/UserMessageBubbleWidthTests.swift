import Testing
import UIKit
@testable import Oriveo

/// The user bubble must hug its content.
///
/// The long-standing cause: hugging was implemented with a filled outer stack, a spacer and a
/// required content-hugging priority on the shadow host - but the shadow host is a plain `UIView`
/// with no intrinsic content size, so content hugging does nothing for it, and the text view's own
/// hugging could not get past the two required equal-width constraints of the filled bubble stack
/// and bubble view. With no shrinking force from either end, a short bubble was always stretched to
/// `maxBubbleWidth`.
///
/// The fix uses explicit constraints (right-aligned to the left of the avatar, with a `leading >=`
/// so the bubble can shrink to the right) and lets the text view's intrinsic width drive the bubble
/// width. This suite pins: short text hugs, long text is capped, and both are right-aligned.
@Suite("User message bubble hugs its content")
@MainActor
struct UserMessageBubbleWidthTests {
    private static let cellWidth: CGFloat = 393
    private static let maxBubbleWidth: CGFloat = 320

    private func makeUserModel(text: String) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .user, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .user,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private func layOutBubble(text: String) -> CGRect {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: Self.cellWidth, height: 100))
        let parent = UIViewController()
        cell.configure(
            model: makeUserModel(text: text),
            maxBubbleWidth: Self.maxBubbleWidth,
            parentViewController: parent
        )
        cell.contentView.frame = CGRect(x: 0, y: 0, width: Self.cellWidth, height: 100)
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: Self.cellWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: Self.cellWidth, height: fit.height)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return cell.bubbleFrameForTesting
    }

    @Test("Short Text Hugs Content")
    func shortTextHugsContent() {
        let frame = layOutBubble(text: "hi")
        #expect(frame.width > 0, "the bubble was never laid out (width = 0)")
        #expect(
            frame.width < 120,
            "the short \"hi\" bubble did not hug its text, width=\(frame.width) (regression: stretched to maxBubbleWidth)"
        )
    }

    @Test("Long Text Caps At Max")
    func longTextCapsAtMax() {
        let long = String(repeating: "long message content ", count: 12)
        let frame = layOutBubble(text: long)
        #expect(frame.width > 260, "the long-text bubble did not fill out, width=\(frame.width)")
        #expect(
            frame.width <= Self.maxBubbleWidth + 0.5,
            "the long-text bubble exceeded maxBubbleWidth, width=\(frame.width)"
        )
    }

    @Test("Bubbles Are Right Aligned")
    func bubblesAreRightAligned() {
        let shortFrame = layOutBubble(text: "hi")
        let longFrame = layOutBubble(text: String(repeating: "word ", count: 30))
        #expect(
            abs(shortFrame.maxX - longFrame.maxX) < 0.5,
            "short and long bubbles do not share a right edge although both are right-aligned: short=\(shortFrame.maxX) long=\(longFrame.maxX)"
        )
        #expect(
            shortFrame.maxX < Self.cellWidth,
            "the bubble's right edge must stay left of the avatar (< cellWidth=\(Self.cellWidth)): \(shortFrame.maxX)"
        )
    }
}
