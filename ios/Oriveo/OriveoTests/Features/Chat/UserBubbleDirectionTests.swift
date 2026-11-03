import Foundation
import Testing
import UIKit
@testable import Oriveo

/// User content (bubble text) is laid out in its own direction,
/// paragraph by paragraph, regardless of the UI direction. The bubble's screen side is not covered here.
@Suite("User content direction", .serialized)
@MainActor
struct UserBubbleDirectionTests {
    static let english = "Please summarize this article for me."
    /// Arabic sample, kept as escapes (test sources stay ASCII).
    static let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}"

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

    private func find<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let found = view as? T, match(found) { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview, where: match) { return found }
        }
        return nil
    }

    /// Lays out a user bubble in a right-to-left interface and returns its text storage.
    private func rtlBubbleStorage(_ text: String) throws -> NSTextStorage {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 430, height: 100))
        cell.semanticContentAttribute = .forceRightToLeft
        cell.contentView.semanticContentAttribute = .forceRightToLeft
        cell.traitOverrides.layoutDirection = .rightToLeft
        cell.configure(
            model: makeUserModel(text: text),
            maxBubbleWidth: 320, parentViewController: UIViewController()
        )
        cell.contentView.frame = CGRect(x: 0, y: 0, width: 430, height: 100)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return try #require(find(ChatPassiveTextView.self, in: cell)).textStorage
    }

    private func directions(in storage: NSAttributedString) -> [NSWritingDirection] {
        let text = storage.string as NSString
        var result: [NSWritingDirection] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            result.append(style?.baseWritingDirection ?? .natural)
            location = NSMaxRange(paragraph)
        }
        return result
    }

    @Test("English paragraph in an RTL interface is left-to-right")
    func englishInRTLIsLeftToRight() throws {
        let storage = try rtlBubbleStorage(Self.english)
        #expect(directions(in: storage) == [.leftToRight])
    }

    @Test("Arabic paragraph is right-to-left")
    func arabicIsRightToLeft() throws {
        let storage = try rtlBubbleStorage(Self.arabic)
        #expect(directions(in: storage) == [.rightToLeft])
    }

    @Test("Mixed paragraphs are judged one by one; neutral-only paragraphs stay natural")
    func mixedParagraphsJudgedEach() throws {
        let storage = try rtlBubbleStorage("\(Self.english)\n\(Self.arabic)\n123 !\n\u{0661}\u{0662} \(Self.english)")
        #expect(directions(in: storage) == [.leftToRight, .rightToLeft, .natural, .leftToRight])
    }
}
