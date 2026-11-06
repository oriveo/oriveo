import Foundation
import Testing
@testable import Oriveo

@Suite("Incremental streaming segment parser equivalence")
@MainActor
struct IncrementalStreamingSegmentParserTests {


    @Test("Empty Input")
    func emptyInput() {
        expectEquivalent("")
    }

    @Test("Plain Text Fast Path")
    func plainTextFastPath() {
        for input in [
            "hello world",
            "hello\nworld",
            "trailing\n",
            "\n\n\n",
            "use `inline` code but no fence",
            "## Heading\n- list item\n- another"
        ] {
            expectEquivalent(input)
        }
    }

    @Test("Closed Code Block")
    func closedCodeBlock() {
        expectEquivalent("```swift\nlet x = 1\n```")
        expectEquivalent("intro\n```swift\nlet x = 1\n```")
        expectEquivalent("intro\n```swift\nlet x = 1\n```\noutro")
        expectEquivalent("```\nplain code\n```")
    }

    @Test("Unclosed Code Block")
    func unclosedCodeBlock() {
        expectEquivalent("intro\n```swift\ncode here")
        expectEquivalent("```\nbare unclosed")
    }

    @Test("Tables")
    func tables() {
        expectEquivalent("| A | B |\n|---|---|\n| 1 | 2 |")
        expectEquivalent("| A | B |\n|---|---|")
        expectEquivalent("intro\n| A | B |\n|---|---|\n| 1 | 2 |\noutro") // closed mid-text
        expectEquivalent("intro\n| A | B |\n|---|---|\n| 1 | 2 |") // still growing at the end
    }

    @Test("Mixed")
    func mixed() {
        expectEquivalent("""
         1

        ```swift
        let x = 1
        ```

        

        | A | B |
        |---|---|
        | 1 | 2 |

        ```python
        x = 2
        ```

        
        """)
    }


    @Test("Incremental Plain Text")
    func incrementalPlainText() {
        let full = "hello world\nthis is line 2\nand line 3"
        expectEquivalentSequence(full, stepSize: 3)
    }

    @Test("Incremental Closed Code Block")
    func incrementalClosedCodeBlock() {
        let full = "intro\n```swift\nlet x = 1\nlet y = 2\n```\noutro"
        expectEquivalentSequence(full, stepSize: 2)
    }

    @Test("Incremental Multiple Code Blocks")
    func incrementalMultipleCodeBlocks() {
        let full = """
         1
        ```swift
        let x = 1
        ```
        
        ```python
        y = 2
        ```
        
        """
        expectEquivalentSequence(full, stepSize: 1)
    }

    @Test("Incremental Table")
    func incrementalTable() {
        let full = "intro\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\noutro"
        expectEquivalentSequence(full, stepSize: 2)
    }

    @Test("Incremental Char By Char")
    func incrementalCharByChar() {
        let full = "intro\n```swift\nlet x = 1\n```\nmiddle\n| A | B |\n|---|---|\n| 1 | 2 |"
        expectEquivalentSequence(full, stepSize: 1)
    }


    @Test("Reset Behavior")
    func resetBehavior() {
        let parser = IncrementalStreamingSegmentParser()
        _ = parser.parse("intro\n```swift\nlet x = 1\n```")
        parser.reset()
        let after = parser.parse("hello world")
        let staticResult = StreamingSegmentParser.parse("hello world")
        #expect(after == staticResult)
    }

    @Test("Prefix Change Fallback")
    func prefixChangeFallback() {
        let parser = IncrementalStreamingSegmentParser()
        _ = parser.parse("```swift\nlet x = 1\n```")
        let new = "| A | B |\n|---|---|\n| 1 | 2 |"
        let result = parser.parse(new)
        let staticResult = StreamingSegmentParser.parse(new)
        #expect(result == staticResult)
    }

    @Test("Shorter Input Fallback")
    func shorterInputFallback() {
        let parser = IncrementalStreamingSegmentParser()
        _ = parser.parse("intro\n```swift\nlet x = 1\n```\noutro")
        let shorter = "intro"
        let result = parser.parse(shorter)
        let staticResult = StreamingSegmentParser.parse(shorter)
        #expect(result == staticResult)
    }

