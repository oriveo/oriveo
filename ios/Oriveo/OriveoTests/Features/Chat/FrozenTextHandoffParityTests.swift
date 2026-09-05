import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Handoff parity for block-level commits.
///
/// With two separate text pipelines a frozen `UILabel` and the live text view measured the same
/// text about 17% differently, so the whole paragraph jumped when a block was committed. There are
/// two safeguards:
/// 1. the frozen view receives the very view that was on screen, taken from
///    `blockWriter.harvestForFreeze()` (`BlockCommitTextWriterTests` pins that identity);
/// 2. the frozen `.text` view and the main text view are both `ChatPassiveTextView` with the same
///    metrics configuration - this suite pins that second guarantee against future drift.
@Suite("Frozen text handoff parity")
@MainActor
struct FrozenTextHandoffParityTests {

    @Test("Frozen Matches Main Text View Height")
    func frozenMatchesMainTextViewHeight() {
        let attr = MarkdownAttributedStringRenderer.render(
            "## Heading\nBody with **bold** and a paragraph long enough to wrap two or three times at a normal chat width.\n- list item\n> quoted line"
        )

        let main = ChatPassiveTextView()
        main.isEditable = false
        main.isScrollEnabled = false
        main.backgroundColor = .clear
        main.textContainerInset = .zero
        main.textContainer.lineFragmentPadding = 0
        main.attributedText = attr

        let frozen = AssistantStaticBodyRenderer.makeFrozenTextView(attr)

        for width: CGFloat in [320, 340, 392] {
            let bound = CGSize(width: width, height: .greatestFiniteMagnitude)
            let mainHeight = main.sizeThatFits(bound).height
            let frozenHeight = frozen.sizeThatFits(bound).height
            #expect(abs(mainHeight - frozenHeight) < 0.5, "width \(width): main \(mainHeight) vs frozen \(frozenHeight)")
        }
    }
}
