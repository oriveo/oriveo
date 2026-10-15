import Foundation

/// Hands over the note body being edited; one per window, owned by `NavigationManager`.
///
/// Changing carrier (two columns ↔ one) or switching to another note in the right column rebuilds `NoteDetailView` from scratch, losing an unsaved body draft.
/// The old view's onDisappear stashes the draft by note id when it is being edited and differs from the saved body; the new view takes it once when it appears.
/// Nothing is written to the store: Save keeps its meaning and the stash lives only in memory.
@MainActor
final class NoteBodyDraftHandoff {
    /// Lifetime in one column: a carrier change and the new view's appearance are a frame or two apart, so an older stash is unrelated to this entry.
    nonisolated static let freshnessWindow: TimeInterval = 2

    private struct Entry {
        let draft: String
        let stashedAt: Date
    }

    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Stashed when the old detail leaves; stashing the same note again replaces the earlier draft.
    func stash(noteID: UUID, draft: String) {
        entries[noteID] = Entry(draft: draft, stashedAt: now())
    }

    /// Clears this note's stash on Cancel or Save.
    func clear(noteID: UUID) {
        entries[noteID] = nil
    }

    /// Taken once when the new detail appears; the entry is removed whether or not it can be restored (an expired stash does not linger for the next visit).
    func take(noteID: UUID, isSplitColumnRoot: Bool) -> String? {
        guard let entry = entries.removeValue(forKey: noteID) else { return nil }
        guard Self.shouldRestore(stashedAt: entry.stashedAt, now: now(), isSplitColumnRoot: isSplitColumnRoot) else {
            return nil
        }
        return entry.draft
    }

    /// Restore rule: switching back to the note in the right column has no time limit (the column stays, so the draft waits for the user); in one column only the frame or two right after a carrier change counts.
    nonisolated static func shouldRestore(stashedAt: Date, now: Date, isSplitColumnRoot: Bool) -> Bool {
        isSplitColumnRoot || now.timeIntervalSince(stashedAt) <= freshnessWindow
    }
}
