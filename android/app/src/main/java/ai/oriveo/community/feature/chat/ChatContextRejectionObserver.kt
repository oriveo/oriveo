package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ChatContextRejections
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Plan rejection: sending already stopped in ChatRepository, with no request and no user / assistant message.
 * Uses the same error prompt as the pre-send interception; when the input box is empty, send / edit-and-send put the text, attachments and quotes all back into the input box.
 * A pinned note is not consumed on send, so it needs no refill.
 * The rollback when the pre-send confirmation is cancelled goes through here too: no prompt is shown.
 * Input box empty = the text is blank after trimming and there are no attachments; otherwise neither a rejection nor a rollback refills anything;
 * on a rollback without refill, the attachments uploaded by this attempt are no longer referenced by any message.
 */
internal fun observeChatContextRejections(
    scope: CoroutineScope,
    showToast: (GlobalSnackbarMessage) -> Unit,
    draft: ChatDraftCoordinator,
    activeConversationId: () -> String?,
    quotes: ChatQuoteCoordinator,
    composerAttachments: () -> List<Attachment>,
    restoreAttachments: (List<Attachment>) -> Unit,
) {
    scope.launch {
        ChatContextRejections.shared.events.collect { rejection ->
            // A cancelled confirmation rollback is not a rejection: no prompt is shown.
            rejection.reject?.takeIf { !rejection.rolledBack }?.let { showToast(contextRejectToast(it)) }
            val conversationId = activeConversationId()
            if (!rejection.restoresComposer || rejection.conversationId != conversationId) return@collect
            if (draft.text.isNotBlank() || composerAttachments().isNotEmpty()) {
                return@collect
            }
            draft.restoreText(rejection.text, conversationId)
            rejection.attachments?.takeIf { it.isNotEmpty() }?.let(restoreAttachments)
            // Fill empty slots only: quotes the user picked after the rejection prompt are not overwritten.
            rejection.quoteContext?.takeIf { quotes.pending == null }?.let(quotes::restore)
        }
    }
}
