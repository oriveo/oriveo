import SwiftUI
import UIKit

/// Reading sheet opened by "Show full message" on a folded long user message (see `UserMessageFold`).
///
/// The text reuses the notes' bounded viewport `BoundedNoteTextView`: TextKit 1 with non-contiguous layout lays
/// out only the visible area, and the display layer sets each paragraph's direction and adds soft breaks, so even
/// 200,000 characters of Arabic open without laying out the whole text. Read-only; copying a selection returns
/// the original text.
struct UserMessageFullTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            BoundedNoteTextView(text: .constant(text), isEditable: false)
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.top, OriveoTheme.Spacing.sm)
                .background(OriveoTheme.Palette.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(copied ? L10n.tr("Copied") : L10n.tr("Copy")) {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                        .accessibilityIdentifier("user_message_full_text_copy")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.tr("Done")) {
                            dismiss()
                        }
                    }
                }
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
        }
        .presentationDetents([.large])
    }
}
