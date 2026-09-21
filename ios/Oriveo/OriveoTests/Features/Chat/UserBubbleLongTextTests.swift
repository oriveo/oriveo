import Testing
import UIKit
@testable import Oriveo

/// Regression lock for very long user bubble text (one unbroken pasted Arabic paragraph used to stall configuring the
/// cell, pinning the sent message to the top and every later remeasure for seconds).
///
/// Two layers of cause: 1. TextKit lays out per paragraph, and cost grows faster than linearly with paragraph length;
/// 2. when a non-scrolling UITextView takes part in Auto Layout, every constraint update pass computes its baseline
/// (set a size → invalidate the whole container → lay out to the last line), so a new cell laid the full text out
/// about 5.5 times just to appear. The fix: the text is laid out by frame from one measurement in a host view (out of
/// the constraint engine), display-only soft breaks, no reset of the whole string when the same message is
/// reconfigured, and measurement at the bubble's real available width. This suite pins machine-independent structure
/// (container geometry changes, storage edits, paragraph lengths, clipping); wall-clock time is never asserted.
@Suite("UserMessageCell - long text lays out within bounds", .serialized)
@MainActor
struct UserBubbleLongTextTests {
    static let arabicSentence = "هذا نص تجريبي طويل باللغة العربية لاختبار أداء التخطيط في فقاعة الرسالة، ويحتوي على كلمات متعددة. "

    static func arabic(utf16: Int) -> String {
        var out = ""
        while out.utf16.count < utf16 { out += arabicSentence }
        return out
    }

    private func makeUserModel(
        id: UUID = UUID(),
        text: String,
        attachments: [Oriveo.Attachment]? = nil
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: id, role: .user, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: attachments, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .user,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private func textView(in view: UIView) -> ChatPassiveTextView? {
        if let found = view as? ChatPassiveTextView { return found }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private final class LayoutCounter: NSObject, NSLayoutManagerDelegate, NSTextStorageDelegate {
        var geometryChanges = 0
        var storageEdits = 0

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            textContainer: NSTextContainer,
            didChangeGeometryFrom oldSize: CGSize
        ) {
            geometryChanges += 1
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            if editedMask.contains(.editedCharacters) { storageEdits += 1 }
        }
    }

    /// The same path as ChatLayout's cell self-sizing: fit the natural height at full width, then lay out at that size.
    private func fitAndLayOut(_ cell: UserMessageCell, width: CGFloat) {
        cell.contentView.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: fit.height)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    private func configure(_ cell: UserMessageCell, _ model: ChatCollectionProjectionBuilder.MessageRenderModel, parent: UIViewController) {
        cell.configure(model: model, maxBubbleWidth: 320, parentViewController: parent)
    }

    @Test("at 393 and 430 pt long text fits the text container and the last lines are never clipped (including the non-hugging attachment branch and mixed scripts)")
    func longTextIsNeverClipped() throws {
        let latin = String(repeating: "A long message line that wraps across the bubble several times. ", count: 50)
        // Arabic with harakat, emoji (including a ZWJ sequence), Thai, Devanagari and kana: font fallback and combining
        // characters both change line heights and wrapping.
        let mixed = String(repeating: "مَرْحَبًا بِكُمْ 👩‍👩‍👧‍👦 สวัสดีครับ नमस्ते दुनिया こんにちは ", count: 60)
        let file = Oriveo.Attachment(id: UUID(), kind: .file, fileName: "notes.txt", mimeType: "text/plain")
        let cases: [(String, [Oriveo.Attachment]?)] = [
            (latin, nil), (Self.arabic(utf16: 3_000), nil), (mixed, nil), (latin, [file]),
        ]
        for width in [CGFloat(393), 430] {
            for (text, attachments) in cases {
                let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
                configure(cell, makeUserModel(text: text, attachments: attachments), parent: UIViewController())
                fitAndLayOut(cell, width: width)
                let tv = try #require(textView(in: cell))
                let manager = tv.layoutManager
                manager.ensureLayout(for: tv.textContainer)
                let laid = manager.characterRange(forGlyphRange: manager.glyphRange(for: tv.textContainer), actualGlyphRange: nil)
                #expect(
                    NSMaxRange(laid) == tv.textStorage.length,
                    "width \(width): the text container only holds \(NSMaxRange(laid)) / \(tv.textStorage.length) characters, the end is clipped"
                )
                let used = manager.usedRect(for: tv.textContainer).height + tv.textContainerInset.top + tv.textContainerInset.bottom
                #expect(used <= tv.bounds.height + 1, "width \(width): the text needs \(used) pt but the view only has \(tv.bounds.height) pt")
                #expect(cell.bubbleFrameForTesting.maxX <= width, "the bubble overflows the cell: \(cell.bubbleFrameForTesting)")
            }
        }
    }

