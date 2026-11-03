import SwiftUI

/// "Select text": the whole body goes into one selectable bounded text view (TextKit 1 non-contiguous, laying out only near the viewport), so a selection can be dragged across any paragraphs and copied.
/// The reading pane's rich text is a stack of lazy blocks (one view each) and a UITextView selection cannot span views; a long note enters here to select across the whole text.
/// It opens scrolled to where the reading pane was; entering by long press on a block scrolls to the press and preselects that word.
struct NoteTextSelectionRequest: Identifiable {
    let id = UUID()
    let text: String
    let sourceLocation: Int
    /// Source range preselected on open (entering by long press on a word of the reading pane); nil when entering from the button.
    var selectedSourceRange: NSRange?
}

struct NoteTextSelectionView: View {
    let request: NoteTextSelectionRequest
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    /// UI test probe: the text the panel's text view actually has selected (XCUITest cannot read the UITextView selection).
    @State private var debugSelectedText = ""
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Select text", table: .notes))
                    .font(OriveoTheme.Typography.title3)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Text(L10n.tr("Done"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextOnSurface)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)

            BoundedNoteTextView(
                text: .constant(request.text),
                isEditable: false,
                initialScrollSourceLocation: request.sourceLocation,
                initialSelectionSourceRange: request.selectedSourceRange
            )
            .padding(.horizontal, 22)
        }
        .background(NotesChrome.background.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("note_text_selection_probe")
                .accessibilityLabel(Text(verbatim: debugSelectedText))
        }
        .onReceive(NotificationCenter.default.publisher(for: .oriveoDebugNoteInitialSelection)) { note in
            debugSelectedText = note.object as? String ?? ""
        }
        #endif
    }
}

#if DEBUG
extension Notification.Name {
    /// The "Select Text" panel applied the preselection made when it opened (object = the selected text). For the UI test probe only.
    static let oriveoDebugNoteInitialSelection = Notification.Name("oriveoDebugNoteInitialSelection")
}

/// UI test direct page `-AUTO_OPEN_PAGE noteLongPressSelect`: creates a long note that uses lazy blocks and opens its detail.
/// One of each of three block kinds per section, with the word at the start of the block and unique across the whole text: a plain paragraph (CachedMarkdownView, UITextView),
/// a code block (CodeBlockCard, UITextView), and a paragraph plus a table (MarkdownUI, SwiftUI Text).
enum NoteLongPressUITestPage {
    static func body(sections: Int = 40) -> String {
        var out = ""
        for index in 0..<sections {
            out += "plainmarker\(index) opens a plain paragraph.\n\n"
            out += "```kotlin\ncodemarker\(index) = \(index)\n```\n\n"
            out += "tablemarker\(index) sits above a table.\n\n| a | b |\n|---|---|\n| \(index) | \(index + 1) |\n\n"
            out += "```text\nend \(index)\n```\n\n"
        }
        return out
    }

    static func open(appState: AppState) {
        guard let note = appState.noteManager.createNote(from: NoteDraft(title: "Long press", body: body(), captureKind: .blank)) else { return }
        appState.openNotes()
        appState.openNoteDetail(noteID: note.id)
    }
}
#endif
