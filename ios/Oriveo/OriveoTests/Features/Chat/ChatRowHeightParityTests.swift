import Testing
import UIKit
@testable import Oriveo

/// Reconciles `estimatedRowHeight` against the height a real cell actually self-sizes to.
///
/// ## Why this suite exists
///
/// `estimatedRowHeight` is a second layout implementation running in parallel with the cell, kept
/// in step by hand. That has failed repeatedly, always in the same shape - the cell grows a new
/// component and the estimate does not know about it:
///
/// - an image attachment was not counted (estimate about 44 against a real 600), producing huge
///   gaps and overlapping images;
/// - the recovery card was not counted (estimate 44 against a real 300+), the same symptom;
/// - the code block preview cap was not counted (estimate about 4400 against a real 436), while the
///   header, reasoning block, citations block and research progress rows were all under-counted in
///   the other direction, inflating the reported content height of a 62-row conversation to about
///   four times its real value.
///
/// Pure-function assertions cannot catch that: they only know what the estimate says, not what the
/// cell renders. This suite is the only thing that pins the invariant that actually matters -
/// estimate is close to reality - by measuring a real cell with `systemLayoutSizeFitting`. A new
/// component that the cell renders and the estimate ignores turns this red immediately, with no one
/// having to remember to keep the two in step.
///
/// Both sides take their input through the same production projection (`makeRows` then
/// `makeSnapshotPlan`) rather than synthesising their own objects.
///
/// ## After changing the layout
///
/// Look at the ratios printed on failure first, then revisit the measured calibration constants
/// next to `estimatedRowHeight`. Do not derive those constants from the font size: the measured body
/// line height is 26 rather than the bare line height of a 16pt font, and a code line occupies a
/// measured 33.4 rather than the 16.7 of a 14pt monospaced font; the difference is the paragraph
/// spacing the renderer adds.
@Suite("Row height estimate parity with real cells")
@MainActor
struct ChatRowHeightParityTests {
    private static let width: CGFloat = 393

    private static let strictBand: ClosedRange<CGFloat> = 0.88...1.12
    private static let userBand: ClosedRange<CGFloat> = 0.88...1.20
    private static let recoveryBand: ClosedRange<CGFloat> = 0.75...1.40


    private static func naturalHeight(of cell: UICollectionViewCell) -> CGFloat {
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

    private static func projection(
        _ message: ChatMessage
    ) -> (row: ChatCollectionProjectionBuilder.MessageRow,
          model: ChatCollectionProjectionBuilder.MessageRenderModel)? {
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty)
        let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(
            from: rows, providerMetadataVersion: 0
        )
        guard let row = rows.first, let model = plan.renderModelsByID[message.id] else { return nil }
        return (row, model)
    }

    private static func measureAssistant(_ message: ChatMessage) -> (estimated: CGFloat, real: CGFloat) {
        guard let (row, model) = projection(message) else { return (0, 0) }
        let estimated = ChatListViewController.estimatedRowHeight(for: row, width: width)
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        cell.configure(
            model: model,
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        if let config = AssistantMessageRecoveryBuilder.makeConfig(
            for: model,
            isSendingMessage: false,
            isDismissed: false,
            isTechnicalDetailExpanded: false,
            onRetry: {}, onContinue: {}, onRegenerate: {},
            onEditMessage: {}, onSwitchModelRequested: {},
            onDismiss: {}, onTechnicalDetailVisibilityChanged: { _ in }
        ) {
            cell.embedRecoveryCard(config)
        }
        cell.frame = CGRect(x: 0, y: 0, width: width, height: naturalHeight(of: cell))
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return (estimated, naturalHeight(of: cell))
    }

    private static func measureUser(_ message: ChatMessage) -> (estimated: CGFloat, real: CGFloat) {
        guard let (row, model) = projection(message) else { return (0, 0) }
        let estimated = ChatListViewController.estimatedRowHeight(for: row, width: width)
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        cell.configure(
            model: model,
            maxBubbleWidth: ChatListViewController.userBubbleMaxWidth,
            parentViewController: UIViewController(),
            onSaveNote: {},
            onSaveSelection: { _ in },
            onAskSelection: { _ in },
            onOpenNoteReferences: nil
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: naturalHeight(of: cell))
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return (estimated, naturalHeight(of: cell))
    }


    private static func assistant(
        text: String = "",
        reasoning: String? = nil,
        citations: [Citation]? = nil,
        attachments: [Oriveo.Attachment]? = nil,
        state: ChatMessageState = .delivered
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .assistant, text: text, reasoningText: reasoning,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0.01, state: state,
            attachments: attachments, citations: citations
        )
    }

