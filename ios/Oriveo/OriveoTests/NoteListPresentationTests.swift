import Foundation
import Testing
@testable import Oriveo

@Suite("NoteListPresentation", .serialized)
struct NoteListPresentationTests {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
    private func summary(_ note: Note) -> NoteSummary { NoteSummary(note) }

    @Test("Pinned First Then Updated")
    func pinnedFirstThenUpdated() {
        let a = summary(NoteTestFactories.makeNote(title: "a", isPinned: false, updatedAt: t(300)))
        let b = summary(NoteTestFactories.makeNote(title: "b", isPinned: true, updatedAt: t(100)))
        let c = summary(NoteTestFactories.makeNote(title: "c", isPinned: false, updatedAt: t(200)))
        let sorted = NoteListPresentation.sort([a, b, c], by: .updatedAt)
        #expect(sorted.map(\.title) == ["b", "a", "c"])
    }

    @Test("Created At Sort")
    func createdAtSort() {
        let a = summary(NoteTestFactories.makeNote(title: "old", createdAt: t(100), updatedAt: t(500)))
        let b = summary(NoteTestFactories.makeNote(title: "new", createdAt: t(400), updatedAt: t(200)))
        let sorted = NoteListPresentation.sort([a, b], by: .createdAt)
        #expect(sorted.map(\.title) == ["new", "old"])
    }

    @Test("Folder Filter")
    func folderFilter() {
        let f = UUID()
        let inFolder = summary(NoteTestFactories.makeNote(title: "in", noteFolderID: f))
        let unc = summary(NoteTestFactories.makeNote(title: "unc", noteFolderID: nil))
        let all = [inFolder, unc]
        #expect(NoteListPresentation.filterByFolder(all, filter: .all).count == 2)
        #expect(NoteListPresentation.filterByFolder(all, filter: .folder(f)).map(\.title) == ["in"])
        #expect(NoteListPresentation.filterByFolder(all, filter: .uncategorized).map(\.title) == ["unc"])
    }

    @Test("Tag And Filter")
    func tagAndFilter() {
        let both = summary(NoteTestFactories.makeNote(title: "both", tags: ["x", "y"]))
        let onlyX = summary(NoteTestFactories.makeNote(title: "x", tags: ["x"]))
        let result = NoteListPresentation.filterByTags([both, onlyX], tags: ["x", "y"])
        #expect(result.map(\.title) == ["both"])
        #expect(NoteListPresentation.filterByTags([both, onlyX], tags: []).count == 2)
    }

    @Test("All Tags Limit")
    func allTagsLimit() {
        let notes = (0..<20).map { i in summary(NoteTestFactories.makeNote(tags: ["tag\(i)"])) }
        #expect(NoteListPresentation.allTags(in: notes, limit: 12).count == 12)
        let dup = [summary(NoteTestFactories.makeNote(tags: ["a", "b"])),
                   summary(NoteTestFactories.makeNote(tags: ["a", "c"]))]
        #expect(NoteListPresentation.allTags(in: dup) == ["a", "b", "c"])
    }

    @Test("Tag Suggestions Exclude Current Tags")
    func tagSuggestionsExcludeCurrentTags() {
        let current = summary(NoteTestFactories.makeNote(tags: ["Vector", "swift"]))
        let other = summary(NoteTestFactories.makeNote(tags: ["vector", "research", "swiftui"]))
        let third = summary(NoteTestFactories.makeNote(tags: ["Research", "design"]))

        #expect(
            NoteListPresentation.tagSuggestions(
                in: [current, other, third],
                excluding: current.tags,
                limit: 12
            ) == ["research", "swiftui", "design"]
        )
    }

    @Test("Detail Applied Tags Use Active Style")
    func detailAppliedTagsUseActiveStyle() {
        let editableApplied = NoteTagChipPresentation.applied(editable: true)
        #expect(editableApplied.visualRole == .applied)
        #expect(editableApplied.showsRemoveAction)

        let readOnlyApplied = NoteTagChipPresentation.applied(editable: false)
        #expect(readOnlyApplied.visualRole == .applied)
        #expect(!readOnlyApplied.showsRemoveAction)

        #expect(NoteTagChipPresentation.suggestion.visualRole == .suggestion)
        #expect(!NoteTagChipPresentation.suggestion.showsRemoveAction)
    }

    @Test("Crosscheck Display Body Skips Internal Original Answer")
    func crosscheckDisplayBodySkipsInternalOriginalAnswer() {
        let body = "## Original answer\n\nOld answer\n\n## Cross-check (GPT-5)\n\nSecond opinion"
        #expect(NoteText.displayBody(body) == "Second opinion")
        #expect(NoteText.preview(from: body) == "Second opinion")
        #expect(NoteManager.placeholderTitle(fromPrompt: nil, body: NoteText.displayBody(body)) == "Second opinion")
    }

    @Test("Uncategorized")
    func uncategorized() {
        let notes = [summary(NoteTestFactories.makeNote(noteFolderID: UUID())),
                     summary(NoteTestFactories.makeNote(noteFolderID: nil)),
                     summary(NoteTestFactories.makeNote(noteFolderID: nil))]
        #expect(NoteListPresentation.uncategorizedCount(notes) == 2)
        #expect(NoteListPresentation.shouldShowUncategorizedFilter(uncategorizedCount: 0))
    }

    @Test("Blank Badge")
    func blankBadge() {
        let blank = summary(NoteTestFactories.makeNote(captureKind: .blank))
        #expect(blank.showsSourceBadge == false)
    }

    @Test("Quote Watermark Darker Than Light")
    func quoteWatermarkDarkerThanLight() {
        #expect(NoteCard.quoteWatermarkOpacity(isDark: true, hasSource: false)
                > NoteCard.quoteWatermarkOpacity(isDark: false, hasSource: false))
        #expect(NoteCard.quoteWatermarkOpacity(isDark: true, hasSource: true)
                > NoteCard.quoteWatermarkOpacity(isDark: false, hasSource: true))
        #expect(NoteCard.quoteWatermarkOpacity(isDark: true, hasSource: false, large: true)
                > NoteCard.quoteWatermarkOpacity(isDark: false, hasSource: false, large: true))
        #expect(NoteCard.quoteWatermarkOpacity(isDark: true, hasSource: true, large: true)
                > NoteCard.quoteWatermarkOpacity(isDark: false, hasSource: true, large: true))
    }
}

