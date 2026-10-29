import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Regression for lazy rendering of long note bodies: when to split, split output pixel-identical to whole rendering, first frame only builds cells near the viewport (independent of length).
@MainActor
@Suite("Note detail long-body lazy rendering", .serialized, .sharedProcessState)
struct NoteLazyMarkdownBodyTests {
    private typealias Cost = NoteDetailRenderCostTests

    private func gate(_ body: String) -> [MarkdownLazyUnit]? {
        NoteLazyMarkdownBody.units(markdown: NoteText.readingMarkdown(body))
    }

    @Test("When to split: short bodies and CachedMarkdownView bodies under 10k chars stay whole; longer bodies always use lazy rich text; unsplittable huge single blocks fall back to a bounded viewport")
    func segmentationGate() {
        #expect(gate(Cost.mixedBody(sections: 2)) == nil)
        #expect(gate(Cost.body(.tableProse, sections: 2)) == nil)
        #expect(gate(Cost.mixedBody(sections: 10)) == nil, "A body under one and a half screens stays whole")
        #expect(gate(Cost.body(.prose, sections: 38)) == nil, "Under 10k chars stays one UITextView, selectable across paragraphs, not split")
        #expect((gate(Cost.mixedBody(sections: 38))?.count ?? 0) >= 76)
        #expect((gate(Cost.body(.tableProse, sections: 38))?.count ?? 0) >= 4)
        // Bodies beyond the bounded-viewport threshold no longer degrade to plain text.
        for kind in Cost.Kind.allCases {
            let body = Cost.body(kind, sections: 300)
            #expect(NoteText.requiresBoundedLayout(body))
            let units = gate(body)
            #expect((units?.count ?? 0) >= 2, "\(kind.rawValue) with 300 sections should use lazy rich text")
            #expect(units?.allSatisfy { $0.content.text.utf16.count <= MarkdownMessageView.maximumLazyUnitUTF16 } ?? false)
        }
        let longSeed = NoteLongBodyPerformanceGateTests.seedMarkdown(lines: NoteLongBodyPerformanceGateTests.productionSeedLines)
        #expect((gate(longSeed)?.count ?? 0) >= 2, "The production-sized 3200-line fixture should use lazy rich text")
        // One 20k-char paragraph with no paragraph boundary: cannot be split, falls back to a bounded viewport.
        #expect(gate(String(repeating: "word ", count: 4_000)) == nil)
        #expect(MarkdownMessageView.codeFenceSegmentSpacing == OriveoTheme.Spacing.md)
    }

    @Test("MarkdownUI bodies are split into groups by top-level block: a group can only start at a paragraph / table, spacing follows the BlockSequence formula; no split with reference definitions")
    func blockGroupRules() throws {
        let paragraphs = (0..<8).map { "p\($0) with a [link](https://e.com)" }
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        // Block 8 is a heading (cannot start a group) -> split at the paragraph after it, spacing = max(h2 bottom 6, paragraph top 0).
        let afterHeading = (paragraphs + ["## H", "after heading", table]).joined(separator: "\n\n")
        let units = MarkdownMessageView.lazyUnits(for: afterHeading, typography: .notes)
        #expect(units.map(\.spacingBefore) == [0, 6])
        guard case let .markdownUI(second) = units.last?.content else { Issue.record("expected markdownUI"); return }
        #expect(second.hasPrefix("after heading"))
        guard case let .markdownUI(first) = units.first?.content else { Issue.record("expected markdownUI"); return }
        #expect(first.hasSuffix("## H"))

        // Block 8 is a table -> split before it, spacing = max(paragraph bottom 14, table top 8).
        let beforeTable = (paragraphs + [table, "tail"]).joined(separator: "\n\n")
        #expect(MarkdownMessageView.lazyUnits(for: beforeTable, typography: .notes).map(\.spacingBefore) == [0, 14])

        // Lists / quotes / indented blocks / ~~~ fences never start a group; blank lines inside ~~~ are not block boundaries.
        let ineligible = (paragraphs + ["- item", "> quote", table, "~~~\ncode\n\nmore\n~~~", "tail"]).joined(separator: "\n\n")
        let ineligibleUnits = MarkdownMessageView.lazyUnits(for: ineligible, typography: .notes)
        #expect(ineligibleUnits.map(\.spacingBefore) == [0, 14])
        guard case let .markdownUI(fenced) = ineligibleUnits.last?.content else { Issue.record("expected markdownUI"); return }
        #expect(fenced.contains("~~~\ncode\n\nmore\n~~~"))

        // Reference-style link definitions may end up in another group: do not split at all.
        let withDefinition = (paragraphs + [table, "see [x][ref]", "[ref]: https://e.com"]).joined(separator: "\n\n")
        #expect(MarkdownMessageView.lazyUnits(for: withDefinition, typography: .notes).count == 1)
    }

