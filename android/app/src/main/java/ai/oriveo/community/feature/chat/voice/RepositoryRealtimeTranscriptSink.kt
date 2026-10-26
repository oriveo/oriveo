package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.voice.realtime.RealtimeConversationSink
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceLog
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Who a realtime turn is attributed to: the realtime connection and the catalog model. */
data class RealtimeMessageAttribution(
    val providerID: String,
    val providerKind: ProviderKind,
    val providerName: String,
    val model: String,
)

/**
 * How a realtime session that has no conversation row yet gets one.
 * [home] = the home entry: the first turn event creates the conversation (moving to the chat page), only one try per
 * session, and when the session persisted nothing into it [onEmptyDeleted] first leaves its page, then the
 * conversation is deleted again (only if the store still has no message). Otherwise (a chat page draft) the page's
 * own [create] runs on the first write and nothing is ever deleted.
 */
internal class RealtimeConversationCreator(
    val home: Boolean,
    private val create: suspend () -> String?,
    val onEmptyDeleted: suspend (String) -> Unit = {},
) : suspend () -> String? {
    override suspend fun invoke(): String? = create()
}

/**
 * Persists realtime turns as plain text messages of [conversationId]: the user
 * transcript is added delivered; the assistant text is added and then updated as delivered, which goes through
 * the same path as a normal answer. No HTTP generation, no usage. Writes run strictly in order.
 *
 * [conversationId] null = no row yet; [createConversation] (a [RealtimeConversationCreator]; a bare creator counts
 * as a chat entry) makes it and every later write goes to that conversation.
 * - Home entry: [ensureConversation] (the first turn event)
 *   creates it, once per session and not cancellable halfway; a failure is reported to the controller and later
 *   writes are dropped. When the session ends with nothing written into the conversation it created, the creator's
 *   onEmptyDeleted leaves its page first, then [delete] removes it if the store still has no message in it.
 * - Chat page draft: [ensureConversation] does nothing; the first write creates the row through the page and it is
 *   never deleted. A write whose conversation could not be created (null) is dropped; one whose creation threw is
 *   held and written, in order, before the next write that resolves it.
 *
 * [close] once the session is over (ended, or entering failed after prepare): queued writes still run, then the
 * write loop finishes.
 */