    private static func user(text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .user, text: text,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered
        )
    }

    private static func failedWithRecoveryCard() -> ChatMessage {
        ChatMessage(
            id: UUID(), role: .assistant, text: "",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .failed,
            errorTitle: "Send Failed",
            errorDetail: "HTTP 429 rate limited"
        )
    }

    private static func citation(_ i: Int) -> Citation {
        Citation(
            url: "https://example\(i).com/article",
            title: "あいうえおか \(i)", snippet: nil, faviconUrl: nil, index: i
        )
    }

    private static func imageAttachment() -> Oriveo.Attachment {
        Oriveo.Attachment(id: UUID(), kind: .image, fileName: "a.png", mimeType: "image/png")
    }

    private static func assertParity(
        _ cases: [(String, ChatMessage)],
        band: ClosedRange<CGFloat>,
        measure: (ChatMessage) -> (estimated: CGFloat, real: CGFloat)
    ) {
        var report: [String] = []
        var failures: [String] = []
        for (label, message) in cases {
            let m = measure(message)
            let ratio = m.real > 0 ? m.estimated / m.real : 0
            report.append("[PARITY] \(label) | est=\(Int(m.estimated)) real=\(Int(m.real)) "
                + "ratio=\(String(format: "%.2f", ratio))")
            if !band.contains(ratio) {
                failures.append("\(label): ratio=\(String(format: "%.2f", ratio)) "
                    + "(est=\(Int(m.estimated)) real=\(Int(m.real))) outside \(band)")
            }
        }
        print(report.joined(separator: "\n"))
        #expect(failures.isEmpty, Comment(rawValue: """
            The estimate has drifted away from the natural height of a real cell:
            \(failures.joined(separator: "\n"))
            -- if a new component was added to the cell, estimatedRowHeight has to account for its
            height as well; if a layout constant changed, revisit the measured calibration notes.
            """))
    }


    @Test("Assistant Parity")
    func assistantParity() {
        let cjkPara = "このあいのうえについておかします。きくをけこしてからさしします。\n"
        let codeLine = "    let value = compute(input, index)\n"
        let longCodeLine = "    let veryLongVariableNameForWrapping = compute(input, index, extra)\n"
        Self.assertParity([
            ("chrome/empty", Self.assistant()),
            ("text/1 paragraph", Self.assistant(text: cjkPara)),
            ("text/5 paragraphs", Self.assistant(text: String(repeating: cjkPara, count: 5))),
            ("text/20 paragraphs", Self.assistant(text: String(repeating: cjkPara, count: 20))),
            ("text/40 paragraphs", Self.assistant(text: String(repeating: cjkPara, count: 40))),
            ("text/single paragraph, 80 CJK", Self.assistant(text: String(repeating: "あ", count: 80))),
            ("text/single paragraph, 400 CJK", Self.assistant(text: String(repeating: "あ", count: 400))),
            ("text/single paragraph, 800 CJK", Self.assistant(text: String(repeating: "あ", count: 800))),
            ("text/1600 ASCII", Self.assistant(text: String(repeating: "word ", count: 320))),
            ("code/3 lines", Self.assistant(text: "```swift\n" + String(repeating: codeLine, count: 3) + "```")),
            ("code/10 lines", Self.assistant(text: "```swift\n" + String(repeating: codeLine, count: 10) + "```")),
            ("code/20 lines", Self.assistant(text: "```swift\n" + String(repeating: codeLine, count: 20) + "```")),
            ("code/60 lines", Self.assistant(text: "```swift\n" + String(repeating: codeLine, count: 60) + "```")),
            ("code/200 lines", Self.assistant(text: "```swift\n" + String(repeating: codeLine, count: 200) + "```")),
            ("code/10 wrapped long lines", Self.assistant(text: "```swift\n" + String(repeating: longCodeLine, count: 10) + "```")),
            ("reasoning/short", Self.assistant(text: "はい。", reasoning: "かえています。")),
            ("reasoning/long", Self.assistant(text: "はい。", reasoning: String(repeating: "かえています。", count: 200))),
            ("citations/1", Self.assistant(text: "はい。", citations: (1...1).map(Self.citation))),
            ("citations/3", Self.assistant(text: "はい。", citations: (1...3).map(Self.citation))),
            ("citations/5", Self.assistant(text: "はい。", citations: (1...5).map(Self.citation))),
            ("citations/10", Self.assistant(text: "はい。", citations: (1...10).map(Self.citation))),
            ("image/1", Self.assistant(text: "えです。", attachments: [Self.imageAttachment()])),
            ("mixed/text + code + citations", Self.assistant(
                text: String(repeating: cjkPara, count: 3) + "```swift\n" + String(repeating: codeLine, count: 8) + "```\n" + cjkPara,
                citations: (1...3).map(Self.citation)
            )),
            ("mixed/reasoning + citations", Self.assistant(
                text: String(repeating: cjkPara, count: 2),
                reasoning: String(repeating: "かえています。", count: 30),
                citations: (1...4).map(Self.citation)
            )),
        ], band: Self.strictBand, measure: Self.measureAssistant)
    }

    @Test("Recovery Card Parity")
    func recoveryCardParity() {
        Self.assertParity(
            [("recovery card", Self.failedWithRecoveryCard())],
            band: Self.recoveryBand,
            measure: Self.measureAssistant
        )
    }

    @Test("User Parity")
    func userParity() {
        Self.assertParity([
            ("user/short", Self.user(text: "こんにちは")),
            ("user/medium", Self.user(text: String(repeating: "これはしつです。", count: 10))),
            ("user/long", Self.user(text: String(repeating: "これはないしつもです。", count: 40))),
            ("user/long ASCII", Self.user(text: String(repeating: "this is a question ", count: 40))),
            ("user/multi-line", Self.user(text: String(repeating: "ひとつです。\n", count: 12))),
        ], band: Self.userBand, measure: Self.measureUser)
    }


    /// Sentinel for the number of slots a cell has.
    ///
    /// The parity matrix only covers component combinations someone thought of. If a new slot is
    /// added to the cell without a matching case, the assertions above stay green. This turns
    /// "a slot was added" into a detectable event: the count changes, this turns red, and whoever
    /// added the slot has to decide whether it belongs in `estimatedRowHeight` and add a case that
    /// covers it.
    ///
    /// The number itself means nothing; its only job is to make a change visible. Once the new slot
    /// is handled, update it here.
    @Test("Cell Slot Inventory Is Stable")
    func cellSlotInventoryIsStable() {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        guard let (_, model) = Self.projection(Self.assistant(text: "はい。")) else {
            Issue.record("projection failed"); return
        }
        cell.configure(
            model: model,
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: nil,
            onContinue: nil
        )
        let hint = """
            The number of slots in AssistantMessageCell changed. If the new slot takes up height, \
            estimatedRowHeight has to account for it and the ChatRowHeightParityTests matrix needs \
            a case that covers it; update the expected value here once that is done.
            """
        #expect(cell.contentStack.arrangedSubviews.count == Self.expectedContentSlots,
                Comment(rawValue: "contentStack=\(cell.contentStack.arrangedSubviews.count) \(hint)"))
        #expect(cell.bodyStack.arrangedSubviews.count == Self.expectedBodySlots,
                Comment(rawValue: "bodyStack=\(cell.bodyStack.arrangedSubviews.count) \(hint)"))
    }

    private static let expectedContentSlots = 7
    private static let expectedBodySlots = 4
}
