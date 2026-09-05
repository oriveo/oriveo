import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Cards with an explicit height must ignore the transient widths that appear in intermediate
/// self-sizing frames.
///
/// The defect: an intermediate `systemLayoutSizeFitting` pass during cell self-sizing hands a
/// frozen card a collapsed width, the card recomputes its wrapping for that wrong width, its
/// explicit height constraint jumps, and the real frame then restores it - a visible flicker.
/// The fix anchors on the real width (`ChatCardStableWidth`, i.e. `cv.bounds.width` minus the
/// content chrome) and skips recomputation for transient frames.
@Suite("Transient width immunity for chat cards")
@MainActor
struct ChatCardTransientWidthTests {

    private static let cvWidth: CGFloat = 390
    private static var contentWidth: CGFloat { cvWidth - ChatCardStableWidth.contentChrome }

    @Test("Trustworthiness Rules")
    func trustworthinessRules() {
        let anchor = Self.contentWidth
        #expect(ChatCardStableWidth.isTrustworthy(width: 190, anchor: nil))
        #expect(ChatCardStableWidth.isTrustworthy(width: anchor, anchor: anchor))
        #expect(ChatCardStableWidth.isTrustworthy(width: anchor + 1.5, anchor: anchor))
        #expect(!ChatCardStableWidth.isTrustworthy(width: 190, anchor: anchor))
        #expect(!ChatCardStableWidth.isTrustworthy(width: 420, anchor: anchor))
    }

    @Test("Anchor Resolution")
    func anchorResolution() {
        let cv = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: Self.cvWidth, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let bare = UIView()
        #expect(ChatCardStableWidth.anchor(for: bare) == nil)
        cv.addSubview(bare)
        #expect(ChatCardStableWidth.anchor(for: bare) == Self.contentWidth)
    }

    @Test("Production Content Width Is Trustworthy")
    func productionContentWidthIsTrustworthy() {
        let productionWidth = ChatListViewController.assistantContentWidth(for: Self.cvWidth)
        #expect(productionWidth == Self.contentWidth)
        #expect(ChatCardStableWidth.isTrustworthy(width: productionWidth, anchor: Self.contentWidth))
        #expect(!ChatCardStableWidth.isTrustworthy(width: Self.cvWidth - 52, anchor: Self.contentWidth))
    }

    @Test("Code Card Ignores Transient Width")
    func codeCardIgnoresTransientWidth() {
        let cv = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: Self.cvWidth, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let code = (1...8).map { "let value\($0) = compute(input\($0))" }.joined(separator: "\n")
        let card = UIKitCodeBlockCard(
            language: "swift",
            content: code,
            parentViewController: nil,
            highlightTransition: false
        )
        cv.addSubview(card)
        card.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 500)
        card.layoutIfNeeded()
        let stableHeight = card.codeHeightConstantForTesting
        #expect(stableHeight > 0)
        #expect(stableHeight < UIKitCodeBlockCard.maxPreviewHeight)

        card.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
        card.layoutIfNeeded()
        #expect(card.codeHeightConstantForTesting == stableHeight, "a transient width must not change the explicit height")

        card.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 500)
        card.layoutIfNeeded()
        #expect(card.codeHeightConstantForTesting == stableHeight)
    }

    @Test("Code Card Without Anchor Still Resizes")
    func codeCardWithoutAnchorStillResizes() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: Self.cvWidth, height: 800))
        let code = (1...8).map { "let value\($0) = compute(input\($0))" }.joined(separator: "\n")
        let card = UIKitCodeBlockCard(
            language: "swift",
            content: code,
            parentViewController: nil,
            highlightTransition: false
        )
        host.addSubview(card)
        card.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 500)
        card.layoutIfNeeded()
        let wide = card.codeHeightConstantForTesting
        card.frame = CGRect(x: 0, y: 0, width: 190, height: 500)
        card.layoutIfNeeded()
        card.setNeedsLayout()
        card.layoutIfNeeded()
        #expect(card.codeHeightConstantForTesting > wide, "without a width anchor, rotation or a real width change must still recompute")
    }
}
