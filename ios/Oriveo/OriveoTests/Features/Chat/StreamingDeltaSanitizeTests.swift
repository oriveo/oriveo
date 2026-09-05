import Foundation
import Testing
@testable import Oriveo

@Suite("Streaming Delta Sanitize Tests")
struct StreamingDeltaSanitizeTests {

    @Test("Strips Leading Whitespace On First Delta")
    func stripsLeadingWhitespaceOnFirstDelta() {
        #expect(ChatManager.sanitizedStreamingDelta("\n\nbody", accumulatedIsEmpty: true) == "body")
        #expect(ChatManager.sanitizedStreamingDelta(" \t\r\nhello", accumulatedIsEmpty: true) == "hello")
    }

    @Test("Skips Whitespace Only First Delta")
    func skipsWhitespaceOnlyFirstDelta() {
        #expect(ChatManager.sanitizedStreamingDelta("\n\n", accumulatedIsEmpty: true) == nil)
        #expect(ChatManager.sanitizedStreamingDelta("   ", accumulatedIsEmpty: true) == nil)
        #expect(ChatManager.sanitizedStreamingDelta("", accumulatedIsEmpty: true) == nil)
    }

    @Test("Keeps Delta Verbatim After First Visible Char")
    func keepsDeltaVerbatimAfterFirstVisibleChar() {
        #expect(ChatManager.sanitizedStreamingDelta("\n\n## Heading", accumulatedIsEmpty: false) == "\n\n## Heading")
        #expect(ChatManager.sanitizedStreamingDelta("  indented", accumulatedIsEmpty: false) == "  indented")
        #expect(ChatManager.sanitizedStreamingDelta("\n", accumulatedIsEmpty: false) == "\n")
    }

    @Test("Strips Across Consecutive Whitespace Deltas")
    func stripsAcrossConsecutiveWhitespaceDeltas() {
        var accumulated = ""
        for delta in ["\n", "\n ", "\tbody starts", ", continues"] {
            if let s = ChatManager.sanitizedStreamingDelta(delta, accumulatedIsEmpty: accumulated.isEmpty) {
                accumulated.append(s)
            }
        }
        #expect(accumulated == "body starts, continues")
    }

    @Test("Streaming Accumulation Stays Prefix Of Trimmed Final")
    func streamingAccumulationStaysPrefixOfTrimmedFinal() {
        let deltas = ["\n\nHere ", "are **Python, ", "Go, JavaScript", "** quicksort implementations.\n\n---\n\n## Python"]
        let finalText = deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        var accumulated = ""
        for delta in deltas {
            if let s = ChatManager.sanitizedStreamingDelta(delta, accumulatedIsEmpty: accumulated.isEmpty) {
                accumulated.append(s)
            }
            #expect(finalText.hasPrefix(accumulated))
        }
        #expect(accumulated == finalText)
    }

    @Test("Matches Service Trim Semantics")
    func matchesServiceTrimSemantics() {
        let samples = ["\u{00A0}\nleading", "\r\n\r\nbody", "\n \t mixed"]
        for raw in samples {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = ChatManager.sanitizedStreamingDelta(raw, accumulatedIsEmpty: true)
            #expect(sanitized == (trimmed.isEmpty ? nil : trimmed))
        }
    }
}
