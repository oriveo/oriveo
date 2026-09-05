package ai.oriveo.community.feature.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.provider.escapeJsonString
import ai.oriveo.community.core.util.TextShareLauncher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal class ChatExportCoordinator(
    private val viewModelScope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val currentConversation: () -> Conversation?,
) {
    fun copyMessage(message: ChatMessage, context: Context) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.app_name), message.text))
    }

    fun shareMessage(message: ChatMessage, context: Context) {
        viewModelScope.launch {
            TextShareLauncher.shareText(
                context = context,
                text = message.text,
                fileName = "${context.getString(R.string.app_name)}.txt",
            ).onFailure {
                showShareFailure()
            }
        }
    }

    fun exportAsMarkdown(context: Context) {
        val conv = currentConversation() ?: return
        viewModelScope.launch {
            val full = conversationRepository.getWithMessages(conv.id) ?: return@launch
            val text = ChatExport.markdown(full)
            TextShareLauncher.shareTextFile(
                context = context,
                text = text,
                fileName = "${ChatExport.sanitizeFilename(full.title)}.md",
                mimeType = "text/markdown",
            ).onSuccess {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.chat_export_markdown_ready)),
                )
            }.onFailure {
                showShareFailure()
            }
        }
    }

    fun exportAsJson(context: Context) {
        val conv = currentConversation() ?: return
        viewModelScope.launch {
            val full = conversationRepository.getWithMessages(conv.id) ?: return@launch
            val messages = full.messages
            val json = buildString {
                appendLine("{")
                appendLine("  \"title\": ${escapeJsonString(full.title)},")
                appendLine("  \"messages\": [")
                messages.forEachIndexed { i, msg ->
                    val comma = if (i < messages.size - 1) "," else ""
                    val escapedText = escapeJsonString(msg.text)
                    appendLine("    {\"role\": \"${msg.role.name}\", \"text\": $escapedText}$comma")
                }
                appendLine("  ]")
                appendLine("}")
            }
            TextShareLauncher.shareTextFile(
                context = context,
                text = json,
                fileName = "${ChatExport.sanitizeFilename(full.title)}.json",
                mimeType = "application/json",
            ).onSuccess {
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.chat_export_json_ready)),
                )
            }.onFailure {
                showShareFailure()
            }
        }
    }

    private fun showShareFailure() {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(R.string.error_generic_message),
                style = GlobalToastStyle.Error,
            ),
        )
    }
}