    @Test("a new cell appearing: the text is out of the constraint engine and no longer resizes its container over and over for baselines")
    func freshCellDoesNotResizeTextContainerRepeatedly() throws {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 430, height: 100))
        let counter = LayoutCounter()
        let tv = try #require(textView(in: cell))
        tv.layoutManager.delegate = counter
        configure(cell, makeUserModel(text: Self.arabic(utf16: 20_000)), parent: UIViewController())
        counter.geometryChanges = 0
        fitAndLayOut(cell, width: 430)
        // Counts TextKit container geometry changes: every baseline computation is a "set size + restore" pair.
        // Before the fix one appearance changed the geometry 7 times (two constraint passes x baselines, plus real layout).
        #expect(tv.translatesAutoresizingMaskIntoConstraints, "the text view must be laid out by frame by its host, not by the constraint engine")
        #expect(counter.geometryChanges <= 2, "one appearance should change the container geometry once or twice for the final frame, got \(counter.geometryChanges)")

        // Measuring again at an unchanged size must not touch TextKit.
        counter.geometryChanges = 0
        _ = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 430, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        #expect(counter.geometryChanges == 0, "remeasuring at an unchanged size changed the container geometry \(counter.geometryChanges) times")
    }

    @Test("reconfiguring the same message does not reset the text (a reset lays the full paragraph out again)")
    func reconfigureSameMessageDoesNotResetText() throws {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 430, height: 100))
        let parent = UIViewController()
        let model = makeUserModel(text: Self.arabic(utf16: 8_000))
        configure(cell, model, parent: parent)
        fitAndLayOut(cell, width: 430)
        let tv = try #require(textView(in: cell))
        let counter = LayoutCounter()
        tv.textStorage.delegate = counter
        configure(cell, model, parent: parent)
        #expect(counter.storageEdits == 0, "reconfiguring the same message reset the text \(counter.storageEdits) times")

        // Reused for another message, the content must really change.
        cell.prepareForReuse()
        let other = makeUserModel(text: "short")
        configure(cell, other, parent: parent)
        #expect(tv.textStorage.string == "short")
    }

    @Test("a very long single paragraph: display paragraphs are bounded and keep one direction, copy and selection get the source")
    func softBreaksKeepDirectionAndSource() throws {
        let source = Self.arabic(utf16: 20_000)
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 430, height: 100))
        configure(cell, makeUserModel(text: source), parent: UIViewController())
        fitAndLayOut(cell, width: 430)
        let tv = try #require(textView(in: cell))
        let display = tv.textStorage.string as NSString

        var location = 0
        var chunks = 0
        while location < display.length {
            let paragraph = display.paragraphRange(for: NSRange(location: location, length: 0))
            #expect(paragraph.length <= SoftParagraphBreaks.maxParagraphUTF16 + 1)
            let style = tv.textStorage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.baseWritingDirection == .rightToLeft, "chunk \(chunks) should keep the original paragraph's RTL direction")
            chunks += 1
            location = NSMaxRange(paragraph)
        }
        #expect(chunks > 1, "a 20K single paragraph should be split into several chunks")
        #expect(SoftParagraphBreaks.source(fromDisplay: display as String) == source)

        // No extra blank space: boundingRect switches internal paths on long strings (20K Arabic: 15796 vs the real
        // 11286 pt), and a standalone TextKit stack substitutes fallback fonts eagerly (1.2 pt more per line), so the
        // measurement has to come from a text view of the same class.
        let manager = tv.layoutManager
        manager.ensureLayout(for: tv.textContainer)
        let used = manager.usedRect(for: tv.textContainer).height
        let lineHeight = OriveoTheme.Typography.chatBodyUIFont().lineHeight
        #expect(tv.bounds.height - used < lineHeight * 1.5, "the bubble is \(tv.bounds.height - used) pt taller than its text")

        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("user-bubble-\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        tv.pasteboard = pasteboard
        tv.selectedRange = NSRange(location: 0, length: display.length)
        tv.copy(nil)
        #expect(pasteboard.string == source, "copying a selection must give the source text, without U+2029 soft breaks")
    }

    @Test("paragraphs that are not split keep the natural direction, so ordinary messages lay out exactly as before")
    func shortParagraphsKeepNaturalDirection() throws {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 430, height: 100))
        configure(cell, makeUserModel(text: "١٢٣ hello\nمرحبا بالعالم"), parent: UIViewController())
        fitAndLayOut(cell, width: 430)
        let tv = try #require(textView(in: cell))
        for location in [0, (tv.textStorage.string as NSString).length - 1] {
            let style = tv.textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            #expect((style?.baseWritingDirection ?? .natural) == .natural, "a short paragraph should not get a pinned direction (location \(location))")
        }
    }

    @Test("short text still hugs its content inside the host")
    func shortTextStillHugs() {
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: 100))
        configure(cell, makeUserModel(text: "hi"), parent: UIViewController())
        fitAndLayOut(cell, width: 393)
        #expect(cell.bubbleFrameForTesting.width < 120, "the short text bubble does not hug: \(cell.bubbleFrameForTesting.width)")
        #expect(cell.bubbleFrameForTesting.height >= 36, "unexpected bubble height: \(cell.bubbleFrameForTesting.height)")
    }
}
