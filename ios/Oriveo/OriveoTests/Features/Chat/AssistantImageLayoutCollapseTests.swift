import Combine
import Testing
import UIKit
@testable import Oriveo

/// Layout regression for a finished image generation.
///
/// An image request first lays out an empty generating assistant cell, and the image turns that
/// same cell into a delivered one through `reconfigureItems`. The image has to join the cell's
/// natural height chain on that "add content to an already laid out cell" path, otherwise it
/// overflows onto the user prompt above it while the collection view's content size stays at the
/// old height, leaving the prompt unreachable by scrolling.
@Suite("Assistant image layout after delivery")
@MainActor
struct AssistantImageLayoutCollapseTests {
    private static let width: CGFloat = 393

    private static func model(
        id: UUID,
        state: ChatMessageState,
        attachments: [Oriveo.Attachment]? = nil
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: id,
            role: .assistant,
            text: "",
            providerKind: .gemini,
            providerName: "Google Gemini",
            modelName: "Nano Banana Pro",
            estimatedCost: 0.17,
            state: state,
            attachments: attachments,
            citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id,
            message: message,
            presentationKind: .assistant,
            showMetadata: true,
            resolvedProviderName: "Google Gemini",
            resolvedModelName: "Nano Banana Pro",
            relayKind: nil,
            renderHint: nil,
            topPadding: 16,
            displayText: "",
            textHash: 0,
            isStreaming: state == .generating,
            providerMetadataVersion: 0,
            isLastInConversation: true
        )
    }

    private static func imageAttachment() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .image,
            fileName: "generated.png",
            mimeType: "image/png"
        )
    }

    private static func naturalHeight(of cell: AssistantMessageCell) -> CGFloat {
        let encapsulated = cell.contentView.constraints.filter {
            ($0.identifier ?? "").contains("Encapsulated-Layout-Height")
        }
        encapsulated.forEach { $0.isActive = false }
        defer { encapsulated.forEach { $0.isActive = true } }
        return cell.contentView.systemLayoutSizeFitting(
            CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    @Test("Generated Image Counts Toward Height After Reconfigure")
    func generatedImageCountsTowardHeightAfterReconfigure() throws {
        let id = UUID()
        let cell = AssistantMessageCell(
            frame: CGRect(x: 0, y: 0, width: Self.width, height: 100)
        )
        let parent = UIViewController()

        cell.configure(
            model: Self.model(id: id, state: .generating),
            parentViewController: parent,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        cell.configure(
            model: Self.model(
                id: id,
                state: .delivered,
                attachments: [Self.imageAttachment()]
            ),
            parentViewController: parent,
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )

        let imageView = try #require(cell.attachmentViews.first)
        cell.frame = CGRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: Self.naturalHeight(of: cell)
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let natural = Self.naturalHeight(of: cell)
        cell.frame.size.height = natural
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let imageFrame = imageView.convert(imageView.bounds, to: cell)
        let headerFrame = cell.headerStack.convert(cell.headerStack.bounds, to: cell)
        let metadataFrame = cell.metadataView.convert(cell.metadataView.bounds, to: cell)

        #expect(imageFrame.minY >= headerFrame.maxY,
                Comment(rawValue: "image minY=\(imageFrame.minY) rides up over the header at \(headerFrame.maxY)"))
        #expect(metadataFrame.minY + 0.5 >= imageFrame.maxY,
                Comment(rawValue: "metadata row at \(metadataFrame.minY) overlaps the bottom of the image at \(imageFrame.maxY)"))
        #expect(imageFrame.maxY <= natural + 0.5,
                Comment(rawValue: "image maxY=\(imageFrame.maxY) overflows the natural cell height \(natural)"))
        #expect(natural >= imageFrame.height + headerFrame.height + metadataFrame.height,
                Comment(rawValue: "natural cell height \(natural) does not include the image height \(imageFrame.height)"))
    }
}
