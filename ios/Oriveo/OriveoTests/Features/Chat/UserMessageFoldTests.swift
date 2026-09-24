import Testing
@testable import Oriveo

/// The long user message fold rule; Android's `UserMessageFoldTest` and the web's `user-message-fold.test.ts` check
/// the same cases.
@Suite("UserMessageFold rule and prefix")
struct UserMessageFoldTests {
    @Test("Exactly 6000 UTF-16 units do not fold, one more does")
    func thresholdBoundary() {
        let atThreshold = String(repeating: "a", count: UserMessageFold.thresholdUTF16)
        #expect(!UserMessageFold.shouldFold(atThreshold))
        #expect(UserMessageFold.shouldFold(atThreshold + "a"))
        // Counted in UTF-16: 3000 emoji (2 UTF-16 units each) do not fold, 3001 do.
        #expect(!UserMessageFold.shouldFold(String(repeating: "😀", count: 3_000)))
        #expect(UserMessageFold.shouldFold(String(repeating: "😀", count: 3_001)))
    }

    @Test("The preview is a prefix of the original and at most 2000 UTF-16 units")
    func previewIsBoundedPrefix() {
        let text = String(repeating: "هذا نص عربي طويل جدا. ", count: 10_000)
        let preview = UserMessageFold.preview(of: text)
        #expect(text.hasPrefix(preview))
        #expect(preview.utf16.count <= UserMessageFold.previewUTF16)
        #expect(preview.utf16.count > UserMessageFold.previewUTF16 - 30)
    }

    @Test("The preview cuts on grapheme boundaries: emoji sequences, surrogate pairs and combining marks stay whole")
    func previewCutsOnGraphemeBoundaries() {
        // The family emoji is an 11-unit ZWJ sequence; placed after 1999 "a"s, the prefix must stop before it.
        let family = "👩‍👩‍👧‍👦"
        let text = String(repeating: "a", count: UserMessageFold.previewUTF16 - 1) + family + String(repeating: "b", count: 8_000)
        let preview = UserMessageFold.preview(of: text)
        #expect(preview == String(repeating: "a", count: UserMessageFold.previewUTF16 - 1))

        // An Arabic letter with harakat: the base letter and its marks are one grapheme and are never cut apart.
        let marked = String(repeating: "بِّ", count: 3_000)
        let markedPreview = UserMessageFold.preview(of: marked)
        #expect(markedPreview.count * 3 == markedPreview.utf16.count, "every grapheme should keep all 3 UTF-16 units")
    }

    @Test("A message with many line breaks is capped at 60 of them")
    func previewCapsLineCount() {
        let text = String(repeating: "line\n", count: 5_000)
        let preview = UserMessageFold.preview(of: text)
        #expect(preview.filter { $0 == "\n" }.count == UserMessageFold.previewLineCap)
        #expect(text.hasPrefix(preview))
    }
}