    /// Same height proposal as the detail page: content goes in a ScrollView (vertically unbounded, ideal height), the window is given `height` so the lazy stack builds every cell.
    /// The screenshot takes the top `height` of the window; both sides lay out from the same origin and are compared pixel by pixel.
    private func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, style: UIUserInterfaceStyle) async -> UIImage {
        let host = UIHostingController(rootView: ScrollView { view.frame(width: width) }
            .background(Color(uiColor: .systemBackground)))
        host.overrideUserInterfaceStyle = style
        let window = makeSceneWindow(width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // CachedMarkdownView shows a plain-text placeholder first and backfills after background parsing; wait for it to settle.
        await settle(1.3)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private static func dumpDifference(_ label: String, _ whole: UIImage, _ lazy: UIImage, row: Int) {
        for (name, image) in [("whole", whole), ("lazy", lazy)] {
            guard let cg = image.cgImage else { continue }
            let top = max(0, row - 100)
            let rect = CGRect(x: 0, y: top, width: cg.width, height: min(300, cg.height - top))
            if let crop = cg.cropping(to: rect), let png = UIImage(cgImage: crop).pngData() {
                print("[NOTE-LAZY-DUMP] \(label)-\(name) top=\(top) \(png.base64EncodedString())")
            }
        }
    }

    private static func firstDifferingRow(_ a: UIImage, _ b: UIImage) -> Int? {
        func pixels(_ image: UIImage) -> (data: [UInt8], width: Int, height: Int)? {
            guard let cg = image.cgImage else { return nil }
            let width = cg.width, height = cg.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return (data, width, height)
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        let rows = min(pa.height, pb.height)
        let rowBytes = pa.width * 4
        for row in 0..<rows where pa.width == pb.width {
            let range = (row * rowBytes)..<((row + 1) * rowBytes)
            if pa.data[range] != pb.data[range] { return row }
        }
        return pa.height == pb.height ? nil : rows
    }

    @Test("Lazy cells match whole rendering pixel for pixel (code+table mix / table+prose x light / dark)", arguments: [NoteDetailRenderCostTests.Kind.mixed, .tableProse])
    func lazyBodyMatchesWholeRendering(kind: NoteDetailRenderCostTests.Kind) async throws {
        let markdown = NoteText.readingMarkdown(Cost.body(kind, sections: 24))
        let units = try #require(NoteLazyMarkdownBody.units(markdown: markdown))
        #expect(units.count >= 4)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let whole = await snapshot(MarkdownMessageView(text: markdown, typography: .notes), width: 346, height: 9_000, style: style)
            let lazy = await snapshot(NoteLazyMarkdownBody(units: units), width: 346, height: 9_000, style: style)
            let diffRow = Self.firstDifferingRow(whole, lazy)
            #expect(diffRow == nil, "\(kind.rawValue) style \(style.rawValue) pixels differ, first differing row y=\(diffRow.map(String.init) ?? "-") (2x)")
            if let diffRow { Self.dumpDifference("\(kind)-\(style.rawValue)", whole, lazy, row: diffRow) }
        }
    }

    /// Chunking of long-paragraph bodies over 10k chars: sample the top 9000pt (contains at least one chunk boundary).
    @Test("Long-paragraph chunking matches whole-paragraph rendering pixel for pixel (prose / plain text x light / dark)", arguments: [NoteDetailRenderCostTests.Kind.prose, .plain])
    func longTextChunksMatchWholeRendering(kind: NoteDetailRenderCostTests.Kind) async throws {
        let markdown = NoteText.readingMarkdown(Cost.body(kind, sections: kind == .prose ? 80 : 130))
        #expect(markdown.utf16.count > MarkdownMessageView.textChunkingThresholdUTF16)
        let units = try #require(NoteLazyMarkdownBody.units(markdown: markdown))
        #expect(units.count >= 4)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let whole = await snapshot(MarkdownMessageView(text: markdown, typography: .notes), width: 346, height: 9_000, style: style)
            let lazy = await snapshot(NoteLazyMarkdownBody(units: units), width: 346, height: 9_000, style: style)
            let diffRow = Self.firstDifferingRow(whole, lazy)
            #expect(diffRow == nil, "\(kind.rawValue) style \(style.rawValue) pixels differ, first differing row y=\(diffRow.map(String.init) ?? "-") (2x)")
            if let diffRow { Self.dumpDifference("\(kind)-\(style.rawValue)", whole, lazy, row: diffRow) }
        }
    }

    @Test("Layered card background matches the old drawing pixel for pixel (several card heights x light / dark)")
    func cardBackgroundMatchesLegacy() async {
        for height in [200, 2_999, 3_001, 4_500, 9_000] as [CGFloat] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let legacy = await snapshot(NoteBrandCardBackground.legacy.frame(height: height).padding(20), width: 390, height: height + 40, style: style)
                let current = await snapshot(NoteBrandCardBackground().frame(height: height).padding(20), width: 390, height: height + 40, style: style)
                let diffRow = Self.firstDifferingRow(legacy, current)
                #expect(diffRow == nil, "card height \(Int(height)) style \(style.rawValue) pixels differ, first differing row y=\(diffRow.map(String.init) ?? "-") (2x)")
                if let diffRow { Self.dumpDifference("card-\(Int(height))-\(style.rawValue)", legacy, current, row: diffRow) }
            }
        }
    }
}

