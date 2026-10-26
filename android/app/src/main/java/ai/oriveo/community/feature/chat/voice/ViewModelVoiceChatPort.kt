package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.feature.chat.ChatViewModel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.dropWhile
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Voice conversation ↔ chat page: a turn goes out through [ai.oriveo.community.feature.chat.ChatVoiceCoordinator.send] (same gates as
 * send, delivery VOICE); the reply is read back from the page's streaming state.
 *
 * - [VoiceReplyEvent.Text] carries the full streamed text while a reply streams.
 * - When the streaming id returns to null the reply message decides: failed state or an error title → Failed,
 *   anything else → Completed (the final text is sent once more first when it grew after the last chunk); an
 *   interrupted message completes with delivered = false.
 * - Tool approvals (MCP or library) → ApprovalPending, on every change, armed or not.
 *
 * Port contract: after [cancel] nothing from the cancelled reply is emitted again; events flow only between a
 * [send] and that reply's end (approval changes excepted). All members run on the main thread (the controller's scope).
 */
class ViewModelVoiceChatPort(
    private val sendText: (String) -> Boolean,
    private val streamingText: Flow<String>,
    private val streamingMessageId: Flow<String?>,
    private val approvalPending: Flow<Boolean>,
    private val replyMessage: (messageId: String) -> Flow<ChatMessage?>,
    private val stop: () -> Unit,
    private val settleTimeoutMs: Long = SETTLE_TIMEOUT_MS,
) : VoiceConversationChatPort {
    // A send arms the port; the reply's end or a cancel disarms it. Each send is a new epoch, so a late end of a
    // cancelled reply can't touch the next one.
    private var epoch = 0
    private var armed = false
    private var streamingId: String? = null
    private var lastText: String? = null

    override suspend fun send(text: String): Boolean {
        armed = false
        // A reply that was just cancelled (barge-in) may still be winding down: the page refuses a send while a
        // stream is busy, and its end must not be read as the end of the new reply.
        if (streamingId != null) withTimeoutOrNull(settleTimeoutMs) { streamingMessageId.first { it == null } }
        streamingId = null
        epoch++
        armed = true
        lastText = null
        val sent = sendText(text)
        if (!sent) armed = false
        return sent
    }

    override fun cancel() {
        armed = false
        epoch++
        stop()
    }

    override val replies: Flow<VoiceReplyEvent> = channelFlow {
        launch {
            streamingMessageId.collect { id ->
                val previous = streamingId
                streamingId = id
                if (id != null || previous == null || !armed) return@collect
                val myEpoch = epoch
                launch {
                    val message = withTimeoutOrNull(settleTimeoutMs) {
                        replyMessage(previous).first { it != null && it.state != ChatMessageState.Generating }
                    }
                    if (!armed || epoch != myEpoch) return@launch
                    armed = false
                    val failed = message == null || message.state == ChatMessageState.Failed || message.errorTitle != null
                    if (failed) {
                        send(VoiceReplyEvent.Failed(REPLY_FAILED))
                    } else {
                        val final = message!!.text
                        if (final.isNotEmpty() && final != lastText) {
                            lastText = final
                            send(VoiceReplyEvent.Text(final))
                        }
                        send(VoiceReplyEvent.Completed(delivered = message.state != ChatMessageState.Interrupted))
                    }
                }
            }
        }
        launch {
            streamingText.collect { text ->
                if (!armed || streamingId == null || text.isEmpty() || text == lastText) return@collect
                lastText = text
                send(VoiceReplyEvent.Text(text))
            }
        }
        launch {
            // A leading false is the initial "nothing pending", not a resolve.
            approvalPending.distinctUntilChanged().dropWhile { !it }.collect { pending ->
                // Not gated by armed: a resolve after a barge-in cancel must still reach the reducer.
                send(VoiceReplyEvent.ApprovalPending(pending))
            }
        }
    }

    companion object {
        /** Failure code of a reply that ended failed (the chat shows its own error card). */
        const val REPLY_FAILED = "reply_failed"

        /** How long the ended reply may take to leave the generating state in the conversation. */
        const val SETTLE_TIMEOUT_MS = 3_000L

        fun of(viewModel: ChatViewModel): ViewModelVoiceChatPort = ViewModelVoiceChatPort(
            sendText = viewModel.voice::send,
            streamingText = viewModel.streamingText,
            streamingMessageId = viewModel.streamingMessageId,
            approvalPending = viewModel.voice.approvalPending,
            replyMessage = viewModel.voice::replyMessage,
            stop = viewModel::stopGeneration,
        )
    }
}
