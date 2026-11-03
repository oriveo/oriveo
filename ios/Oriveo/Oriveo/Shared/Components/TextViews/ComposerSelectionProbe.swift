import Foundation

/// The selection outlet of `ComposerTextView`: the host (dictation) reads the current selection and inserts
/// transcribed text at it.
///
/// The host creates an instance and passes it to `ComposerTextView(selectionProbe:)`; the input attaches itself
/// once its view is built. `range` is always a UTF-16 range in the source text (the text in the binding,
/// without display-layer soft breaks).
@MainActor
final class ComposerSelectionProbe {
    /// The current selection as UTF-16 offsets in the source text; length == 0 means a caret. The last selection
    /// is kept after the input is replaced.
    private(set) var range = NSRange(location: 0, length: 0)

    /// The attached input; disconnects automatically once the input is destroyed.
    private weak var textView: ComposerUITextView?

    /// Whether the input has ever published a selection: after it is replaced the insert uses that selection,
    /// and with none ever published it appends at the end.
    private var hasSelection = false

    /// The length limit and over-limit callback of the most recently attached input, so an insert still truncates
    /// and still notifies after the input is replaced (for example by the recording bar). If nothing was ever
    /// attached the chat input limit applies and there is no callback to call.
    private var maxLength: Int? = ChatInputLimit.maxUTF16
    private var onLengthLimitExceeded: (@MainActor () -> Void)?

    /// Source text and selection when a live-text generation (the DictationLiveText code) starts writing; written = live text has been written (so a retract has something to undo).
    private struct LiveBase {
        let generation: Int
        let text: String
        let selection: NSRange
        let hadSelection: Bool
        var written = false
    }

    private var liveBase: LiveBase?

    /// This generation has already written live text into the input box (while recording); the input box pauses undo / redo on this basis.
    var isWritingLive: Bool { liveBase?.written ?? false }

    init() {}

    /// Inserts the transcript at the selection per `DictationRules.insert` (selected text is kept, the transcript goes after the end of the selection),
    /// through the same length-limit path as typing, with the caret placed after the inserted text.
    /// Returns the full source text after the insert: the host sends it directly instead of waiting for the bound @State to refresh.
    /// While attached, the text in the input box wins and `currentText` is ignored; while not attached (the view was never built or is already destroyed),
    /// the same rule inserts at the cached selection (clamped to the length of `currentText`; appended at the end when there is no cached selection),
    /// then the inserted run is truncated to the cached length limit. Returning only the transcript would not do: the host overwrites its draft with the return value.
    ///
    /// When this generation has written live text (the system engine finalizes), replace the live range by `DictationRules.liveInsert(source, selection, [transcript], "")`
    /// (already including the length-limit truncation), and end this generation.
    func insert(transcript: String, currentText: String) -> String {
        if let finished = finishLive(transcript) { return finished }
        guard let textView, let coordinator = textView.coordinator else {
            return insertDetached(transcript: transcript, into: currentText)
        }
        remember(coordinator.parent)
        return coordinator.insertDictation(transcript, into: textView)
    }

    /// Writes live text: when the generation differs from the recorded one (a new generation or never started), re-fetch the source text and selection; while attached the input box wins and `currentText` is ignored;
    /// while not attached, use `currentText` and the cached selection (at the end when there is no cached selection). Afterwards every snapshot of the same generation is recomputed from it by
    /// `DictationRules.liveInsert` (already including the length-limit truncation, not passed through the typing truncation again), with the caret placed after the live text.
    /// Returns the full source text after the write.
    func writeLive(_ live: LiveDictationText, generation: Int, currentText: String) -> String? {
        var base = liveBase.flatMap { $0.generation == generation ? $0 : nil }
            ?? fetchBase(generation: generation, currentText: currentText)
        let result = DictationRules.liveInsert(
            finals: live.final.isEmpty ? [] : [live.final],
            partial: live.volatile,
            into: base.text,
            selectionStart: base.selection.location,
            selectionEnd: NSMaxRange(base.selection)
        )
        base.written = true
        liveBase = base
        let volatile = NSRange(location: result.volatile.lowerBound, length: result.volatile.count)
        show(result.text, selection: NSRange(location: result.cursor, length: 0), volatile: volatile)
        return result.text
    }

