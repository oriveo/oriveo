package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import ai.oriveo.community.feature.chat.ChatViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.dropWhile
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
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
 * - A send or an amend the page could not send after all (onBlocked / onFailed after it returned true), or a turn
 *   rolled back at the pre-send confirmation or refused by the context plan before its stream started → Failed,
 *   and the port disarms.
 * - Tool approvals and the pre-send confirmation both arrive through approvalPending.
 * - Tool approvals (MCP or library) → ApprovalPending, on every change, armed or not.
 *
 * Port contract: after [cancel] nothing from the cancelled reply is emitted again; events flow only between a
 * [send] and that reply's end (approval changes excepted); a send / amend still waiting for a cancelled stream when
 * [cancel] comes is dropped (returns false). An amend first waits (bounded by the settle timeout) for the user
 * message of the latest turn to land, so a barge-in right after a send rewrites that turn and not the one before;
 * past the timeout it goes out with no id (the page then sends it as a new turn). All members run on the main
 * thread (the controller's scope).
 */
class ViewModelVoiceChatPort(
    /** Sends a voice turn; after true the page calls onBlocked when the send was refused before it went out. */
    private val sendText: (text: String, onBlocked: () -> Unit) -> Boolean,
    private val streamingText: Flow<String>,
    private val streamingMessageId: Flow<String?>,
    private val approvalPending: Flow<Boolean>,
    private val replyMessage: (messageId: String) -> Flow<ChatMessage?>,
    private val stop: () -> Unit,
    private val settleTimeoutMs: Long = SETTLE_TIMEOUT_MS,
    /**
     * Barge-in while thinking: amends the turn's user message [userMessageId] (null = it never landed) and
     * regenerates; false = nothing to amend. After true the page calls onFailed when the amend could not go out
     * after all (the turn vanished, the fallback send was refused, no model): the reply then ends Failed.
     */
    private val amendText: (text: String, userMessageId: String?, onFailed: () -> Unit) -> Boolean = { _, _, _ -> false },
    /** The user message of the latest turn once the page has it; null while the send has not landed. */
    private val turnUserMessageId: Flow<String?> = flowOf(null),
    /**
     * The latest turn ended before a reply: rolled back at the pre-send confirmation (cancel / stop while it waited)
     * or refused by the context plan.
     */
    private val turnRolledBack: Flow<Unit> = kotlinx.coroutines.flow.emptyFlow(),
) : VoiceConversationChatPort {
    // A send arms the port; the reply's end or a cancel disarms it. Each send is a new epoch, so a late end of a
    // cancelled reply can't touch the next one.
    private var epoch = 0
    private var armed = false
    private var streamingId: String? = null
    private var lastText: String? = null

    // The approval state last sent through [replies]: a rollback resolves a pending confirmation before it fails the turn.
    private var approvalSent = false

    // Sends / amends waiting for a cancelled stream to wind down; a cancel drops them all.
    private val settling = mutableSetOf<Job>()

    // Turns that failed after they went out (a send or amend the page could not send after all); [replies] reports them.
    private val failures = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    override suspend fun send(text: String): Boolean = send(text) {}

    /** [onDelivered] runs right before the text is handed to the page (a send dropped while settling never calls it). */
    override suspend fun send(text: String, onDelivered: () -> Unit): Boolean =
        dispatch(awaitTurn = false, onDelivered) { _, onFailed -> sendText(text, onFailed) }

    override suspend fun amend(text: String): Boolean = amend(text) {}

    /** Same arming as [send]: the regenerated reply flows through [replies] under a new epoch. */
    override suspend fun amend(text: String, onDelivered: () -> Unit): Boolean =
        dispatch(awaitTurn = true, onDelivered) { target, onFailed -> amendText(text, target, onFailed) }

    private suspend fun dispatch(
        awaitTurn: Boolean,
        onDelivered: () -> Unit,
        start: (turnUserMessageId: String?, onFailed: () -> Unit) -> Boolean,
    ): Boolean {
        armed = false
        val myEpoch = epoch
        // The send before this amend may not have landed its user message yet; the page's last one is the turn before.
        val target = if (awaitTurn) settle { turnUserMessageId.filterNotNull().first() } else null
        // A reply that was just cancelled (barge-in) may still be winding down: the page refuses a send while a
        // stream is busy, and its end must not be read as the end of the new reply.
        if (streamingId != null && epoch == myEpoch) settle { streamingMessageId.first { it == null } }
        // Cancelled while waiting: the conversation moved on, this turn is not sent.
        if (epoch != myEpoch) return false
        streamingId = null
        epoch++
        val turnEpoch = epoch
        armed = true
        lastText = null
        // Only this turn's failure disarms: a late one from a turn already cancelled or replaced is ignored.
        val onFailed = {
            if (armed && epoch == turnEpoch) {
                armed = false
                failures.tryEmit(Unit)
            }
        }
        // Delivery point (E-414): from here the page replaces / creates the user message, so a cancel no longer
        // drops this text and the host must not carry it into the next turn.
        onDelivered()
        val sent = start(target, onFailed)
        if (!sent) armed = false
        return sent
    }

    /** Waits for [block] up to the settle timeout; null on timeout or when a [cancel] drops the wait. */
    private suspend fun <T> settle(block: suspend () -> T): T? = coroutineScope {
        var result: T? = null
        val wait = launch { result = withTimeoutOrNull(settleTimeoutMs) { block() } }
        settling += wait
        wait.join()
        settling -= wait
        result
    }

    override fun cancel() {
        armed = false
        epoch++
        settling.toList().forEach { it.cancel() }
        settling.clear()
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
            failures.collect { send(VoiceReplyEvent.Failed(REPLY_FAILED)) }
        }
        launch {
            // Rolled back at the pre-send confirmation or refused by the context plan, no stream yet: this turn's end.
            turnRolledBack.collect {
                if (!armed || streamingId != null) return@collect
                armed = false
                // The confirmation it was held at is gone: approval resolved first, then Failed (same order as iOS).
                if (approvalSent) {
                    approvalSent = false
                    send(VoiceReplyEvent.ApprovalPending(false))
                }
                send(VoiceReplyEvent.Failed(REPLY_FAILED))
            }
        }
        launch {
            // A leading false is the initial "nothing pending", not a resolve.
            approvalPending.distinctUntilChanged().dropWhile { !it }.collect { pending ->
                // Not gated by armed: a resolve after a barge-in cancel must still reach the reducer.
                // A resolve the rollback already sent is not sent again.
                if (pending == approvalSent) return@collect
                approvalSent = pending
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
            sendText = { text, onBlocked -> viewModel.voice.send(text, onBlocked = onBlocked) },
            streamingText = viewModel.streamingText,
            streamingMessageId = viewModel.streamingMessageId,
            approvalPending = viewModel.voice.approvalPending,
            replyMessage = viewModel.voice::replyMessage,
            stop = viewModel::stopGeneration,
            amendText = viewModel.voice::amend,
            turnUserMessageId = viewModel.voice.turnUserMessageId,
            turnRolledBack = viewModel.voice.turnRolledBack,
        )
    }
}