    @Test("Same Text Cache")
    func sameTextCache() {
        let parser = IncrementalStreamingSegmentParser()
        let text = "intro\n```swift\nlet x = 1\n```"
        let first = parser.parse(text)
        let second = parser.parse(text)
        #expect(first == second)
        #expect(first == StreamingSegmentParser.parse(text))
    }

    @Test("Fast Path To Structured Transition")
    func fastPathToStructuredTransition() {
        let parser = IncrementalStreamingSegmentParser()
        _ = parser.parse("plain text no structure")
        let structured = "plain text no structure\n```swift\nlet x = 1\n```"
        let result = parser.parse(structured)
        let staticResult = StreamingSegmentParser.parse(structured)
        #expect(result == staticResult)
    }

    // MARK: - Helpers

    private func expectEquivalent(_ input: String) {
        let parser = IncrementalStreamingSegmentParser()
        let incremental = parser.parse(input)
        let staticResult = StreamingSegmentParser.parse(input)
        #expect(incremental == staticResult, "Incremental parse diverged from static for input: \(input)")
    }

    private func expectEquivalentSequence(_ full: String, stepSize: Int) {
        let parser = IncrementalStreamingSegmentParser()
        var cursor = full.startIndex
        var step = 0
        while cursor < full.endIndex {
            let advance = full.index(cursor, offsetBy: stepSize, limitedBy: full.endIndex) ?? full.endIndex
            let prefix = String(full[full.startIndex..<advance])
            let incremental = parser.parse(prefix)
            let staticResult = StreamingSegmentParser.parse(prefix)
            #expect(
                incremental == staticResult,
                "Step \(step) (prefix len \(prefix.count)) diverged: incremental=\(incremental) static=\(staticResult)"
            )
            cursor = advance
            step += 1
        }
    }

    // MARK: - Bridged input and byte-wise prefix

    @Test("input bridged from NSString stays equivalent to the static parser")
    func bridgedInputEquivalent() {
        let parser = IncrementalStreamingSegmentParser()
        let source = "\u{4E2D}\u{6587}\n```swift\nlet a = 1\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n\u{7ED3}\u{675F}\n"
        let ns = source as NSString
        for length in 1...ns.length {
            let frame = ns.substring(to: length)
            #expect(describe(parser.parse(frame)) == describe(StreamingSegmentParser.parse(frame)), "length \(length)")
        }
    }

    @Test("hasUTF8Prefix handles empty, equal, longer and bridged operands")
    func utf8Prefix() {
        let native = "\u{4E2D}\u{6587}abc"
        let ns = native as NSString
        #expect(native.hasUTF8Prefix(""))
        #expect("".hasUTF8Prefix(""))
        #expect(!"".hasUTF8Prefix("a"))
        #expect(native.hasUTF8Prefix(native))
        #expect(!native.hasUTF8Prefix(native + "d"))
        #expect(native.hasUTF8Prefix(ns.substring(to: 2)))
        #expect(ns.substring(to: 4).hasUTF8Prefix(ns.substring(to: 3)))
        #expect(!native.hasUTF8Prefix("\u{4E2D}\u{5B57}"))
    }

    @Test("containsFenceOrPipe matches contains for fences and pipes")
    func fenceOrPipeScan() {
        let cases = ["", "plain", "a`b``c", "``", "```", "a```b", "x``y`z", "a|b", "\u{4E2D}\u{6587}", "\u{4E2D}|\u{6587}", "\u{4E2D}```"]
        for text in cases {
            let bridged = ((text + "\u{6587}") as NSString).substring(to: (text as NSString).length)
            let expected = text.contains("```") || text.contains("|")
            #expect(text.containsFenceOrPipe == expected, "\(text)")
            #expect(bridged.containsFenceOrPipe == expected, "\(text)")
        }
    }

    private func describe(_ parsed: StreamingSegmentParser.ParsedContent) -> String {
        String(reflecting: parsed)
    }
}
