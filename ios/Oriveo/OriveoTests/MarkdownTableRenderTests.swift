import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("Markdown Table Render Tests")
struct MarkdownTableRenderTests {


    @Test("Basic Table Parsing")
    func basicTableParsing() {
        let lines = [
            "| A | B |",
            "| - | - |",
            "| 1 | 2 |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.headers == ["A", "B"])
        #expect(data!.rows == [["1", "2"]])
    }

    @Test("Single Column Table")
    func singleColumnTable() {
        let lines = [
            "| Item |",
            "| --- |",
            "| Alpha |",
            "| Beta |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.headers == ["Item"])
        #expect(data!.rows.count == 2)
        #expect(data!.rows[0] == ["Alpha"])
        #expect(data!.rows[1] == ["Beta"])
    }

    @Test("Header Only Table")
    func headerOnlyTable() {
        let lines = [
            "| A | B |",
            "| - | - |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.headers == ["A", "B"])
        #expect(data!.rows.isEmpty)
    }

    @Test("Multi Row Table")
    func multiRowTable() {
        let lines = [
            "| Operation | Time complexity |",
            "| --- | --- |",
            "| Insert | O(log n) |",
            "| Delete | O(log n) |",
            "| Lookup | O(log n) |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.rows.count == 3)
        #expect(data!.rows[0][0] == "Insert")
        #expect(data!.rows[0][1] == "O(log n)")
    }

    @Test("Mismatched Column Count Not Table")
    func mismatchedColumnCountNotTable() {
        let lines = [
            "| A | B | C |",
            "| - | - |",
            "| 1 | 2 | 3 |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data == nil)
    }


    @Test("Right Alignment Parsed")
    func rightAlignmentParsed() {
        let lines = [
            "| Name | Price |",
            "| --- | ---: |",
            "| Apple | 5.00 |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.alignments[0] == .left)
        #expect(data!.alignments[1] == .right)
    }

    @Test("Center Alignment Parsed")
    func centerAlignmentParsed() {
        let lines = [
            "| Left | Center | Right |",
            "| :--- | :---: | ---: |",
            "| L | C | R |",
        ]
        let data = UIKitTableCard.parseMarkdownLines(lines)
        #expect(data != nil)
        #expect(data!.alignments[0] == .left)
        #expect(data!.alignments[1] == .center)
        #expect(data!.alignments[2] == .right)
    }


    @Test("Strip Markdown")
    func stripMarkdown() {
        #expect(UIKitTableCard.stripMarkdown("**bold**") == "bold")
        #expect(UIKitTableCard.stripMarkdown("*italic*") == "italic")
        #expect(UIKitTableCard.stripMarkdown("`code`") == "code")
        #expect(UIKitTableCard.stripMarkdown("~~strike~~") == "strike")
        #expect(UIKitTableCard.stripMarkdown("[link](url)") == "link")
        #expect(UIKitTableCard.stripMarkdown("plain text") == "plain text")
    }


    @Test("Separator Row Stripped")
    func separatorRowStripped() {
        let text = """
        | H1 | H2 |
        | -- | -- |
        | D1 | D2 |
        """
        let result = MarkdownAttributedStringRenderer.render(text).string
        #expect(!result.contains("--"))
    }

    @Test("Table Rendering Is Cached")
    func tableRenderingIsCached() {
        let text = """
        | X | Y |
        | - | - |
        | 1 | 2 |
        """
        let first = MarkdownAttributedStringRenderer.render(text)
        let second = MarkdownAttributedStringRenderer.cachedRender(for: text)
        #expect(second != nil)
        #expect(first.string == second!.string)
    }

    @Test("Pipe In Normal Text Not Table")
    func pipeInNormalTextNotTable() {
        let text = "This is ordinary text with A | B | C"
        let result = MarkdownAttributedStringRenderer.render(text).string
        #expect(result.contains("A | B | C"))
    }

    @Test("Table After Heading")
    func tableAfterHeading() {
        let text = """
        ## Core operations

        | Operation | Complexity |
        | --- | --- |
        | Insert | O(1) |
        """
        let result = MarkdownAttributedStringRenderer.render(text).string
        #expect(result.contains("Core operations"))
        #expect(result.contains("Insert"))
        #expect(result.contains("O(1)"))
    }

    @Test("Multiple Tables In Single Message")
    func multipleTablesInSingleMessage() {
        let text = """
        | A | B |
        | --- | --- |
        | 1 | 2 |

        Text in between

        | C | D |
        | --- | --- |
        | 3 | 4 |
        """

        let result = MarkdownAttributedStringRenderer.render(text).string

        #expect(result.contains("1"))
        #expect(result.contains("2"))
        #expect(result.contains("Text in between"))
        #expect(result.contains("3"))
        #expect(result.contains("4"))
        #expect(!result.contains("---"))
    }

    @Test("Html Bold In Table Cells")
    func htmlBoldInTableCells() {
        let text = """
        | Name | Value |
        | --- | --- |
        | <b>Important</b> | 100 |
        """
        let result = MarkdownAttributedStringRenderer.render(text).string
        #expect(!result.contains("<b>"))
        #expect(!result.contains("</b>"))
        #expect(result.contains("Important"))
        #expect(result.contains("100"))
    }


    @Test("UIKitTableCard Instantiates With Height > 0")
    @MainActor
    func tableCardCreation() {
        let data = UIKitTableCard.TableData(
            headers: ["Name", "Value"],
            rows: [["Alpha", "100"], ["Beta", "200"]],
            alignments: [.left, .right]
        )
        let card = UIKitTableCard(tableData: data)
        let size = card.intrinsicContentSize
        #expect(size.height > 0)
    }

    @Test("CJK Content Does Not Crash And Height > 0")
    @MainActor
    func tableCardCJK() {
        let data = UIKitTableCard.TableData(
            headers: ["조작", "시간복잡도", "공간복잡도"],
            rows: [
                ["삽입", "O(log n)", "O(1)"],
                ["삭제", "O(log n)", "O(1)"],
                ["이진탐색", "O(log n)", "O(1)"],
            ],
            alignments: [.left, .center, .right]
        )
        let card = UIKitTableCard(tableData: data)
        let size = card.intrinsicContentSize
        #expect(size.height > 0)
    }

    @Test("Empty-Row Table Does Not Crash")
    @MainActor
    func tableCardEmptyRows() {
        let data = UIKitTableCard.TableData(
            headers: ["A", "B"],
            rows: [],
            alignments: [.left, .left]
        )
        let card = UIKitTableCard(tableData: data)
        let size = card.intrinsicContentSize
        #expect(size.height > 0)
    }

    @Test("Narrow Table Fills Message Width Without Right-Side Gap")
    @MainActor
    func narrowTableCardFillsAvailableWidth() throws {
        let data = UIKitTableCard.TableData(
            headers: ["Service", "Mainland availability"],
            rows: [
                ["Realtime Database", "❌ Unavailable"],
                ["Document Store", "❌ Unavailable"],
                ["Account Service", "❌ Unavailable"],
            ],
            alignments: [.left, .left]
        )
        let card = UIKitTableCard(tableData: data)
        card.frame = CGRect(x: 0, y: 0, width: 340, height: card.intrinsicContentSize.height)

        card.setNeedsLayout()
        card.layoutIfNeeded()

        let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
        let tableContainer = try #require(scrollView.subviews.first)
        #expect(abs(scrollView.contentSize.width - 340) < 0.5)
        #expect(abs(tableContainer.frame.width - 340) < 0.5)
    }

    @Test("cell views are built once: attaching the selection callback and changing width reuse them, frames follow the width, and question context is kept")
    @MainActor
    func tableCardReusesCellViewsAcrossRelayout() throws {
        let data = UIKitTableCard.TableData(
            headers: ["Model", "Notes"],
            rows: [["**alpha**", "fast"], ["beta", "`tools` ok"]],
            alignments: [.left, .left]
        )
        let card = UIKitTableCard(tableData: data)
        func cellViews() throws -> [ChatPassiveTextView] {
            let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
            let container = try #require(scrollView.subviews.first)
            return container.subviews.flatMap { $0.subviews.compactMap { $0 as? ChatPassiveTextView } }
        }
        card.frame = CGRect(x: 0, y: 0, width: 360, height: 10)
        card.layoutIfNeeded()
        card.frame.size.height = card.intrinsicContentSize.height
        card.completeDeferredRows()
        let built = try cellViews()
        #expect(built.count == 6)

        var asked: QuoteSelectionContent?
        card.onAskSelection = { asked = $0 }
        card.layoutIfNeeded()
        let wide = try cellViews()
        #expect(wide.map(ObjectIdentifier.init) == built.map(ObjectIdentifier.init))
        let wideNotesX = wide[1].frame.minX

        card.frame.size.width = 300
        card.setNeedsLayout()
        card.layoutIfNeeded()
        let narrow = try cellViews()
        #expect(narrow.map(ObjectIdentifier.init) == built.map(ObjectIdentifier.init))
        #expect(narrow[1].frame.minX < wideNotesX, "the second column should move left once the available width shrinks")

        // Second data row, second column: the question context carries the row's other cells, markdown stripped.
        let callback = try #require(narrow[5].onAskSelection)
        callback(QuoteSelectionContent(contentKind: .table, leadingText: "", selectedText: "tools", trailingText: " ok"))
        #expect(asked?.leadingText == "beta | ")
        #expect(asked?.selectedText == "tools")

        card.onAskSelection = nil
        #expect(try cellViews().allSatisfy { $0.onAskSelection == nil })
    }

    @Test("Fills Real Content Width On The cv Tree — Old chrome=52 Rejected Final Width As Transient")
    @MainActor
    func narrowTableCardFillsWidthInsideCollectionView() throws {
        let cv = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let data = UIKitTableCard.TableData(
            headers: ["Multiply", "Log"],
            rows: [
                ["1000 × 100 = 100000", "3 + 2 = 5"],
                ["10th root", "÷10"],
            ],
            alignments: [.left, .left]
        )
        let card = UIKitTableCard(tableData: data)
        cv.addSubview(card)
        let contentWidth = ChatListViewController.assistantContentWidth(for: 390)
        card.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 200)
        card.setNeedsLayout()
        card.layoutIfNeeded()

        let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
        let tableContainer = try #require(scrollView.subviews.first)
        #expect(contentWidth == 342)
        #expect(abs(scrollView.contentSize.width - contentWidth) < 0.5)
        #expect(abs(tableContainer.frame.width - contentWidth) < 0.5)
    }

    @Test("Table Cell Renders $...$ As A Math Attachment Not Raw Text")
    @MainActor
    func tableCellRendersInlineMath() {
        let latex = #"\log_a M"#
        let font = UIFont.systemFont(ofSize: 14)
        let color = UIColor(OriveoTheme.Palette.textPrimary)
        _ = LatexImageCache.image(
            latex: latex,
            fontSize: font.pointSize * 1.1,
            textColor: color,
            inline: true
        )
        let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
            "$\(latex)$",
            font: font,
            textColor: color,
            isHeader: false
        )
        #expect(!attr.string.contains("$"))
        var hasAttachment = false
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if value is LatexAttachment { hasAttachment = true }
        }
        #expect(hasAttachment)
    }

    @Test("Table Header With Math Is Not Uppercased")
    func tableHeaderWithMathIsNotUppercased() {
        let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
            #"$\log_a M$"#,
            font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            textColor: .black,
            isHeader: true
        )
        #expect(!attr.string.contains("LOG"))
        #expect(!attr.string.contains("Log"))
    }
}

/// Chat cell reuse: a cleared table card goes back to the reuse pool, and the same table scrolling
/// back on screen takes the card back instead of rebuilding the whole table.
@Suite("Table card reuse across cells", .serialized)
@MainActor
struct TableCardRecyclingTests {
    private func makeRenderer() -> (AssistantStaticBodyRenderer, UIStackView) {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.frame = CGRect(x: 0, y: 0, width: 342, height: 800)
        let textView = UITextView()
        stack.addArrangedSubview(textView)
        return (AssistantStaticBodyRenderer(bodyStack: stack, textView: textView), stack)
    }

    private func tableCards(in stack: UIStackView) -> [UIKitTableCard] {
        stack.arrangedSubviews.compactMap { $0 as? UIKitTableCard }
    }

    @Test("a cleared table is taken back for the same content, a card still on screen is never taken by another cell, and reuse resets its state")
    func recycledCardIsReusedOnlyWhenDetached() throws {
        let text = """
        Compare:

        | Recycle \(UUID().uuidString) | Value |
        |---|---|
        | alpha | 1 |
        | beta | 2 |
        """
        let host = UIViewController()
        let (first, firstStack) = makeRenderer()
        first.renderBlockMarkdown(text: text, renderHint: nil, parentViewController: host)
        firstStack.layoutIfNeeded()
        let original = try #require(tableCards(in: firstStack).first)

        // The same table in a second cell at the same time: the original is still attached, so build a new card.
        let (second, secondStack) = makeRenderer()
        second.renderBlockMarkdown(text: text, renderHint: nil, parentViewController: host)
        secondStack.layoutIfNeeded()
        let concurrent = try #require(tableCards(in: secondStack).first)
        #expect(concurrent !== original)

        // The first cell is reused and cleared, with a leftover entrance animation and a horizontal scroll.
        original.alpha = 0.3
        original.transform = CGAffineTransform(translationX: 0, y: 8)
        let originalScroll = try #require(original.subviews.compactMap { $0 as? UIScrollView }.first)
        originalScroll.contentOffset = CGPoint(x: 40, y: 0)
        first.clear()
        #expect(original.superview == nil)

        var asked = false
        let (third, thirdStack) = makeRenderer()
        third.onAskSelection = { _ in asked = true }
        third.renderBlockMarkdown(text: text, renderHint: nil, parentViewController: host)
        thirdStack.layoutIfNeeded()
        let reused = try #require(tableCards(in: thirdStack).first)
        #expect(reused === original)
        reused.completeDeferredRows()
        #expect(reused.alpha == 1)
        #expect(reused.transform == .identity)
        #expect(originalScroll.contentOffset == .zero)

        // The callback now belongs to the new cell: asking from a table cell reaches the third renderer.
        let container = try #require(originalScroll.subviews.first)
        let cell = try #require(container.subviews.flatMap { $0.subviews.compactMap { $0 as? ChatPassiveTextView } }.last)
        cell.onAskSelection?(QuoteSelectionContent(contentKind: .table, leadingText: "", selectedText: "2", trailingText: ""))
        #expect(asked)

        // The pool only holds detached cards: clearing the second cell makes the next render take that card,
        // not the original still attached to the third cell.
        second.clear()
        let (fourth, fourthStack) = makeRenderer()
        fourth.renderBlockMarkdown(text: text, renderHint: nil, parentViewController: host)
        fourthStack.layoutIfNeeded()
        #expect(tableCards(in: fourthStack).first === concurrent)
    }
}

/// Table cards show pixel-identical placeholders in the first frame, and the shared scheduler upgrades
/// them to UITextViews in later frames. These tests use a real window and spin the real main run loop
/// (CADisplayLink and RunLoop.perform both run), driving the production upgrade path rather than
/// capturing the final state directly.
@Suite("Table card placeholders and deferred upgrades", .serialized)
@MainActor
struct TableCardDeferredBuildTests {
    private var scheduler: TableCardCellUpgradeScheduler { .shared }

    private func withWindow(_ body: (UIView) throws -> Void) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer {
            scheduler.frameBudgetOverrideForTesting = nil
            scheduler.isPausedForTesting = false
            window.isHidden = true
            window.rootViewController = nil
        }
        try body(root.view)
    }

    private func tableData(rows: Int, tag: String, mathLatex: String? = nil) -> UIKitTableCard.TableData {
        UIKitTableCard.TableData(
            headers: ["Model", "Context", "Input", "Output", "Notes"],
            rows: (0..<rows).map { index in
                let context = (index == 0 || index == rows - 1) ? mathLatex.map { "$\($0)$" } ?? "128K" : "128K"
                return ["\(tag)-\(index)", context, "$2.50", "$10.00", "notes \(index) with a longer tail"]
            },
            alignments: [.left, .center, .right, .right, .left]
        )
    }

    /// Spins the real main run loop until the condition holds or the timeout passes.
    @discardableResult
    private func pump(timeout: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func hasLatexAttachment(_ attributed: NSAttributedString?) -> Bool {
        guard let attributed else { return false }
        var found = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value is LatexAttachment { found = true }
        }
        return found
    }

    @Test("every row has content in the first frame (placeholder or UITextView), and the scheduler upgrades the rest in the real run loop")
    func firstFrameCoversEveryRowAndSchedulerFinishes() throws {
        try withWindow { root in
            let card = UIKitTableCard(tableData: tableData(rows: 30, tag: "first-frame-\(UUID().uuidString.prefix(6))"))
            root.addSubview(card)
            card.frame = CGRect(x: 24, y: 0, width: 342, height: 10)
            card.layoutIfNeeded()

            let first = card._testCellCoverage
            #expect(first.rows == 31)
            #expect(first.rowsWithContent == 31, "Only \(first.rowsWithContent)/31 rows have content in the first frame; the rest show a blank background")
            #expect(first.placeholders == 31 * 5, "Layout builds no UITextView, only placeholders")
            let placeholder = try #require(card._testCell(row: 30, column: 4))
            #expect(placeholder.view is UIKitTableCard.CellPlaceholderView)
            #expect(placeholder.attributedText?.string == "notes 29 with a longer tail")

            let finished = pump(timeout: 15) { card._testCellCoverage.placeholders == 0 }
            #expect(finished, "The scheduler did not finish upgrading placeholders, \(card._testCellCoverage.placeholders) cells left")
            #expect(card._testCellCoverage.rowsWithTextViews == 31)
            #expect(card._testCell(row: 30, column: 4)?.view is ChatPassiveTextView)
        }
    }

    @Test("upgrades pause off screen (removed from the window or pooled) and resume back on screen")
    func upgradesPauseOffscreenAndResumeOnScreen() throws {
        try withWindow { root in
            let card = UIKitTableCard(tableData: tableData(rows: 30, tag: "offscreen-\(UUID().uuidString.prefix(6))"))
            root.addSubview(card)
            card.frame = CGRect(x: 24, y: 0, width: 342, height: 10)
            card.layoutIfNeeded()
            card.removeFromSuperview()

            pump(timeout: 0.3)
            #expect(card._testCellCoverage.placeholders == 31 * 5, "UITextViews were still built outside a window")

            root.addSubview(card)
            let finished = pump(timeout: 15) { card._testCellCoverage.placeholders == 0 }
            #expect(finished, "Upgrades did not resume back in the window, \(card._testCellCoverage.placeholders) cells left")
        }
    }

    @Test("a formula image landing mid-upgrade refreshes upgraded UITextViews and remaining placeholders alike, none stay on $...$")
    func latexRenderedMidUpgradeRefreshesEveryCell() throws {
        try withWindow { root in
            let latex = "x_{\(Int.random(in: 100_000...999_999))}"
            let card = UIKitTableCard(tableData: tableData(rows: 30, tag: "latex-\(UUID().uuidString.prefix(6))", mathLatex: latex))
            root.addSubview(card)
            card.frame = CGRect(x: 24, y: 0, width: 342, height: 10)
            card.layoutIfNeeded()
            card.frame.size.height = card.intrinsicContentSize.height
            card.layoutIfNeeded()

            // Touch the first data row: that row upgrades to UITextViews while the others stay
            // placeholders, which sets up an upgrade in progress.
            let rowFrame = try #require(card._testRowFrame(row: 1))
            _ = card.hitTest(CGPoint(x: 20, y: rowFrame.midY), with: nil)
            #expect(card._testCell(row: 1, column: 1)?.view is ChatPassiveTextView)
            #expect(card._testCell(row: 30, column: 1)?.view is UIKitTableCard.CellPlaceholderView)
            #expect(card._testCell(row: 1, column: 1)?.attributedText?.string.contains("$") == true,
                    "Precondition: the formula image is not cached yet, so the cell still shows the source")

            // The real asynchronous render notification is delivered through DispatchQueue.main and is not
            // consumed in tests: fill the cache synchronously, then post the same notification by hand.
            card.traitCollection.performAsCurrent {
                _ = LatexImageCache.image(
                    latex: latex,
                    fontSize: 14 * 1.1,
                    textColor: UIColor(OriveoTheme.Palette.textPrimary),
                    inline: true
                )
            }
            NotificationCenter.default.post(
                name: LatexImageCache.didRenderNotification,
                object: nil,
                userInfo: [LatexImageCache.userInfoLatexKey: latex]
            )
            card.layoutIfNeeded()

            #expect(hasLatexAttachment(card._testCell(row: 1, column: 1)?.attributedText), "An upgraded cell stayed on the source text")
            #expect(hasLatexAttachment(card._testCell(row: 30, column: 1)?.attributedText), "A placeholder cell stayed on the source text")

            #expect(pump(timeout: 15) { card._testCellCoverage.placeholders == 0 })
            let last = try #require(card._testCell(row: 30, column: 1))
            #expect(last.view is ChatPassiveTextView)
            #expect(hasLatexAttachment(last.attributedText), "Upgrading the placeholder to a UITextView lost the formula")
            #expect(last.attributedText?.string.contains("$") == false)
        }
    }

