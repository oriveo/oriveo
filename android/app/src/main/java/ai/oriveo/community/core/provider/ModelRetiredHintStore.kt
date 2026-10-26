package ai.oriveo.community.core.provider

import android.content.Context
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * One-shot record of the "preferred model for a new chat was retired" hint (hint last_used_retired: once per device per model).
 * Keyed by `provider|model` (the model that was replaced); implemented in [OncePerModelHintStore].
 */
class ModelRetiredHintStore(
    readPayload: () -> String?,
    writePayload: (String?) -> Unit,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : OncePerModelHintStore(readPayload, writePayload, ioDispatcher) {
    companion object {
        private const val PREFS_NAME = "model_retired_hint_seen.v1"

        fun from(context: Context): ModelRetiredHintStore {
            val payload = OncePerModelHintStore.PrefsPayload(context, PREFS_NAME)
            return ModelRetiredHintStore(readPayload = payload.read, writePayload = payload.write)
        }
    }
}

/**
 * New-chat fallback hint (shared by Home and a Chat without a conversation): shows once when [selection] carries a hint and this device has not shown it for "last used connection + original model id".
 * Returns whether the hint was emitted. The dedup ledger is read and written on the IO thread.
 */
suspend fun ModelRetiredHintStore.showNewChatHintIfNeeded(
    selection: ai.oriveo.community.core.model.ActiveModelSelection?,
    snackbarManager: ai.oriveo.community.core.app.GlobalSnackbarManager,
): Boolean {
    if (selection?.hint != ModelRetirement.NewChatHint.LastUsedRetired) return false
    // Dedup key = last used connection + original model id, not the connection fell back to.
    val replaced = selection.replacedModelId ?: return false
    if (!consumeOffMain(selection.replacedProviderId ?: selection.provider.id, replaced)) return false
    snackbarManager.show(
        ai.oriveo.community.core.app.GlobalSnackbarMessage(
            message = ai.oriveo.community.core.app.UiText.Resource(
                ai.oriveo.community.R.string.chat_last_used_model_retired_hint,
                listOf(selection.model.name.ifBlank { selection.model.id }),
            ),
        ),
    )
    return true
}
