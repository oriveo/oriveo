import Testing
import UIKit
@testable import Oriveo

/// Pins the contract that an asynchronous syntax-highlight pass which really changes the height of
/// a code block must report that change up to the cell.
///
/// The defect: `UIKitCodeBlockCard.refreshCodeHeightAfterRehighlight` only called
/// `setNeedsLayout` and relied on Auto Layout to propagate the height constraint change up through
/// the content container and body stack to the cell, so the invalidation only happened on the next
/// frame. That overlapped the finalize settle window and produced one extra jump after a code block
/// finished rendering.
///
/// Fix: the card exposes an `onIntrinsicHeightDidChange` closure, the static body renderer wires it
/// up when it builds a rich code card, and the cell points it at `notifyContentDidChange()`.
@Suite("UIKitCodeBlockCard async highlight → host notify chain")
@MainActor
struct UIKitCodeBlockCardAsyncHighlightHostNotifyTests {

    @Test("Card Shows Visible Save As Note Button When Action Is Available")
    func cardShowsVisibleSaveAsNoteButtonWhenActionIsAvailable() {
        let card = UIKitCodeBlockCard(
            language: "swift",
            content: "let x = 1",
            parentViewController: nil
        )

        card.onSaveNote = {}

        let buttonTitles = Self.buttonTitles(in: card)
        #expect(
            buttonTitles.contains(L10n.tr("Save as Note", table: .notes)),
            "a code block card must expose a visible save-as-note affordance, not only a long-press menu"
        )
    }


    @Test("Card Exposes Intrinsic Height Hook")
    func cardExposesIntrinsicHeightHook() {
        let card = UIKitCodeBlockCard(
            language: "swift",
            content: "let x = 1",
            parentViewController: nil
        )
        var hookCount = 0
        card.onIntrinsicHeightDidChange = { hookCount += 1 }
        #expect(card.onIntrinsicHeightDidChange != nil)
        card.onIntrinsicHeightDidChange?()
        #expect(hookCount == 1)
    }


    @Test("Static Renderer Wires Host Notifier On Frozen Code Card")
    func staticRendererWiresHostNotifierOnFrozenCodeCard() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        var hostNotifyCount = 0
        let renderer = AssistantStaticBodyRenderer(
            bodyStack: bodyStack,
            textView: textView,
            hostNotifier: { hostNotifyCount += 1 }
        )
        let placeholderVC = UIViewController()
        renderer.renderBlockMarkdown(
            text: "Leading text\n\n```swift\nlet x = 1\n```\n\nTrailing text",
            renderHint: nil,
            parentViewController: placeholderVC
        )

        let codeCards = bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(codeCards.count == 1, "rendering should produce exactly one UIKitCodeBlockCard")
        guard let card = codeCards.first else { return }
        #expect(card.onIntrinsicHeightDidChange != nil, "a frozen code card must carry the host notifier")

        card.onIntrinsicHeightDidChange?()
        #expect(hostNotifyCount == 1)
    }


    @Test("Static Renderer Wires Host Notifier On Append Frozen Views")
    func staticRendererWiresHostNotifierOnAppendFrozenViews() {
        let bodyStack = UIStackView()
        let textView = UIView()
        bodyStack.addArrangedSubview(textView)
        var hostNotifyCount = 0
        let renderer = AssistantStaticBodyRenderer(
            bodyStack: bodyStack,
            textView: textView,
            hostNotifier: { hostNotifyCount += 1 }
        )
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)
        let segment = StreamingSegmentParser.Segment(
            kind: .codeBlock(language: "swift"),
            content: "let x = 1"
        )
        renderer.appendFrozenViews(newSegments: [segment])

        let codeCards = bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(codeCards.count == 1)
        guard let card = codeCards.first else { return }
        #expect(card.onIntrinsicHeightDidChange != nil)
        card.onIntrinsicHeightDidChange?()
        #expect(hostNotifyCount == 1)
    }


    @Test("Default Host Notifier Is No Op")
    func defaultHostNotifierIsNoOp() {
        let bodyStack = UIStackView()
        let textView = UIView()
        let renderer = AssistantStaticBodyRenderer(bodyStack: bodyStack, textView: textView)
        let placeholderVC = UIViewController()
        renderer.setParentViewController(placeholderVC)
        let segment = StreamingSegmentParser.Segment(
            kind: .codeBlock(language: nil),
            content: "x"
        )
        renderer.appendFrozenViews(newSegments: [segment])
        let codeCards = bodyStack.arrangedSubviews.compactMap { $0 as? UIKitCodeBlockCard }
        #expect(codeCards.count == 1)
        codeCards.first?.onIntrinsicHeightDidChange?()
    }

    private static func buttonTitles(in view: UIView) -> [String] {
        var titles: [String] = []
        if let button = view as? UIButton {
            if let title = button.configuration?.title, !title.isEmpty {
                titles.append(title)
            }
            if let title = button.title(for: .normal), !title.isEmpty {
                titles.append(title)
            }
        }
        for subview in view.subviews {
            titles.append(contentsOf: buttonTitles(in: subview))
        }
        return titles
    }
}
