import QuartzCore
import Testing
@testable import Oriveo

/// Cost of deriving note card previews. NotesView's body reads the search query, so every keystroke
/// re-evaluates the page and a screen of cards (10 per page) derives its previews again in init.
/// Wall-clock numbers are printed only.
@MainActor
@Suite("Note card preview cost", .serialized)
struct NoteCardPreviewCostTests {
    private func aiStyleBody(_ index: Int) -> String {
        let paragraph = "This is a **long** paragraph with `inline code`, a [link](https://example.com/\(index)) and some $x^2$ math that an assistant might write when explaining things in detail. "
        return """
        ## Summary \(index)

        \(String(repeating: paragraph, count: 6))

        ### Key points

        - First point with *emphasis* and more text \(index)
        - Second point with ~~strike~~ text
        1. Numbered item one
        2. Numbered item two

        > A quoted remark that spans a line.

        | Column | Value |
        |---|---|
        | alpha | 1 |
        | beta | 2 |

        ```swift
        let value = compute(\(index))
        print(value)
        ```

        \(String(repeating: paragraph, count: 8))
        """
    }

    @Test("a screen of 10 cards derives previews once, then hits the cache by body, and recomputes as soon as the body changes")
    func tenCardsRebuildPreview() {
        let token = UUID().uuidString
        let summaries = (0..<10).map { index in
            NoteSummary(NoteTestFactories.makeNote(title: "Note \(index)", body: aiStyleBody(index) + token))
        }
        var start = CACurrentMediaTime()
        for summary in summaries {
            _ = NoteCard(summary: summary)
        }
        let firstPass = CACurrentMediaTime() - start

        let rounds = 5
        start = CACurrentMediaTime()
        for _ in 0..<rounds {
            for summary in summaries {
                _ = NoteCard(summary: summary)
            }
        }
        let cachedPass = (CACurrentMediaTime() - start) / Double(rounds)

        var uncached: CFTimeInterval = 0
        for _ in 0..<rounds {
            start = CACurrentMediaTime()
            for summary in summaries {
                _ = NoteText.previewAttributed(from: summary.body)
            }
            uncached += CACurrentMediaTime() - start
        }
        print("""
        [HANG-COST] note list, 10 cards per screen (body about \(summaries[0].body.count) characters), preview cost per body: \
        derived per card \(String(format: "%.1f", uncached / Double(rounds) * 1000))ms, first pass \(String(format: "%.1f", firstPass * 1000))ms, \
        cached \(String(format: "%.2f", cachedPass * 1000))ms
        """)

        // The cached preview matches direct derivation exactly, and an edited body gets a new preview.
        let body = summaries[3].body
        #expect(NoteCard.preview(for: body) == NoteText.previewAttributed(from: body))
        let edited = body.replacingOccurrences(of: "## Summary 3", with: "## Revised summary")
        #expect(String(NoteCard.preview(for: edited).characters).contains("Revised summary"))
        #expect(NoteCard.preview(for: edited) == NoteText.previewAttributed(from: edited))
    }
}
