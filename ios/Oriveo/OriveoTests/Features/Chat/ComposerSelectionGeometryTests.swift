import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Regression lock for "after Select All on a long text, every tap in the composer hangs for seconds".
///
/// The main-thread stack of that hang: `-[UITextSelectionInteraction _handleMultiTapGesture:]` →
/// `_checkForRepeatedTap:` → `-[UITextInteraction selection:containsPoint:]` →
/// `-[_UITextKit2LayoutController boundingRectForRange:]` → `-[NSTextLayoutManager enumerateTextSegmentsInRange:…]`,
/// reached by tapping repeatedly after `selectAll:`. UIKit enumerates the whole selection segment by segment and
/// TextKit 2 keeps no layout outside the viewport, so after Select All every tap is a full-document layout.
/// Bounding paragraph length and height measurement does not cover this query path.
///
/// What is locked is machine-independent structure: on the production composer, the length a large-range
/// geometry query hands to the system has an upper bound that does not depend on the text length. The same
/// tests turn bounding off through a seam to show that an unbounded query really covers the whole text.
/// Wall-clock numbers are only printed.
@MainActor
@Suite("Chat composer · selection geometry queries are bounded", .serialized)
struct ComposerSelectionGeometryTests {
    private final class Box {
        var text = ""
        var focused = false
    }

    static let sentence = "これはとてもながいぶんしょうで、ぜんせんたくのあとにれんぞくでタップしたときのひっかかりをさいげんします；English words とすうじ 12345 もまざっています。"

    static func cjk(utf16: Int) -> String {
        var out = ""
        while out.utf16.count < utf16 { out += sentence }
        return out
    }

    static let longUTF16 = 500_000
    /// The most one bounded query may enumerate: the head piece + the tail piece + one padding on each side of
    /// the (five-line) viewport, with the same amount again as headroom.
    static let perQueryBudget = ComposerTextLayoutManager.edgeUTF16 * 4 * 2