@Suite("Note Text Math Preview Tests")
struct NoteTextMathPreviewTests {

    @Test("Preview Strips Math Delimiters")
    func previewStripsMathDelimiters() {
        let body = "Conclusion: $E=mc^2$ and\n$$a+b=c$$"
        let preview = NoteText.preview(from: body)
        #expect(!preview.contains("$"))
        #expect(preview.contains("E=mc^2"))
        #expect(preview.contains("a+b=c"))
    }

    @Test("Preview Attributed Strips Dollar")
    func previewAttributedStripsDollar() {
        let attr = NoteText.previewAttributed(from: "See the $x^2$ formula")
        let plain = String(attr.characters)
        #expect(!plain.contains("$"))
        #expect(plain.contains("x^2"))
    }

    @Test("Currency Dollar Kept")
    func currencyDollarKept() {
        let preview = NoteText.preview(from: "Just a price of $5")
        #expect(preview.contains("$5"))
    }
}

@Suite("NoteText large body layout policy")
struct NoteTextLargeBodyLayoutTests {
    @Test("ordinary notes keep rich Markdown layout")
    func ordinaryNotesKeepRichLayout() {
        #expect(NoteText.requiresBoundedLayout(String(repeating: "a", count: 9_999)) == false)
    }

    @Test("the threshold is 10,000 UTF-16 units, inclusive")
    func thresholdIsTenThousandUTF16() {
        #expect(NoteText.boundedLayoutUTF16Threshold == 10_000)
        #expect(NoteText.requiresBoundedLayout(String(repeating: "a", count: 10_000)))
    }

    @Test("very large notes use the bounded TextKit viewport")
    func largeNotesUseBoundedLayout() {
        let text = String(repeating: "😊", count: NoteText.boundedLayoutUTF16Threshold / 2)
        #expect(NoteText.requiresBoundedLayout(text))
    }
}

@Suite("Note body editor session")
struct NoteBodyEditorSessionTests {
    private func body(_ count: Int) -> String { String(repeating: "a", count: count) }

    @Test("the editor is chosen by length when editing starts")
    func editorIsChosenByLengthOnEntry() {
        #expect(NoteBodyEditorSession(body: body(9_999)).editor == .plain)
        #expect(NoteBodyEditorSession(body: body(10_000)).editor == .bounded)
        #expect(NoteBodyEditorSession(body: body(10_000)).focusTakeover == nil)
    }

    @Test("crossing the threshold while editing moves up to the bounded view, once")
    func crossingUpwardUpgradesOnce() {
        var session = NoteBodyEditorSession(body: body(9_999))
        session.bodyDidChange(from: body(9_999), to: body(9_999) + "bc")
        #expect(session.editor == .bounded)
        #expect(session.focusTakeover == .init(sourceLocation: 10_001))

        // After the upgrade no change switches the editor again or re-issues the takeover request.
        let upgraded = session
        session.bodyDidChange(from: body(9_999) + "bc", to: body(5_000))
        session.bodyDidChange(from: body(5_000), to: body(20_000))
        #expect(session == upgraded)
    }

