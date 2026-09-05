import Foundation
import Testing
@testable import Oriveo

@Suite("StreamingSegmentParser - pure parsing")
struct StreamingSegmentParserTests {


    @Test("Parse Plain Text")
    func parsePlainText() {
        let parsed = StreamingSegmentParser.parse("hello world\nsecond line")
        #expect(parsed.streamingTable == nil)
        #expect(parsed.committed.isEmpty)
        #expect(parsed.tail == "hello world\nsecond line")
    }

    @Test("Parse Plain Text Fast Path Preserves Trailing Newlines")
    func parsePlainTextFastPathPreservesTrailingNewlines() {
        for input in ["a\nb\n", "a\n\n", "trailing space  \nx", "", "single", "\n\n\n"] {
            let parsed = StreamingSegmentParser.parse(input)
            #expect(parsed.committed.isEmpty)
            #expect(parsed.streamingTable == nil)
            #expect(parsed.tail == input)
        }
    }

    @Test("Parse Plain Text Fast Path Inline Code")
    func parsePlainTextFastPathInlineCode() {
        for input in ["use `let x` here", "double ``backtick`` text", "no code at all"] {
            let parsed = StreamingSegmentParser.parse(input)
            #expect(parsed.committed.isEmpty)
            #expect(parsed.tail == input)
        }
    }

