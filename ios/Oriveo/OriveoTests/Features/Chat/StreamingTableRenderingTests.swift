import Testing
import UIKit
@testable import Oriveo

/// Streaming table rendering:
/// 1. `parseStreamingSegments` recognizing a GFM table at the end of the tail;
/// 2. `UIKitStreamingTableCard` incremental updates and one-way sticky column widths.
@Suite("Streaming Table Rendering")
struct StreamingTableRenderingTests {

    // MARK: - parseStreamingSegments

    @Test("Tail With Header And Separator Yields Streaming Table")
    func tailWithHeaderAndSeparatorYieldsStreamingTable() {
        let text = """
        These are the traits of the zebrafish:
        | Item | Notes |
        |------|------|
        """
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.streamingTable != nil)
        #expect(parsed.streamingTable?.count == 2)
        #expect(parsed.tail == "These are the traits of the zebrafish:")
    }

    @Test("Tail Table With Partial Data Rows")
    func tailTableWithPartialDataRows() {
        let text = """
        Intro text
        | Item | Notes |
        |------|------|
        | Size | Small fish |
        | Temperament | Very peaceful |
        """
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.streamingTable?.count == 4)
        #expect(parsed.tail == "Intro text")
    }

    @Test("Tail Header Only Does Not Yield Streaming Table")
    func tailHeaderOnlyDoesNotYieldStreamingTable() {
        let text = """
        Intro text
        | Item | Notes |
        """
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.streamingTable == nil)
        // The whole block stays in the tail and is rendered as inline markdown.
        #expect(parsed.tail.contains("| Item |"))
    }

    @Test("Tail Table Followed By Text Does Not Yield Streaming Table")
    func tailTableFollowedByTextDoesNotYieldStreamingTable() {
        let text = """
        | Item | Notes |
        |------|------|
        | Size | Small fish |

        These are the traits of the zebrafish.
        """
        let detailed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(text)
        #expect(detailed.streamingTable == nil)
        #expect(detailed.committedKinds.contains(.table), "a closed table must be lifted into a committed table segment")
        #expect(detailed.tail.contains("These are the traits of the zebrafish"))
        #expect(!detailed.tail.contains("|"), "the tail must no longer contain table markdown")
    }

    // MARK: - liftClosedTablesFromTail

    @Test("Lift Closed Table In Middle Of Tail")
    func liftClosedTableInMiddleOfTail() {
        let text = """
        Option one: checking ornamental fish for disease
        | Symptom | Possible disease | Urgent action |
        |------|----------|----------|
        | White spots on the fins | White spot disease | Raise the water to 30°C |

        Golden rule for medication: isolate the sick fish first
        """
        let detailed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(text)
        #expect(detailed.committedKinds.contains(.table))
        #expect(detailed.committedKinds.contains(.text))
        let textSegments = zip(detailed.committedKinds, detailed.committedContents)
            .filter { $0.0 == .text }
            .map(\.1)
        #expect(textSegments.contains { $0.contains("Option one") })
        #expect(detailed.tail.contains("Golden rule for medication"))
        #expect(!detailed.tail.contains("|"), "once lifted, the tail contains no table markdown")
    }

    @Test("Tail Trailing Table Not Lifted")
    func tailTrailingTableNotLifted() {
        let text = """
        These are the traits of the zebrafish:
        | Item | Notes |
        |------|------|
        | Size | Small fish |
        """
        let detailed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(text)
        #expect(detailed.streamingTable != nil)
        #expect(!detailed.committedKinds.contains(.table), "a table still growing at the end must not be lifted into a committed segment")
    }

    @Test("Lift Multiple Closed Tables")
    func liftMultipleClosedTables() {
        let text = """
        | A | B |
        |---|---|
        | 1 | 2 |

        Text in between

        | X | Y |
        |---|---|
        | 3 | 4 |

        Trailing text
        """
        let detailed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(text)
        let tableCount = detailed.committedKinds.filter { $0 == .table }.count
        #expect(tableCount == 2, "both closed tables must be lifted")
        #expect(detailed.tail.contains("Trailing text"))
        #expect(!detailed.tail.contains("|"))
    }

    @Test("Plain Tail Does Not Change Committed")
    func plainTailDoesNotChangeCommitted() {
        let text = "plain text still streaming..."
        let detailed = AssistantMessageCell.parseStreamingSegmentsDetailedForTesting(text)
        #expect(detailed.committedKinds.isEmpty)
        #expect(detailed.tail == text)
    }

    @Test("Committed Code Block And Trailing Streaming Table")
    func committedCodeBlockAndTrailingStreamingTable() {
        let text = """
        ```go
        package main
        ```
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.committedCount >= 1)
        #expect(parsed.streamingTable != nil)
        #expect(parsed.streamingTable?.count == 3)
    }

    @Test("Plain Text Tail Has No Streaming Table")
    func plainTextTailHasNoStreamingTable() {
        let text = "This is an ordinary paragraph, with no table."
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.streamingTable == nil)
        #expect(parsed.tail == text)
    }

    @Test("Single Column Table Recognized")
    func singleColumnTableRecognized() {
        let text = """
        | Item |
        |------|
        | Size |
        """
        let parsed = AssistantMessageCell.parseStreamingSegmentsForTesting(text)
        #expect(parsed.streamingTable?.count == 3)
    }

    // MARK: - UIKitStreamingTableCard

    @Test("Streaming Table Card Requires Header And Separator")
    @MainActor
    func streamingTableCardRequiresHeaderAndSeparator() {
        let onlyHeader = ["| A | B |"]
        let card = UIKitStreamingTableCard(initialLines: onlyHeader)
        #expect(card == nil)

        let headerAndSep = ["| A | B |", "|---|---|"]
        let card2 = UIKitStreamingTableCard(initialLines: headerAndSep)
        #expect(card2 != nil)
    }

    @Test("Streaming Table Card Invalid Separator Returns Nil")
    @MainActor
    func streamingTableCardInvalidSeparatorReturnsNil() {
        let invalid = ["| A | B |", "| not separator |"]
        let card = UIKitStreamingTableCard(initialLines: invalid)
        #expect(card == nil)
    }

    @Test("Column Widths Sticky Upon Shorter Content")
    @MainActor
    func columnWidthsStickyUponShorterContent() {
        let card = UIKitStreamingTableCard(initialLines: [
            "| A | B |",
            "|---|---|",
            "| Longer initial text | Value |",
        ])
        #expect(card != nil)
        guard let card else { return }
        let h1 = card.intrinsicContentSize.height
        #expect(h1 > 0)

        card.updateLines([
            "| A | B |",
            "|---|---|",
            "| Short | Value |",
        ])
        let h2 = card.intrinsicContentSize.height
        #expect(h2 > 0)
        #expect(abs(h2 - h1) < 50)
    }

    @Test("Incremental Append Adds New Rows")
    @MainActor
    func incrementalAppendAddsNewRows() {
        let card = UIKitStreamingTableCard(initialLines: [
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
        ])
        #expect(card != nil)
        guard let card else { return }
        let h1 = card.intrinsicContentSize.height
        #expect(h1 > 0)

        card.updateLines([
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
            "| 3 | 4 |",
            "| 5 | 6 |",
        ])
        let h2 = card.intrinsicContentSize.height

        #expect(h2 > h1)
    }

    @Test("Update Last Row Text In Place")
    @MainActor
    func updateLastRowTextInPlace() {
        let card = UIKitStreamingTableCard(initialLines: [
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
        ])
        #expect(card != nil)
        guard let card else { return }
        let h1 = card.intrinsicContentSize.height

        card.updateLines([
            "| A | B |",
            "|---|---|",
            "| 1 | 2 revised |",
        ])
        let h2 = card.intrinsicContentSize.height
        #expect(h2 > 0)
        #expect(abs(h2 - h1) < 50)
    }

    @Test("Header Change Rebuilds")
    @MainActor
    func headerChangeRebuilds() {
        let card = UIKitStreamingTableCard(initialLines: [
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
        ])
        #expect(card != nil)
        guard let card else { return }

        card.updateLines([
            "| X | Y | Z |",
            "|---|---|---|",
            "| 1 | 2 | 3 |",
        ])
        #expect(card.intrinsicContentSize.height > 0)
    }

    @Test("Parse Table Row Consistency")
    func parseTableRowConsistency() {
        let line = "| Item | Notes |"
        let aCells = UIKitStreamingTableCard.parseTableRow(line)
        #expect(aCells == ["Item", "Notes"])
    }

    @Test("Parse Alignment Cases")
    func parseAlignmentCases() {
        #expect(UIKitStreamingTableCard.parseAlignment(":---:").textAlignment == .center)
        #expect(UIKitStreamingTableCard.parseAlignment("---:").textAlignment == .right)
        #expect(UIKitStreamingTableCard.parseAlignment(":---").textAlignment == .left)
        #expect(UIKitStreamingTableCard.parseAlignment("---").textAlignment == .left)
    }

    @Test("Streaming Narrow Table Fills Width Inside Collection View")
    @MainActor
    func streamingNarrowTableFillsWidthInsideCollectionView() throws {
        let cv = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let card = try #require(UIKitStreamingTableCard(initialLines: [
            "| Linear | Log |",
            "|---|---|",
            "| 1000 × 100 = 100000 | 3 + 2 = 5 |",
            "| 10th root | ÷10 |",
        ]))
        cv.addSubview(card)
        let contentWidth = ChatListViewController.assistantContentWidth(for: 390)
        card.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 200)
        card.setNeedsLayout()
        card.layoutIfNeeded()

        let scrollView = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(abs(scrollView.contentSize.width - contentWidth) < 0.5)
    }
}
