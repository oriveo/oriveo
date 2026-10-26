package ai.oriveo.community.feature.chat.voice

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationServiceStarter
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Who owns the running voice conversation, and the home → chat handoff. One per app (Koin single);
 * main thread only.
 *
 * - A chat page that starts a conversation owns it ([beginChat]); leaving the page or switching conversations ends
 *   it (the host asks [ownedBy]).
 * - The home hero starts with a [HandoffPort] ([beginHome]): nothing exists until the first transcript; then the
 *   conversation is created with the pill's model, the app navigates to it, and the chat page [attach]es its own
 *   port — the controller and its session survive the page change. Leaving home during that handoff is not an end.
 */
class VoiceConversationSessions {
    /**
     * Owner token of the running conversation (a host instance); null = none. Snapshot state: a page bar reading
     * [ownedBy] recomposes on the handoff itself ([attach]), not on whenever its own copy refreshes.
     */
    var owner: Any? by mutableStateOf(null)
        private set

    /** The conversation a home handoff is heading to (set once the first transcript created it). */
    var handoffConversationId: String? = null
        private set

    private var handoff: HandoffPort? = null

    fun beginChat(owner: Any) {
        this.owner = owner
        handoff = null
        handoffConversationId = null
    }

    fun beginHome(
        owner: Any,
        createConversation: suspend () -> String?,
        navigate: (String) -> Unit,
    ): HandoffPort {
        this.owner = owner
        handoffConversationId = null
        return HandoffPort(createConversation, navigate).also { handoff = it }
    }

    fun ownedBy(owner: Any): Boolean = this.owner === owner

    /** True while home has created the conversation and the chat page has not attached yet. */
    val handingOff: Boolean get() = handoff?.let { it.target.value == null && handoffConversationId != null } == true

    /**
     * The chat page of [conversationId] takes over a home conversation heading there; returns false when there is
     * nothing to take over.
     */
    fun attach(conversationId: String?, newOwner: Any, port: () -> VoiceConversationChatPort): Boolean {
        val pending = handoff ?: return false
        if (conversationId == null || conversationId != handoffConversationId || pending.target.value != null) return false
        owner = newOwner
        pending.target.value = port()
        return true
    }

    /** Home port: the first send creates the conversation and waits for the chat page to attach. */
    @OptIn(ExperimentalCoroutinesApi::class)
    inner class HandoffPort internal constructor(
        private val createConversation: suspend () -> String?,
        private val navigate: (String) -> Unit,
    ) : VoiceConversationChatPort {
        internal val target = MutableStateFlow<VoiceConversationChatPort?>(null)

        /**
         * Creates the conversation with the pill's model and navigates to it, once; later calls return the same id.
         * A realtime home session calls this from its first persist and never sends here.
         */
        internal suspend fun conversationId(): String? = withContext(Dispatchers.Main.immediate + NonCancellable) {
            // The realtime sink asks from its write loop (a background thread); the ids and navigation live on main.
            // Creation and the handoff are not cancellable halfway: an end meanwhile still records the created id
            //.
            used = true
            createdId?.let { return@withContext it }
            val id = createConversation() ?: return@withContext null
            createdId = id
            if (handoff === this@HandoffPort) handoffConversationId = id
            try {
                navigate(id)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (e: Exception) {
                // The conversation exists either way: its turns are still written there and it opens from the list.
                Log.w(TAG, "home voice handoff navigation failed", e)
            }
            id
        }

        private var createdId: String? = null

        // A turn was sent (or a realtime persist asked for the id): from then on the conversation exists or is being made.
        private var used = false

        override suspend fun send(text: String): Boolean {
            used = true
            target.value?.let { return it.send(text) }
            conversationId() ?: return false
            val port = withTimeoutOrNull(HANDOFF_TIMEOUT_MS) { target.filterNotNull().first() } ?: return false
            return port.send(text)
        }

        override val replies: Flow<VoiceReplyEvent> = target.flatMapLatest { it?.replies ?: emptyFlow() }

        /** Ending before the first turn created anything releases the ownership: zero turns leave no trace. */
        override fun cancel() {
            target.value?.cancel()
            if (!used && handoff === this) {
                owner = null
                handoff = null
                handoffConversationId = null
            }
        }
    }

    companion object {
        /** How long the first home turn waits for the chat page to take over. */
        const val HANDOFF_TIMEOUT_MS = 10_000L

        private const val TAG = "VoiceConversationSessions"
    }
}

/**
 * Entering a voice conversation, in a fixed order: the send gates, then RECORD_AUDIO, then a
 * one-time POST_NOTIFICATIONS request that never blocks, then the foreground service and finally the controller.
 * Each step is a port so the order is testable without Android.
 */
class VoiceConversationEntryFlow(
    private val gate: suspend () -> Boolean,
    private val microphone: suspend () -> Boolean,
    private val notifications: suspend () -> Unit,
    private val startService: () -> VoiceConversationServiceStarter.Result,
    private val startConversation: () -> Unit,
    private val onMicrophoneDenied: () -> Unit,
    private val onStartFailed: () -> Unit,
) {
    suspend fun run(): Boolean {
        if (!gate()) return false
        if (!microphone()) {
            onMicrophoneDenied()
            return false
        }
        notifications()
        return when (startService()) {
            VoiceConversationServiceStarter.Result.Started -> {
                startConversation()
                true
            }
            // Not visible any more: the user already left; nothing to say.
            VoiceConversationServiceStarter.Result.NotVisible -> false
            else -> {
                onStartFailed()
                false
            }
        }
    }
}
