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
        card.layoutIfNeeded()
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

    @Test("deferred row builds finish every cell even when the width does not change")
    @MainActor
    func tableCardFinishesDeferredRowsWithoutWidthChange() throws {
        let headers = ["Model", "Context", "Input", "Output", "Notes"]
        let rows = (0..<12).map { index in
            ["model-\(index)", "128K", "$2.50", "$10.00", "notes \(index)"]
        }
        let data = UIKitTableCard.TableData(
            headers: headers,
            rows: rows,
            alignments: [.left, .center, .right, .right, .left]
        )
        let card = UIKitTableCard(tableData: data)
        card.frame = CGRect(x: 0, y: 0, width: 350, height: 10)
        card.layoutIfNeeded()
        card.completeDeferredRows()
        card.frame.size.height = card.intrinsicContentSize.height
        card.layoutIfNeeded()

        func cellCount() throws -> Int {
            let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
            let container = try #require(scrollView.subviews.first)
            return container.subviews.flatMap { $0.subviews.compactMap { $0 as? ChatPassiveTextView } }.count
        }

        let expected = (rows.count + 1) * headers.count
        let got = try cellCount()
        #expect(got == expected, "deferred row build produced \(got) cells, expected \(expected)")
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