internal class RepositoryRealtimeTranscriptSink(
    @Volatile private var conversationId: String?,
    private val attribution: RealtimeMessageAttribution,
    private val add: suspend (String, ChatMessage) -> Unit,
    private val update: suspend (String, ChatMessage) -> Unit,
    scope: CoroutineScope,
    private val createConversation: suspend () -> String? = { null },
    /** Deletes the conversation only if it has no message (one transaction); true = deleted. */
    private val delete: suspend (String) -> Boolean = { false },
    private val now: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = ::generateUuidString,
    /** Adds a user transcript; defaults to the plain message write. */
    private val addUser: suspend (String, ChatMessage) -> Unit = add,
) : RealtimeConversationSink, AutoCloseable {
    constructor(
        repository: ConversationRepository,
        conversationId: String?,
        attribution: RealtimeMessageAttribution,
        scope: CoroutineScope,
        createConversation: suspend () -> String?,
    ) : this(
        conversationId = conversationId,
        attribution = attribution,
        add = repository::addMessage,
        update = repository::updateMessage,
        scope = scope,
        createConversation = createConversation,
        // Only a conversation still without messages: the chat page may have written into it meanwhile.
        delete = repository::deleteIfEmpty,
    )

    private val writes = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    // Ids of every message this sink queued, recorded before the write so a reader never sees one it misses.
    private val written = LinkedHashSet<String>()

    // Writes whose target lookup threw; only the write loop touches it.
    private val held = ArrayList<suspend (String) -> Unit>()
    private var lastCreatedAt = Long.MIN_VALUE

    // The first turn event (main thread) and the write loop may both ask for the home conversation.
    private val targetLock = Mutex()

    private val creator = createConversation as? RealtimeConversationCreator

    // Only the home entry creates on the first turn event and deletes.
    // A bare creator (not tagged) counts as a chat entry: when the entry is unknown, never delete.
    private val home = conversationId == null && creator?.home == true

    // The home entry already tried to create its conversation (once per session); guarded by targetLock.
    private var homeAttempted = false

    // The conversation the home entry created; null on a chat entry. Guarded by targetLock.
    @Volatile private var created: String? = null

    // A message was written into the conversation.
    @Volatile private var persisted = false

    /** [close] was called: later turns are not written. */
    var closed = false
        private set

    private val loop: Job = scope.launch {
        for (write in writes) runCatchingWrite(write)
        // Closed: a home conversation this session made but never wrote into is not left behind empty. Taking the
        // lock waits for a creation still in flight (the session may end during it).
        val empty = targetLock.withLock { created }
        if (home && empty != null && !persisted) {
            // Leave that conversation's page first (the creator switches to the main thread and only leaves when it
            // is the current page): with no send entry left, no new message can lose an FK race against the delete.
            // A skipped delete (the store has messages) does not navigate again.
            runCatchingWrite { creator?.onEmptyDeleted?.invoke(empty) }
            runCatchingWrite {
                val deleted = delete(empty)
                RealtimeVoiceLog.d("sink empty conversation=$empty deleted=$deleted")
            }
        }
    }

    override fun close() {
        closed = true
        writes.close()
    }

    /**
     * Waits until every write queued so far has run, then returns the conversation they went to (null = nothing
     * written on a home / draft entry yet). A reopen reads the history only after this.
     * After [close] it waits for the write loop to finish, the empty-conversation cleanup included.
     */
    suspend fun drain(): String? {
        val done = CompletableDeferred<Unit>()
        if (writes.trySend { done.complete(Unit) }.isSuccess) done.await() else loop.join()
        return conversationId
    }

    /** Home entry: creates the conversation now; false = it could not be created. Other entries: no-op, true. */
    override suspend fun ensureConversation(): Boolean {
        if (!home || closed) return true
        return target() != null
    }

    /** Ids of the messages queued so far (realtime-session.v1: the open session's own transcripts on a replan). */
    fun writtenIds(): Set<String> = synchronized(written) { written.toSet() }

    override fun appendUser(text: String) {
        val message = message(ChatRole.User, text)
        writes.trySend {
            persist { id ->
                addUser(id, message)
                persisted = true
                logPersisted(id, message)
            }
        }
    }

    override fun appendAssistant(text: String) {
        val message = message(ChatRole.Assistant, text)
        writes.trySend {
            persist { id ->
                add(id, message)
                persisted = true
                update(id, message)
                logPersisted(id, message)
            }
        }
    }

    /** Runs on the write loop: resolves the conversation, writes the held turns first, then [write]. */
    private suspend fun persist(write: suspend (String) -> Unit) {
        val id = try {
            target()
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            // The first home turn must not be lost when creating / opening its conversation failed once.
            held += write
            RealtimeVoiceLog.d("sink held: conversation lookup failed, held=${held.size}")
            return
        } ?: run {
            RealtimeVoiceLog.d("sink dropped: no conversation")
            return
        }
        if (held.isNotEmpty()) {
            val pending = held.toList()
            held.clear()
            pending.forEach { runCatchingWrite { it(id) } }
        }
        write(id)
    }

    private suspend fun runCatchingWrite(write: suspend () -> Unit) {
        try {
            write()
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            // One failed write must not drop the later turns.
        }
    }

    /** The conversation to write to; creates it on the first turn event (home) or the first write (chat draft). */
    private suspend fun target(): String? = conversationId ?: targetLock.withLock {
        conversationId ?: if (home) createHome() else createConversation()?.also { conversationId = it }
    }

    /**
     * One try per session. Not cancellable halfway: an end during creation still records the id, so the empty
     * check at close runs on it. A failure returns null (later writes are dropped).
     */
    private suspend fun createHome(): String? {
        if (homeAttempted) return null
        homeAttempted = true
        return withContext(NonCancellable) {
            val id = try {
                createConversation()
            } catch (_: Exception) {
                null
            }
            id?.also {
                created = it
                conversationId = it
            }
        }
    }

    private fun logPersisted(conversation: String, message: ChatMessage) {
        RealtimeVoiceLog.d(
            "sink persisted ${message.role} conversation=$conversation message=${message.id} " +
                "text=${RealtimeVoiceLog.text(message.text)}",
        )
    }

    private fun message(role: ChatRole, text: String): ChatMessage {
        // Strictly increasing createdAt keeps the order stable across devices (same as ChatRepository.sendMessage).
        val createdAt = maxOf(now(), lastCreatedAt + 1)
        lastCreatedAt = createdAt
        val id = newId()
        synchronized(written) { written += id }
        return ChatMessage(
            id = id,
            role = role,
            text = text,
            providerID = attribution.providerID,
            providerKind = attribution.providerKind,
            providerName = attribution.providerName,
            modelID = attribution.model,
            modelName = attribution.model,
            state = ChatMessageState.Delivered,
            createdAt = createdAt,
        )
    }
}
