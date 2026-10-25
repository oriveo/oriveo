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

    init() {}

    /// Inserts a transcript at the selection per `DictationRules.insert` (selected text is kept, the transcript goes
    /// after the end of the selection), through the same length-limit path as typing, with the caret placed after
    /// the inserted text.
    /// Returns the full source text after the insert: the host sends it directly instead of waiting for the bound
    /// @State to refresh.
    /// While attached, the text in the input wins and `currentText` is ignored. While not attached (the view was
    /// never built or is already destroyed) the same rule inserts at the cached selection (clamped to the length of
    /// `currentText`; appended at the end when there is none), and the inserted run is truncated to the cached
    /// length limit. Returning only the transcript would not do: the host overwrites its draft with the return value.
    func insert(transcript: String, currentText: String) -> String {
        guard let textView, let coordinator = textView.coordinator else {
            return insertDetached(transcript: transcript, into: currentText)
        }
        remember(coordinator.parent)
        return coordinator.insertDictation(transcript, into: textView)
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