    @Test("when the card width never matches the stable width anchor, the table is built at the current width after one run loop turn")
    func untrustedWidthFallsBackToCurrentWidth() throws {
        let cv = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let card = UIKitTableCard(tableData: UIKitTableCard.TableData(
            headers: ["A", "B"],
            rows: [["short", "cell"], ["wide text", "aligned"]],
            alignments: [.left, .left]
        ))
        cv.addSubview(card)
        // Anchor = 390 - 48 = 342, so a 300pt card width always counts as transient.
        card.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        card.layoutIfNeeded()
        #expect(card._testCellCoverage.rowsWithContent == 0, "Precondition: a transient width builds nothing within the same layout pass")

        let built = pump(timeout: 2) { card._testCellCoverage.rowsWithContent == 3 }
        #expect(built, "No fallback when the width never becomes trustworthy, so the table stays blank")
        let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(abs(scrollView.contentSize.width - 300) < 0.5, "The fallback fills the current width")
    }

    @Test("a touch on a row that is still placeholders upgrades that row in hitTest with the ask callback bound")
    func hitTestUpgradesTouchedRow() throws {
        try withWindow { root in
            let tag = "touch-\(UUID().uuidString.prefix(6))"
            let card = UIKitTableCard(tableData: tableData(rows: 30, tag: tag))
            var asked: QuoteSelectionContent?
            card.onAskSelection = { asked = $0 }
            root.addSubview(card)
            card.frame = CGRect(x: 24, y: 0, width: 342, height: 10)
            card.layoutIfNeeded()
            card.frame.size.height = card.intrinsicContentSize.height
            card.layoutIfNeeded()
            #expect(card._testCellCoverage.rowsWithTextViews == 0)

            let rowFrame = try #require(card._testRowFrame(row: 5))
            let hit = card.hitTest(CGPoint(x: 20, y: rowFrame.midY), with: nil)
            let textView = try #require((hit as? ChatPassiveTextView) ?? (hit?.superview as? ChatPassiveTextView))
            #expect(card._testCell(row: 5, column: 0)?.view === textView)
            #expect(card._testCellCoverage.rowsWithTextViews == 1)

            let callback = try #require(textView.onAskSelection)
            callback(QuoteSelectionContent(contentKind: .table, leadingText: "", selectedText: "\(tag)-4", trailingText: ""))
            #expect(asked?.trailingText.hasPrefix(" | 128K") == true)
        }
    }

