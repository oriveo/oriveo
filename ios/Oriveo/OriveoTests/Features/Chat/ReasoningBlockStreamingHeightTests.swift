import Testing
import UIKit
@testable import Oriveo

/// Reproduces - and then rules out - the reasoning block changing height while streaming.
///
/// By design the collapsed streaming `UIKitReasoningBlock` pins its content area to a fixed
/// single-line height, so the block height is constant and the answer below it is not pushed around
/// as reasoning chunks arrive. This suite measures the block's `systemLayoutSizeFitting` height in
/// isolation while CJK reasoning text grows one character at a time and asserts it never changes.
@Suite("Reasoning block height is stable while streaming")
@MainActor
struct ReasoningBlockStreamingHeightTests {
    private static let contentWidth: CGFloat = 332  // 390 − leading26 − trailing22 − decoration2 − spacing8

    private func fittingHeight(_ block: UIKitReasoningBlock) -> CGFloat {
        block.setNeedsLayout()
        block.layoutIfNeeded()
        return block.systemLayoutSizeFitting(
            CGSize(width: Self.contentWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    @Test("Cjk Single Paragraph Height Stable")
    func cjkSingleParagraphHeightStable() {
        let block = UIKitReasoningBlock()
        let full = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんあ"
        let chars = Array(full)
        var heights: [CGFloat] = []
        for n in 1...chars.count {
            let prefix = String(chars.prefix(n))
            block.configure(text: prefix, durationMs: nil, isStreaming: true, hasMainText: false)
            heights.append(fittingHeight(block))
        }
        let distinct = Set(heights.map { ($0 * 2).rounded() / 2 })
        #expect(distinct.count == 1,
                Comment(rawValue: "the height oscillates: distinct=\(distinct.sorted()) heights=\(heights.map { Int($0) })"))
    }

    @Test("Cjk Multi Paragraph Height Stable")
    func cjkMultiParagraphHeightStable() {
        let block = UIKitReasoningBlock()
        let lines = [
            "あいうえおかきくけこさ",
            "しすせそたちつてとなにぬねの",
            "はひふへほまみむめもやゆよらりるれろわをん",
            "まみむめもやゆよらりるれろわをん",
        ]
        var accumulated = ""
        var heights: [CGFloat] = []
        for line in lines {
            let lineChars = Array(line)
            for n in 1...lineChars.count {
                let text = accumulated + String(lineChars.prefix(n))
                block.configure(text: text, durationMs: nil, isStreaming: true, hasMainText: false)
                heights.append(fittingHeight(block))
            }
            accumulated += line + "\n"
        }
        let distinct = Set(heights.map { ($0 * 2).rounded() / 2 })
        #expect(distinct.count == 1,
                Comment(rawValue: "the height oscillates: distinct=\(distinct.sorted()) sample=\(heights.prefix(40).map { Int($0) })"))
    }
}