    @Test("changes below the threshold keep the plain editor")
    func changesBelowThresholdKeepPlainEditor() {
        var session = NoteBodyEditorSession(body: body(100))
        session.bodyDidChange(from: body(100), to: body(9_999))
        #expect(session.editor == .plain)
        #expect(session.focusTakeover == nil)
    }

    @Test("deleting below the threshold in the bounded view does not switch back")
    func deletingBelowThresholdKeepsBoundedEditor() {
        var session = NoteBodyEditorSession(body: body(10_000))
        session.bodyDidChange(from: body(10_000), to: body(5_000))
        #expect(session.editor == .bounded)
        #expect(session.focusTakeover == nil)
    }

    @Test("entering again after editing ends decides by the length at that time")
    func reenteringDecidesAgain() {
        var session = NoteBodyEditorSession(body: body(10_000))
        session.bodyDidChange(from: body(10_000), to: body(5_000))
        #expect(NoteBodyEditorSession(body: body(5_000)).editor == .plain)
    }

    @Test("after a paste in the middle the caret lands at the end of the inserted segment")
    func caretLandsAfterInsertedSegment() {
        let old = "あたまぶん" + "うしろがわ"
        let pasted = String(repeating: "か", count: 12_000)
        let new = "あたまぶん" + pasted + "うしろがわ"
        #expect(NoteText.caretLocationAfterEdit(from: old, to: new) == 5 + 12_000)

        var session = NoteBodyEditorSession(body: old)
        session.bodyDidChange(from: old, to: new)
        #expect(session.focusTakeover == .init(sourceLocation: 5 + 12_000))
    }

    @Test("replacing a selection, appending at the end, and the underivable case")
    func caretInferenceEdgeCases() {
        #expect(NoteText.caretLocationAfterEdit(from: "abXYZcd", to: "abQcd") == 3)
        #expect(NoteText.caretLocationAfterEdit(from: "abc", to: "abc") == nil)
        #expect(NoteText.caretLocationAfterEdit(from: "abc", to: "abcde") == 5)
        // Never inside a surrogate pair: replacing U+1F200 (D83C DE00) with U+1F600 (D83D DE00), which
        // share a low surrogate, makes the shared suffix cut into the pair.
        #expect(NoteText.caretLocationAfterEdit(from: "x\u{1F200}b", to: "x\u{1F600}b") == 3)
    }
}

@Suite("NoteText preview cost is bounded")
struct NoteTextPreviewCostTests {
    private static func largeBody(repeats: Int) -> String {
        let block = """
            ## Section heading
            Body **bold** and `code`.
            - List item
            > Quote line
            | Col A | Col B |
            Inline formula $E=mc^2$.

            """
        return String(repeating: block, count: repeats)
    }

    @Test("Large Body Preview Matches Small Body")
    func largeBodyPreviewMatchesSmallBody() {
        let small = Self.largeBody(repeats: 8)
        let large = Self.largeBody(repeats: 4_000)
        #expect(NoteText.preview(from: large) == NoteText.preview(from: small))
        #expect(String(NoteText.previewAttributed(from: large).characters)
                == String(NoteText.previewAttributed(from: small).characters))
    }

    @Test("Preview Cost Does Not Scale With Body Size")
    func previewCostDoesNotScaleWithBodySize() {
        let small = Self.largeBody(repeats: 8)
        let large = Self.largeBody(repeats: 4_000)

        func elapsed(_ body: String) -> Double {
            let start = DispatchTime.now()
            _ = NoteText.previewAttributed(from: body)
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }
        _ = elapsed(small)

        let largeMs = elapsed(large)
        #expect(largeMs < 150)
    }

    @Test("Crosscheck Preview Skips Long Original Answer")
    func crosscheckPreviewSkipsLongOriginalAnswer() {
        let longAnswer = String(repeating: "Original answer content.", count: 750)
        let body = "## Original answer\n\n\(longAnswer)\n\n## Cross-check (GPT-5)\n\nThe cross-check conclusion is here."
        let preview = NoteText.preview(from: body)
        #expect(preview.hasPrefix("The cross-check conclusion is here"))
        #expect(!preview.contains("Original answer content"))
    }

    @Test("Summary Projection Shares Recall Budget")
    func summaryProjectionSharesRecallBudget() {
        #expect(NoteSummary.bodyProjectionCharacters == NoteRecallCandidate.maxBodyCharacters)
    }

    @Test("Summary From Note Truncates Body")
    func summaryFromNoteTruncatesBody() {
        let oversized = String(repeating: "x", count: NoteSummary.bodyProjectionCharacters + 5_000)
        let summary = NoteSummary(NoteTestFactories.makeNote(title: "Large note", body: oversized))
        #expect(summary.body.count == NoteSummary.bodyProjectionCharacters)
    }
}