    @Test("the per-frame budget is shared across cards: with two tables pending, the first uses the frame's budget and the second waits")
    func frameBudgetIsSharedAcrossCards() throws {
        try withWindow { root in
            // Run only the frame driven by hand below (same implementation as the display link callback),
            // so callbacks from the run loop do not mix in.
            scheduler.isPausedForTesting = true
            scheduler.frameBudgetOverrideForTesting = 0.03
            let cards = (0..<2).map { index in
                UIKitTableCard(tableData: tableData(rows: 60, tag: "budget-\(index)-\(UUID().uuidString.prefix(6))"))
            }
            for card in cards {
                root.addSubview(card)
                card.frame = CGRect(x: 24, y: 0, width: 342, height: 10)
                card.layoutIfNeeded()
                #expect(card._testCellCoverage.placeholders == 61 * 5, "Layout builds no UITextView")
                #expect(card._testCellCoverage.rowsWithContent == 61)
            }

            scheduler.runFrameForTesting()
            let upgraded = cards.map { 61 * 5 - $0._testCellCoverage.placeholders }
            // One UITextView takes at least 0.3ms on a simulator, so 305 cells do not fit in a 30ms frame:
            // with a shared budget only one table advances.
            #expect(upgraded.filter { $0 > 0 }.count == 1, "Both tables got their own budget in one frame: \(upgraded)")
            #expect(upgraded.reduce(0, +) < 61 * 5)
            for card in cards { card.removeFromSuperview() }
        }
    }

