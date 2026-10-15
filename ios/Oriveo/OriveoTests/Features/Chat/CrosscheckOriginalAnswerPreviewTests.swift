import Foundation
import Testing
@testable import Oriveo

@Suite("CrosscheckOriginalAnswerPreview")
struct CrosscheckOriginalAnswerPreviewTests {
    @Test("Original answer preview drops bold, list markers, headings, inline code and links, keeping only text")
    func previewStripsMarkdownMarkers() {
        let answer = """
        ## Conclusion

        **Consistency beats intensity**

        1. **Read first**, then write
        2. Review with `git log`
        - See [Stoic notes](https://example.com/notes)
        """
        let preview = CrosscheckSheet.originalAnswerPreview(for: answer)
        #expect(preview == "Conclusion Consistency beats intensity Read first, then write Review with git log See Stoic notes")
        for marker in ["**", "`", "##", "](", "1. ", "- "] {
            #expect(!preview.contains(marker), "leftover marker \(marker)")
        }
    }

    @Test("Original answer preview still truncates to 220 characters with an ellipsis after stripping")
    func previewTruncatesAfterStripping() {
        let answer = (0..<80).map { "**bold\($0)**" }.joined(separator: "\n")
        let preview = CrosscheckSheet.originalAnswerPreview(for: answer)
        #expect(!preview.contains("**"))
        #expect(preview.hasSuffix("..."))
        #expect(preview.count <= 223)
    }

    @Test("Short plain-text original answer is returned as is")
    func plainShortAnswerUnchanged() {
        #expect(CrosscheckSheet.originalAnswerPreview(for: "  Plain answer.\n\nSecond line. ") == "Plain answer. Second line.")
    }
}
