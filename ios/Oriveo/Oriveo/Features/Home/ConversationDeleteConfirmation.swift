import SwiftUI

/// The confirmation shown before deleting a single conversation. Long-press "Delete" on a conversation in the Home
/// list and inside a folder share this one: the same wording (including the "referenced by N notes" note), so the
/// two places cannot drift apart. Inside a folder the delete used to happen right away, with no confirmation.
private struct ConversationDeleteConfirmation: ViewModifier {
    @Binding var conversation: Conversation?
    let animation: Animation?

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.alert(
            L10n.tr("Delete this conversation?"),
            isPresented: Binding(
                get: { conversation != nil },
                set: { if !$0 { conversation = nil } }
            ),
            presenting: conversation
        ) { conv in
            Button(L10n.tr("Cancel"), role: .cancel) {
                conversation = nil
            }
            Button(L10n.tr("Delete"), role: .destructive) {
                let id = conv.id
                conversation = nil
                withAnimation(animation) {
                    appState.deleteConversation(id: id)
                }
            }
        } message: { conv in
            let refCount = appState.noteManager.referenceCount(conversationID: conv.id)
            if refCount > 0 {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted.")
                    + "\n\n" + String(format: L10n.tr("This conversation is referenced by %d notes.", table: .notes), refCount))
            } else {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted."))
            }
        }
    }
}

extension View {
    /// Shows the delete confirmation while `conversation` is non-nil; confirming deletes it inside `animation`.
    func conversationDeleteConfirmation(_ conversation: Binding<Conversation?>, animation: Animation?) -> some View {
        modifier(ConversationDeleteConfirmation(conversation: conversation, animation: animation))
    }
}