    /// Ends this generation without changing the text (when dictation returns to idle or fails): later inserts take the normal path with the current source text and selection.
    func clearLive() {
        liveBase = nil
    }

    private func fetchBase(generation: Int, currentText: String) -> LiveBase {
        if let textView, let coordinator = textView.coordinator {
            let base = coordinator.sourceTextAndSelection(of: textView)
            return LiveBase(generation: generation, text: base.text, selection: base.selection, hadSelection: true)
        }
        let count = currentText.utf16.count
        let start = hasSelection ? min(max(range.location, 0), count) : count
        let end = hasSelection ? min(start + max(range.length, 0), count) : count
        return LiveBase(
            generation: generation, text: currentText,
            selection: NSRange(location: start, length: end - start), hadSelection: hasSelection
        )
    }

    /// Finalizes by replacing the live range and ends this generation; when this generation never wrote live text, it only ends the generation and returns nil (normal insert path).
    private func finishLive(_ transcript: String) -> String? {
        guard let base = liveBase else { return nil }
        liveBase = nil
        guard base.written else { return nil }
        let result = DictationRules.liveInsert(
            finals: [transcript], partial: "", into: base.text,
            selectionStart: base.selection.location, selectionEnd: NSMaxRange(base.selection)
        )
        let selection = NSRange(location: result.cursor, length: 0)
        show(result.text, selection: selection)
        // The whole dictation is one undoable step: undo returns to the source text and selection from before recording (only while the input box is attached; there is no undo stack while it is not).
        if let textView, let coordinator = textView.coordinator {
            coordinator.registerDictationUndo(
                restoring: (base.text, base.selection), redoing: (result.text, selection), in: textView
            )
        }
        return result.text
    }

    /// Retracts live text and ends this round (no undo registered): if live text was written, restores the source text and selection from the start and returns the source text; if not, changes nothing and returns nil.
    func restoreLive() -> String? {
        guard let base = liveBase else { return nil }
        liveBase = nil
        guard base.written else { return nil }
        show(base.text, selection: base.selection)
        if textView?.coordinator == nil { hasSelection = base.hadSelection }
        return base.text
    }

    /// While attached, writes the whole source text into the input box and places the selection by source offset (the selection is published back through the input box); while not attached, only the cached selection is updated.
    private func show(_ text: String, selection: NSRange, volatile: NSRange? = nil) {
        if let textView, let coordinator = textView.coordinator {
            coordinator.applyDictationLive(text, selection: selection, volatile: volatile, to: textView)
        } else {
            range = selection
            hasSelection = true
        }
    }

    func attach(_ textView: ComposerUITextView) {
        self.textView = textView
        if let parent = textView.coordinator?.parent { remember(parent) }
    }

    func isAttached(to textView: ComposerUITextView) -> Bool {
        self.textView === textView
    }

    func update(range: NSRange) {
        self.range = range
        hasSelection = true
        if let parent = textView?.coordinator?.parent { remember(parent) }
    }

    private func remember(_ parent: ComposerTextView) {
        maxLength = parent.maxLength
        onLengthLimitExceeded = parent.onLengthLimitExceeded
    }

    private func insertDetached(transcript: String, into text: String) -> String {
        let count = text.utf16.count
        let start = hasSelection ? min(max(range.location, 0), count) : count
        let end = hasSelection ? min(start + max(range.length, 0), count) : count
        let result = DictationRules.insert(transcript: transcript, into: text, selectionStart: start, selectionEnd: end).text
        let added = result.utf16.count - count
        guard let limit = maxLength, added > 0, count + added > limit else { return result }
        onLengthLimitExceeded?()
        // The rule inserts a single run at `end` (possibly with a space added on each side); truncate only that run,
        // the same way typing is truncated (never splitting surrogate pairs or grapheme clusters).
        let full = result as NSString
        let inserted = full.substring(with: NSRange(location: end, length: added)) as NSString
        let kept = ComposerTextView.Coordinator.prefix(of: inserted, fittingUTF16: limit - count)
        let source = text as NSString
        return source.substring(to: end) + kept + source.substring(from: end)
    }
}
