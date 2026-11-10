import Foundation
import Testing
import UIKit
@testable import Oriveo

// A frozen text block is built before it has a frame. With a 0-wide container, contiguous TextKit 1
// laid the whole text out on assignment with every cluster forced onto its own line, the main-thread
// hang behind jumping into a long thread.
@MainActor
@Suite("Frozen text block layout width")
struct FrozenTextLayoutWidthTests {
    private func longAttributed() -> NSAttributedString {
        let paragraph = String(
            repeating: "\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{5F88}\u{957F}\u{7684}\u{4E2D}\u{6587}\u{6BB5}\u{843D}",
            count: 60
        )
        return MarkdownAttributedStringRenderer.render(Array(repeating: paragraph, count: 20).joined(separator: "\n\n"))
    }

    @Test("A frozen block is never laid out in a 0-wide container")
    func frozenBlockStartsWithProvisionalWidth() {
        let view = AssistantStaticBodyRenderer.makeFrozenTextView(longAttributed())
        #expect(view.bounds.width == 0)
        #expect(view.textContainer.size.width == ChatPassiveTextView.provisionalLayoutWidth)
    }

    @Test("Once sized, the block lays out at its real width and matches the measured height")
    func frozenBlockTracksRealWidthAfterSizing() {
        let view = AssistantStaticBodyRenderer.makeFrozenTextView(longAttributed())
        view.frame = CGRect(x: 0, y: 0, width: 350, height: 0)
        view.layoutIfNeeded()
        #expect(view.textContainer.size.width == 350)
        view.layoutManager.ensureLayout(for: view.textContainer)
        let laidOut = view.layoutManager.usedRect(for: view.textContainer).height
        let measured = view.measuredContentSize(fittingWidth: 350).height
        #expect(abs(ceil(laidOut) - measured) <= 1)
    }
}