    private func streamingModel(id: UUID, text: String, generating: Bool) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: id, role: .assistant, text: text, reasoningText: nil,
            providerKind: .miniMax, providerName: "MiniMax", modelName: "MiniMax-M2.7",
            estimatedCost: 0, state: generating ? .generating : .delivered,
            attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id, message: message, presentationKind: .assistant, showMetadata: true,
            resolvedProviderName: "MiniMax", resolvedModelName: "MiniMax-M2.7", relayKind: nil,
            renderHint: nil, topPadding: 16, displayText: nil, textHash: text.hashValue,
            isStreaming: generating, providerMetadataVersion: 1
        )
    }

    private func relayout(_ cell: AssistantMessageCell) {
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 390, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: fit.height)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    @Test("finalizing a stream that ends with a table shows the whole table in the frame that swaps in the static card, and upgrades finish in the window")
    func finalizeHandoffShowsWholeTableInFirstFrame() throws {
        try withWindow { root in
            let id = UUID()
            let tag = "finalize-\(UUID().uuidString.prefix(6))"
            let rows = (0..<20).map { "| \(tag)-\($0) | 128K | $2.50 | $10.00 | notes \($0) |" }
            let text = "Here is the comparison:\n\n| Model | Context | Input | Output | Notes |\n|---|---|---|---|---|\n"
                + rows.joined(separator: "\n")
            let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
            root.addSubview(cell)
            let host = UIViewController()
            cell.configure(model: streamingModel(id: id, text: "", generating: true),
                           parentViewController: host, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
            cell.updateStreamingText(text)
            relayout(cell)
            #expect(cell.bodyStack.arrangedSubviews.contains { $0 is UIKitStreamingTableCard },
                    "Precondition: the table streams through the streaming card")

            cell.configure(model: streamingModel(id: id, text: text, generating: false),
                           parentViewController: host, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil)
            relayout(cell)
            #expect(!cell.bodyStack.arrangedSubviews.contains { $0 is UIKitStreamingTableCard })
            let card = try #require(cell.bodyStack.arrangedSubviews.compactMap { $0 as? UIKitTableCard }.first)
            let coverage = card._testCellCoverage
            #expect(coverage.rowsWithContent == 21, "Only \(coverage.rowsWithContent)/21 rows have content in the finalize frame")

            #expect(pump(timeout: 15) { card._testCellCoverage.placeholders == 0 })
            cell.removeFromSuperview()
        }
    }
}