    @Test("Parse Does Not Short Circuit On Code Or Table")
    func parseDoesNotShortCircuitOnCodeOrTable() {
        let withCode = StreamingSegmentParser.parse("intro\n```swift\nlet x = 1\n```")
        #expect(withCode.committed.contains { if case .codeBlock = $0.kind { return true }; return false })

        let withTable = StreamingSegmentParser.parse("note:\n| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(withTable.streamingTable != nil)
    }

    @Test("Parse Plain Text Before Unclosed Code Stays In Tail")
    func parsePlainTextBeforeUnclosedCodeStaysInTail() {
        let text = """
        The first paragraph of the answer.

        The second paragraph is still going.
        ```swift
        let x = 1
        """
        let parsed = StreamingSegmentParser.parse(text)

        #expect(parsed.committed.isEmpty)
        #expect(parsed.tail.contains("The first paragraph of the answer."))
        #expect(parsed.tail.contains("The second paragraph is still going."))
        #expect(parsed.tail.contains("```swift"))
    }

    @Test("Parse Single Closed Code Block")
    func parseSingleClosedCodeBlock() {
        let text = """
        intro
        ```swift
        let x = 1
        ```
        """
        let parsed = StreamingSegmentParser.parse(text)
        let codeBlocks = parsed.committed.compactMap { seg -> (String?, String)? in
            if case let .codeBlock(lang) = seg.kind { return (lang, seg.content) }
            return nil
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks.first?.0 == "swift")
        #expect(codeBlocks.first?.1 == "let x = 1")
    }

    @Test("Parse Multiple Closed Code Blocks")
    func parseMultipleClosedCodeBlocks() {
        let text = """
        ```python
        a = 1
        ```
        text in between
        ```js
        const b = 2
        ```
        still active at the end
        """
        let parsed = StreamingSegmentParser.parse(text)
        let codeBlocks = parsed.committed.compactMap { seg -> String? in
            if case let .codeBlock(lang) = seg.kind { return lang }
            return nil
        }
        #expect(codeBlocks == ["python", "js"])
    }

    @Test("Parse Unclosed Code Block")
    func parseUnclosedCodeBlock() {
        let text = """
        intro
        ```swift
        let x = 1
        """
        let parsed = StreamingSegmentParser.parse(text)
        #expect(parsed.tail.contains("```swift"))
        #expect(parsed.tail.contains("let x = 1"))
    }

    @Test("Parse Unclosed Code Block No Language")
    func parseUnclosedCodeBlockNoLanguage() {
        let text = """
        ```
        bare code
        """
        let parsed = StreamingSegmentParser.parse(text)
        #expect(parsed.tail.hasPrefix("```"))
        #expect(parsed.tail.contains("bare code"))
    }

    // MARK: - splitTailAtUnclosedFence

    @Test("Split Tail No Fence")
    func splitTailNoFence() {
        let (text, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence("just plain text")
        #expect(text == "just plain text")
        #expect(unclosed == nil)
    }

    @Test("Split Tail Single Unclosed")
    func splitTailSingleUnclosed() {
        let tail = """
        text before
        ```swift
        let x = 1
        """
        let (text, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(tail)
        #expect(text == "text before")
        #expect(unclosed?.language == "swift")
        #expect(unclosed?.code == "let x = 1")
    }

    @Test("Split Tail Even Fences")
    func splitTailEvenFences() {
        let tail = """
        ```py
        a = 1
        ```
        more text
        """
        let (_, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(tail)
        #expect(unclosed == nil)
    }

    @Test("Split Tail Odd Triple Fences")
    func splitTailOddTripleFences() {
        let tail = """
        ```py
        a = 1
        ```
        text in between
        ```js
        let b = 2
        """
        let (text, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(tail)
        #expect(unclosed?.language == "js")
        #expect(unclosed?.code == "let b = 2")
        #expect(text.contains("```py"))
        #expect(text.contains("text in between"))
    }

    // MARK: - textContainsGFMTable

    @Test("Gfm Table Valid Columns True")
    func gfmTableValidColumnsTrue() {
        let text = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        #expect(StreamingSegmentParser.textContainsGFMTable(text) == true)
    }

    @Test("Gfm Table Mismatched Columns False")
    func gfmTableMismatchedColumnsFalse() {
        let text = """
        | A | B | C |
        |---|---|
        """
        #expect(StreamingSegmentParser.textContainsGFMTable(text) == false)
    }

    @Test("Gfm Table Single Line False")
    func gfmTableSingleLineFalse() {
        #expect(StreamingSegmentParser.textContainsGFMTable("| A | B |") == false)
    }

    @Test("Gfm Table Plain Text False")
    func gfmTablePlainTextFalse() {
        #expect(StreamingSegmentParser.textContainsGFMTable("hello\nworld") == false)
    }

    @Test("Gfm Table No Separator False")
    func gfmTableNoSeparatorFalse() {
        let text = """
        | A | B |
        | 1 | 2 |
        """
        #expect(StreamingSegmentParser.textContainsGFMTable(text) == false)
    }

    // MARK: - splitTextSegmentsForTables

    @Test("Split Text Table Embedded")
    func splitTextTableEmbedded() {
        let text = """
        intro paragraph
        | A | B |
        |---|---|
        | 1 | 2 |
        following paragraph
        """
        let input = [StreamingSegmentParser.Segment(kind: .text, content: text)]
        let split = StreamingSegmentParser.splitTextSegmentsForTables(input)
        let tableSegs = split.filter {
            if case .table = $0.kind { return true }
            return false
        }
        let textSegs = split.filter {
            if case .text = $0.kind { return true }
            return false
        }
        #expect(tableSegs.count == 1)
        #expect(textSegs.count >= 1)
        #expect(textSegs.contains { $0.content.contains("intro paragraph") })
    }

    @Test("Split Text Keeps Code Blocks")
    func splitTextKeepsCodeBlocks() {
        let codeBlock = StreamingSegmentParser.Segment(kind: .codeBlock(language: "py"), content: "x = 1")
        let result = StreamingSegmentParser.splitTextSegmentsForTables([codeBlock])
        #expect(result.count == 1)
        if case let .codeBlock(lang) = result[0].kind {
            #expect(lang == "py")
        } else {
            Issue.record("Expected codeBlock to be preserved, got \(result[0].kind)")
        }
    }

    @Test("Split Text No Table Unchanged")
    func splitTextNoTableUnchanged() {
        let text = "plain text with no table\nthe second line has none either"
        let input = [StreamingSegmentParser.Segment(kind: .text, content: text)]
        let result = StreamingSegmentParser.splitTextSegmentsForTables(input)
        #expect(result.count == 1)
        #expect(result[0].content == text)
    }


    @Test("Parse Lifts Closed Table From Tail")
    func parseLiftsClosedTableFromTail() {
        let text = """
        | A | B |
        |---|---|
        | 1 | 2 |

        text keeps being generated after the table
        """
        let parsed = StreamingSegmentParser.parse(text)
        let tableSegs = parsed.committed.filter {
            if case .table = $0.kind { return true }
            return false
        }
        #expect(tableSegs.count == 1)
        #expect(parsed.streamingTable == nil)
        #expect(parsed.tail.contains("text keeps being generated"))
    }

    @Test("Parse Extracts Trailing Table")
    func parseExtractsTrailingTable() {
        let text = """
        The explanation above:
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let parsed = StreamingSegmentParser.parse(text)
        #expect(parsed.streamingTable != nil)
        #expect(parsed.streamingTable?.count == 3)
        #expect(parsed.tail == "The explanation above:")
    }


    @Test("Table Lines Inside Unclosed Fence Stay In Code")
    func tableLinesInsideUnclosedFenceStayInCode() {
        let text = "Intro.\n```markdown\n# Title\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let parsed = StreamingSegmentParser.parse(text)
        #expect(parsed.committed.isEmpty)
        #expect(parsed.streamingTable == nil)
        let (before, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(parsed.tail)
        #expect(before == "Intro.")
        #expect(unclosed?.language == "markdown")
        #expect(unclosed?.code.contains("|---|---|") == true)
    }

    @Test("Closed Fence With Table Content Commits As Code")
    func closedFenceWithTableContentCommitsAsCode() {
        let streaming = "Intro.\n```markdown\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let closed = streaming + "```\nend"
        #expect(StreamingSegmentParser.parse(streaming).committed.isEmpty)
        let parsed = StreamingSegmentParser.parse(closed)
        #expect(parsed.committed.count == 2)
        guard parsed.committed.count == 2,
              case .text = parsed.committed[0].kind,
              case .codeBlock(let lang) = parsed.committed[1].kind else {
            Issue.record("committed segments should be [text, codeBlock]")
            return
        }
        #expect(lang == "markdown")
        #expect(parsed.committed[1].content == "| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(parsed.tail == "end")
    }

    @Test("Unclosed Fence Precomputed Equivalence")
    func unclosedFencePrecomputedEquivalence() {
        let cases = [
            "Intro.\n```swift\nlet a = 1",
            "Intro.\n```swift\nlet a = 1\n",
            "```\ncode only",
            "Paragraph one\n\n```python\n",
            "Paragraph one\n\n```python",
            "plain text with no code block",
            "closed\n```js\nx()\n```\nfollowing text",
            "| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n",
        ]
        for text in cases {
            let parsed = StreamingSegmentParser.parse(text)
            let (textPart, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(parsed.tail)
            if let unclosed {
                #expect(parsed.unclosedFence?.textBefore == textPart, "textBefore differs: \(text)")
                #expect(parsed.unclosedFence?.language == unclosed.language, "language differs: \(text)")
                #expect(parsed.unclosedFence?.code == unclosed.code, "code differs: \(text)")
            } else {
                #expect(parsed.unclosedFence == nil, "there should be no unclosed fence: \(text)")
            }
        }
    }

    @Test("Closed Table Before Fence Still Lifts")
    func closedTableBeforeFenceStillLifts() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n"
        let parsed = StreamingSegmentParser.parse(text)
        #expect(parsed.committed.contains { seg in
            if case .table = seg.kind { return true }
            return false
        })
        #expect(parsed.streamingTable == nil)
        let (_, unclosed) = StreamingSegmentParser.splitTailAtUnclosedFence(parsed.tail)
        #expect(unclosed?.language == "swift")
        #expect(unclosed?.code == "let x = 1")
    }
}
