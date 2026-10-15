import Foundation
import Testing
@testable import Oriveo

/// Note body draft handoff and the wide right column's default note.
///
/// Contract:
/// 1. Stored and taken by note id, removed once taken;
/// 2. In one column only a stash under 2 seconds old counts; an expired one is discarded and removed too;
/// 3. In the right column (isSplitColumnRoot) it does not expire;
/// 4. The right column's default note: keep the last id while it is in the list, otherwise take the first.
@Suite("Notes · body draft handoff")
@MainActor
struct NoteBodyDraftHandoffTests {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }

    @Test("Stored and taken by note id, removed once taken")
    func stashAndTakeOnce() {
        let clock = Clock()
        let handoff = NoteBodyDraftHandoff(now: { clock.now })
        let noteA = UUID()
        let noteB = UUID()
        handoff.stash(noteID: noteA, draft: "draft A")

        #expect(handoff.take(noteID: noteB, isSplitColumnRoot: false) == nil)
        #expect(handoff.take(noteID: noteA, isSplitColumnRoot: false) == "draft A")
        #expect(handoff.take(noteID: noteA, isSplitColumnRoot: false) == nil)
    }

    @Test("Stashing the same note again replaces the earlier draft")
    func restashOverwrites() {
        let handoff = NoteBodyDraftHandoff()
        let note = UUID()
        handoff.stash(noteID: note, draft: "old")
        handoff.stash(noteID: note, draft: "new")
        #expect(handoff.take(noteID: note, isSplitColumnRoot: false) == "new")
    }

    @Test("Cancel or Save clears this note's stash and leaves other notes alone")
    func clearRemovesOnlyThatNote() {
        let handoff = NoteBodyDraftHandoff()
        let noteA = UUID()
        let noteB = UUID()
        handoff.stash(noteID: noteA, draft: "A")
        handoff.stash(noteID: noteB, draft: "B")
        handoff.clear(noteID: noteA)

        #expect(handoff.take(noteID: noteA, isSplitColumnRoot: true) == nil)
        #expect(handoff.take(noteID: noteB, isSplitColumnRoot: true) == "B")
    }

    @Test("One column: restored within 2 seconds, discarded and removed after")
    func compactExpiresAfterFreshnessWindow() {
        let clock = Clock()
        let handoff = NoteBodyDraftHandoff(now: { clock.now })
        let fresh = UUID()
        let stale = UUID()
        handoff.stash(noteID: fresh, draft: "fresh")
        handoff.stash(noteID: stale, draft: "stale")

        clock.now += NoteBodyDraftHandoff.freshnessWindow
        #expect(handoff.take(noteID: fresh, isSplitColumnRoot: false) == "fresh")

        clock.now += 0.5
        #expect(handoff.take(noteID: stale, isSplitColumnRoot: false) == nil)
        // The expired take already removed it, so even the right column gets nothing
        #expect(handoff.take(noteID: stale, isSplitColumnRoot: true) == nil)
    }

    @Test("Right column: restored even past the lifetime")
    func splitColumnDoesNotExpire() {
        let clock = Clock()
        let handoff = NoteBodyDraftHandoff(now: { clock.now })
        let note = UUID()
        handoff.stash(noteID: note, draft: "kept")
        clock.now += 600
        #expect(handoff.take(noteID: note, isSplitColumnRoot: true) == "kept")
    }

    @Test("Restore rule: no limit in the right column, 2 seconds in one column")
    func restoreCriterion() {
        let stashedAt = Date(timeIntervalSinceReferenceDate: 0)
        let window = NoteBodyDraftHandoff.freshnessWindow
        #expect(window == 2)
        #expect(NoteBodyDraftHandoff.shouldRestore(stashedAt: stashedAt, now: stashedAt + window, isSplitColumnRoot: false))
        #expect(!NoteBodyDraftHandoff.shouldRestore(stashedAt: stashedAt, now: stashedAt + window + 0.001, isSplitColumnRoot: false))
        #expect(NoteBodyDraftHandoff.shouldRestore(stashedAt: stashedAt, now: stashedAt + 3_600, isSplitColumnRoot: true))
    }

    @Test("Right-column default note: kept while in the list, otherwise or the first time the first note")
    func splitDefaultNoteResolution() {
        let a = UUID(), b = UUID(), c = UUID()
        // First time
        #expect(NotesView.resolveSplitDefaultNoteID(current: nil, displayedIDs: [a, b, c]) == a)
        // A sort change does not jump
        #expect(NotesView.resolveSplitDefaultNoteID(current: a, displayedIDs: [c, b, a]) == a)
        // No longer in the current filtered list
        #expect(NotesView.resolveSplitDefaultNoteID(current: a, displayedIDs: [b, c]) == b)
        // Empty list
        #expect(NotesView.resolveSplitDefaultNoteID(current: a, displayedIDs: []) == nil)
    }
}
