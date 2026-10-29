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
                        .foregroundStyle(OriveoTheme.Palette.primary)
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
    }
}