    private func makeView(text: String) throws -> (ComposerUITextView, ComposerTextLayoutManager, UIWindow) {
        let box = Box()
        box.text = text
        let representable = ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
            placeholder: "Type a message...",
            font: .systemFont(ofSize: 16),
            textColor: .label
        )
        let coordinator = representable.makeCoordinator()
        // The same production constructor makeUIView uses.
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(representable, to: container, force: true)
        coordinator.apply(box.text, to: container.textView)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        container.frame = CGRect(x: 20, y: 100, width: 320, height: 96)
        window.addSubview(container)
        window.makeKeyAndVisible()
        container.layoutIfNeeded()
        let layoutManager = try #require(container.textView.boundedLayoutManager)
        return (container.textView, layoutManager, window)
    }

    private func spin(_ seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func milliseconds(_ body: () -> Void) -> String {
        let start = CACurrentMediaTime()
        body()
        return String(format: "%.1fms", (CACurrentMediaTime() - start) * 1000)
    }

    /// The fraction of viewport pixels tinted with the selection highlight color (bluish).
    private func highlightFraction(of view: UIView) -> Double {
        let size = view.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var tinted = 0
        for index in stride(from: 0, to: data.count, by: 4) where Int(data[index + 2]) - Int(data[index]) > 20 {
            tinted += 1
        }
        return Double(tinted) / Double(width * height)
    }

    // MARK: - Structure

    @Test("The production constructor is still TextKit 2 and uses the bounded layout manager subclass")
    func productionViewUsesBoundedLayoutManager() throws {
        let (input, layoutManager, window) = try makeView(text: "hello")
        defer { window.isHidden = true }
        #expect(input.textLayoutManager === layoutManager, "UITextView is not using the custom layout manager (it may have fallen back to TextKit 1)")
        #expect(input.textStorage.string == "hello")
        #expect(input.textContainer.widthTracksTextView)
    }

    @Test("Lays out like the system constructor: same text and frame render pixel for pixel the same")
    func rendersIdenticallyToSystemConstruction() throws {
        let text = "いちぎょうめ first line\n" + String(repeating: "おりかえすながいぶん wraps onto more lines. ", count: 6) + "\nمرحبا بالعالم"
        let font = UIFont.systemFont(ofSize: 16)
        func configured(_ textView: UITextView) -> UITextView {
            textView.backgroundColor = .white
            textView.isScrollEnabled = true
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.attributedText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
            textView.frame = CGRect(x: 0, y: 0, width: 300, height: 160)
            return textView
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        defer { window.isHidden = true }
        window.isHidden = false
        func render(_ textView: UITextView) -> Data? {
            window.addSubview(textView)
            textView.layoutIfNeeded()
            defer { textView.removeFromSuperview() }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(size: textView.bounds.size, format: format).image { _ in
                textView.drawHierarchy(in: textView.bounds, afterScreenUpdates: true)
            }.pngData()
        }
        let system = configured(UITextView(usingTextLayoutManager: true))
        let production = configured(ComposerUITextView.makeBoundedTextKit2())
        let systemImage = try #require(render(system))
        let productionImage = try #require(render(production))
        #expect(system.contentSize == production.contentSize, "Content size differs: \(system.contentSize) vs \(production.contentSize)")
        #expect(systemImage == productionImage, "Rendering changed with the custom layout manager")
    }

    @Test("Short ranges go to the system untouched")
    func shortRangesPassThrough() throws {
        let (input, layoutManager, window) = try makeView(text: Self.cjk(utf16: 4_000))
        defer { window.isHidden = true }
        input.selectAll(nil)
        let all = try #require(input.selectedTextRange)
        let before = layoutManager.boundedQueryCount
        #expect(!input.selectionRects(for: all).isEmpty)
        #expect(layoutManager.boundedQueryCount == before, "A selection within 4000 characters must not be bounded")
    }

    // MARK: - Select All on a long text

    @Test("Selection geometry after Select All on 500K characters: enumeration is bounded; unbounded it covers the whole text")
    func selectAllGeometryQueriesAreBounded() async throws {
        let (input, layoutManager, window) = try makeView(text: Self.cjk(utf16: Self.longUTF16))
        defer { window.isHidden = true }
        input.becomeFirstResponder()
        try await spin(0.4)
        input.selectAll(nil)
        try await spin(0.6)
        let total = input.textStorage.length
        let all = try #require(input.selectedTextRange)
        #expect(input.selectedRange.length == total)

        var enumerated = layoutManager.enumeratedUTF16
        let queries = layoutManager.boundedQueryCount
        var rects: [CGRect] = []
        let boundedCost = milliseconds { rects = input.selectionRects(for: all).map(\.rect) }
        let firstRectCost = milliseconds { _ = input.firstRect(for: all) }
        #expect(layoutManager.boundedQueryCount - queries == 2, "Both UIKit queries should go through the bounded layout manager")
        #expect(layoutManager.enumeratedUTF16 - enumerated <= Self.perQueryBudget * 2,
                "Two queries enumerated \(layoutManager.enumeratedUTF16 - enumerated) UTF-16 out of \(total)")

        // Selection rects in the viewport are still returned (the highlight depends on them), and the overall
        // bounding rect still spans the whole text (tap hit-testing and menu placement depend on it).
        let viewport = input.bounds
        let visible = rects.filter { $0.intersects(viewport) && $0.width > 0 }
        let visibleUnion = visible.reduce(CGRect.null) { $0.union($1) }.intersection(viewport)
        #expect(visibleUnion.height >= viewport.height * 0.8, "Selection rects in the viewport do not cover it: \(visibleUnion) / \(viewport)")
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        #expect(union.minY <= 1, "The bounding rect should start at the first line: \(union)")
        #expect(union.maxY >= input.contentSize.height * 0.9, "The bounding rect should reach the last line: \(union) / \(input.contentSize)")
        #expect(union.contains(CGPoint(x: viewport.midX, y: viewport.midY)), "A point in the viewport should be inside the selection bounding rect")

        // The unbounded shape: on the same production path, every query enumerates the whole text. Measured
        // last, because a full layout rewrites the estimated heights of paragraphs outside the viewport and
        // the geometry afterwards can no longer be compared with the expectations above.
        layoutManager._testDisableBounding = true
        enumerated = layoutManager.enumeratedUTF16
        let unboundedCost = milliseconds { _ = input.selectionRects(for: all) }
        layoutManager._testDisableBounding = false
        #expect(layoutManager.enumeratedUTF16 - enumerated >= total, "With bounding off the whole text should be enumerated; otherwise the test never reached the production query path")
        print("ComposerSelectionGeometry iOS \(UIDevice.current.systemVersion) total=\(total) selectionRects unbounded=\(unboundedCost) bounded=\(boundedCost) firstRect bounded=\(firstRectCost)")
    }

    /// The frame from the hang's stack: `-[UITextInteraction selection:containsPoint:]`. It is a private method,
    /// so this test skips itself if the system renames it (the previous test already locks the public entry
    /// points); while it exists, it is called directly so the expectation covers the very path that hung.
    @Test("Tap hit-testing (selection:containsPoint:) after Select All still hits, with bounded enumeration")
    func tapHitTestOnFullSelectionIsBounded() async throws {
        let (input, layoutManager, window) = try makeView(text: Self.cjk(utf16: Self.longUTF16))
        defer { window.isHidden = true }
        input.becomeFirstResponder()
        try await spin(0.4)
        input.selectAll(nil)
        try await spin(0.6)

        let containsPoint = NSSelectorFromString("selection:containsPoint:")
        let activeSelection = NSSelectorFromString("activeSelection")
        let interactionAssistant = NSSelectorFromString("interactionAssistant")
        guard let interaction = input.interactions.first(where: { String(describing: type(of: $0)) == "UITextSelectionInteraction" }) as? NSObject,
              interaction.responds(to: containsPoint),
              input.responds(to: interactionAssistant),
              let assistant = input.perform(interactionAssistant)?.takeUnretainedValue() as? NSObject,
              assistant.responds(to: activeSelection),
              let selection = assistant.perform(activeSelection)?.takeUnretainedValue() else {
            print("ComposerSelectionGeometry: selection:containsPoint: unavailable (iOS \(UIDevice.current.systemVersion)), skipping the private path")
            return
        }
        typealias ContainsPoint = @convention(c) (AnyObject, Selector, AnyObject, CGPoint) -> Bool
        let call = unsafeBitCast(interaction.method(for: containsPoint), to: ContainsPoint.self)
        let point = CGPoint(x: input.bounds.midX, y: input.bounds.midY)

        var enumerated = layoutManager.enumeratedUTF16
        var boundedHit = false
        let boundedCost = milliseconds { boundedHit = call(interaction, containsPoint, selection, point) }
        let boundedEnumerated = layoutManager.enumeratedUTF16 - enumerated

        layoutManager._testDisableBounding = true
        enumerated = layoutManager.enumeratedUTF16
        var unboundedHit = false
        let unboundedCost = milliseconds { unboundedHit = call(interaction, containsPoint, selection, point) }
        let unboundedEnumerated = layoutManager.enumeratedUTF16 - enumerated
        layoutManager._testDisableBounding = false

        print("ComposerSelectionGeometry iOS \(UIDevice.current.systemVersion) containsPoint unbounded=\(unboundedCost)/\(unboundedEnumerated) bounded=\(boundedCost)/\(boundedEnumerated) hit=\(unboundedHit)/\(boundedHit)")
        #expect(unboundedEnumerated >= input.textStorage.length, "Unbounded, this path should enumerate the whole text; otherwise it is not the path that hangs")
        #expect(boundedEnumerated <= Self.perQueryBudget, "One tap enumerated \(boundedEnumerated) UTF-16")
        #expect(boundedHit == unboundedHit, "Bounding must not change whether the point is inside the selection")
        #expect(boundedHit, "After Select All a tap in the middle of the viewport should hit the selection")
    }

    @Test("Scrolling to the middle after Select All keeps the highlight; clearing the selection removes it")
    func highlightSurvivesScrolling() async throws {
        let (input, _, window) = try makeView(text: Self.cjk(utf16: Self.longUTF16))
        defer { window.isHidden = true }
        input.becomeFirstResponder()
        try await spin(0.4)
        input.selectAll(nil)
        try await spin(0.6)
        #expect(highlightFraction(of: input) > 0.5, "After Select All the viewport should be covered by the highlight")
        for fraction in [0.5, 0.2] {
            input.setContentOffset(CGPoint(x: 0, y: input.contentSize.height * fraction), animated: false)
            try await spin(0.5)
            let highlighted = highlightFraction(of: input)
            #expect(highlighted > 0.5, "At scroll fraction \(fraction) only \(highlighted) of the viewport is highlighted")
        }
        input.selectedRange = NSRange(location: 10, length: 0)
        try await spin(0.4)
        #expect(highlightFraction(of: input) < 0.05, "No highlight should remain after the selection is cleared")
    }

    @Test("Select All on 500K characters → repeated taps → cut: main-thread stall (printed only)")
    func selectAllThenCutStall() async throws {
        let source = Self.cjk(utf16: Self.longUTF16)
        let (input, _, window) = try makeView(text: source)
        defer { window.isHidden = true }
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        input.sourcePasteboard = pasteboard
        input.becomeFirstResponder()
        try await spin(0.4)
        let probe = MainThreadStallProbe()
        probe.start()
        input.selectAll(nil)
        try await spin(0.8)
        let all = try #require(input.selectedTextRange)
        for _ in 0..<6 {
            _ = input.firstRect(for: all)
            try await spin(0.05)
        }
        input.cut(nil)
        try await spin(0.5)
        probe.stop()
        #expect(input.textStorage.length == 0)
        #expect(input.sourcePasteboard.string == source, "The cut text must be the source text without soft breaks")
        print("ComposerSelectionGeometry iOS \(UIDevice.current.systemVersion) selectAll+taps+cut maxStall=\(Int(probe.maxStall * 1000))ms")
    }
}
