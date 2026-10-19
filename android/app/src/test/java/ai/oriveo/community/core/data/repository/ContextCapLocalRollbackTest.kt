package ai.oriveo.community.core.data.repository

import androidx.room.Room
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextCapConfirmChoice
import ai.oriveo.community.core.context.ContextCapConfirmCoordinator
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.testing.TestSharedPreferences
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Cancelling a confirmation rolls back by deleting locally only (ConversationRepository.deleteMessagesLocally, real Room database).
 * The rolled-back pair never leaves the device, and checkpoint invalidation only touches local rows.
 */
@RunWith(RobolectricTestRunner::class)
class ContextCapLocalRollbackTest {

    private lateinit var db: OriveoDatabase

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun local_rollback_deletes_no_remote() = runBlocking {
        val store = ContextCompactionStore(db.contextCheckpointDao())
        val repository = ConversationRepository(
            db.conversationDao(), db.messageDao(),
            contextCompactionStore = store,
        )

        // One earlier round u0 / a0 whose checkpoint covers up to a0; the current send u1 (with an attachment) / a1 is cancelled before confirmation.
        // Another checkpoint covers up to u1: it is invalidated together with u1.
        val conversation = repository.create(PROVIDER_ID, ProviderKind.Grok, MODEL_ID, useMemory = false)
        val u0 = message(ChatRole.User, "earlier question")
        val a0 = message(ChatRole.Assistant, "earlier answer")
        val attached = Attachment(
            id = generateUuidString(), kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png",
        )
        val u1 = message(ChatRole.User, "new question").copy(attachments = listOf(attached))
        val a1 = message(ChatRole.Assistant, "")
        listOf(u0, a0, u1, a1).forEach { repository.addMessage(conversation.id, it) }
        val history = listOf(u0, a0, u1).map { CheckpointCoveredMessage(it.id, it.text) }
        store.save(ACCOUNT, record(conversation.id, a0.id, history, createdAt = 1L))
        store.save(ACCOUNT, record(conversation.id, u1.id, history, createdAt = 2L))

        val deleted = repository.deleteMessagesLocally(conversation.id, listOf(u1.id, a1.id), draftWhenEmpty = true)

        // Returns the rows read before the delete: the user row carries its attachment.
        assertEquals(setOf(u1.id, a1.id), deleted.map { it.id }.toSet())
        assertEquals(listOf(attached.id), deleted.single { it.id == u1.id }.attachments?.map { it.id })

        val after = requireNotNull(repository.getWithMessages(conversation.id))
        assertEquals(listOf(u0.id, a0.id), after.messages.map { it.id })
        assertFalse(after.isDraft)
        // The row whose coversTo is before the deleted messages stays; the row covering up to u1 is deleted locally.
        assertEquals(
            listOf(ContextCheckpoint.checkpointId(conversation.id, a0.id)),
            store.list(ACCOUNT, conversation.id).map { it.checkpointId },
        )

        // Rolling back the first message: the conversation returns to a draft.
        val first = repository.create(PROVIDER_ID, ProviderKind.Grok, MODEL_ID, useMemory = false)
        val firstUser = message(ChatRole.User, "first question")
        val firstAssistant = message(ChatRole.Assistant, "")
        repository.addMessage(first.id, firstUser)
        repository.addMessage(first.id, firstAssistant)
        assertFalse(requireNotNull(repository.getWithMessages(first.id)).isDraft)
        repository.deleteMessagesLocally(first.id, listOf(firstUser.id, firstAssistant.id), draftWhenEmpty = true)

        val draft = requireNotNull(repository.getWithMessages(first.id))
        assertTrue(draft.isDraft)
        assertTrue(draft.messages.isEmpty())
    }

    /** The first send is cancelled and rolled back: the conversation returns to a draft and the home list (same visibility rule as HomeViewModel) does not show it. */
    @Test
    fun rolled_back_draft_not_in_list() = runBlocking {
        val harness = GateHarness()
        val conversation = harness.repository.create(PROVIDER_ID, ProviderKind.Grok, MODEL_ID, useMemory = false)

        harness.sendAndCancel(conversation.id, attachments = null) { userRow ->
            // While the gate waits, this pair of messages is visible in the list (not a draft).
            val row = harness.repository.observeAll().first().single { it.id == conversation.id }
            assertTrue("pending send hidden: $row", !row.isDraft || row.messageCount > 0)
            assertEquals(ChatRole.User, userRow.role)
        }

        val row = harness.repository.observeAll().first().single { it.id == conversation.id }
        assertTrue(row.isDraft)
        assertEquals(0, row.messageCount)
        assertFalse("rolled back draft still listed: $row", !row.isDraft || row.messageCount > 0)
    }

    /** A ConversationRepository on real Room plus the production ChatRepository; the confirmation gate is answered with a cancel by the case. */
    private inner class GateHarness {
        val repository = ConversationRepository(
            db.conversationDao(), db.messageDao(),
            contextCompactionStore = ContextCompactionStore(db.contextCheckpointDao()),
        )
        val chatRequests = AtomicInteger(0)
        private val client = HttpClient(MockEngine {
            chatRequests.incrementAndGet()
            respond("{}", HttpStatusCode.InternalServerError, headersOf(HttpHeaders.ContentType, "application/json"))
        })
        private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
        private val coordinator = ContextCapConfirmCoordinator(
            store = ContextPriceLineConfirmStore { TestSharedPreferences() },
            reminderEnabled = { true },
        )
        private val rejections = ChatContextRejections()
        private val chat = ChatRepository(
            conversationRepository = repository,
            providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
                coEvery { it.getById(PROVIDER.id) } returns PROVIDER
            },
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = rejections,
            contextCapConfirm = coordinator,
        )

        /** Sends a message over the custom cap; while the gate is suspended it first runs [whilePending] (given the stored user row), then cancels. Returns the rollback event. */
        suspend fun sendAndCancel(
            conversationId: String,
            attachments: List<Attachment>?,
            whilePending: suspend (ChatMessage) -> Unit,
        ): ChatContextRejection = coroutineScope {
            val events = Collections.synchronizedList(mutableListOf<ChatContextRejection>())
            val collector = launch(Dispatchers.Unconfined) { rejections.events.collect { events += it } }
            val answer = launch {
                val pending = coordinator.pending.first { it.isNotEmpty() }.first()
                val userRow = requireNotNull(repository.getWithMessages(conversationId)).messages
                    .single { it.role == ChatRole.User }
                whilePending(userRow)
                coordinator.resolve(pending.id, ContextCapConfirmChoice.Cancel)
            }
            val conversation = requireNotNull(repository.getWithMessages(conversationId))
                .copy(contextCap = ContextBudgetCap.Custom(32_000))
            withTimeout(TIMEOUT_MS) {
                chat.sendMessage(
                    conversation = conversation,
                    text = "token ".repeat(40_000),
                    provider = PROVIDER,
                    modelID = MODEL_ID,
                    existingMessages = emptyList(),
                    attachments = attachments,
                    requestOptions = ChatRequestOptions(
                        activeModel = MODEL,
                        chatContext = ChatContextRequest(ContextConversation(id = conversationId, useMemory = false)),
                    ),
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
            answer.join()
            collector.cancel()
            client.close()
            assertEquals(0, chatRequests.get())
            events.single()
        }
    }

    private fun message(role: ChatRole, text: String) = ChatMessage(
        id = generateUuidString(),
        role = role,
        text = text,
        providerID = PROVIDER_ID,
        providerKind = ProviderKind.Grok,
        providerName = "Grok",
        modelID = MODEL_ID,
        modelName = "Grok 4.7",
        state = ChatMessageState.Delivered,
    )

    private fun record(
        conversationId: String,
        coversTo: String,
        history: List<CheckpointCoveredMessage>,
        createdAt: Long,
    ): ContextCheckpointRecord {
        val index = history.indexOfFirst { it.id == coversTo }
        val covered = history.subList(0, index + 1)
        return ContextCheckpointRecord(
            conversationId = conversationId,
            checkpointId = ContextCheckpoint.checkpointId(conversationId, coversTo),
            kind = ContextCheckpointKind.FALLBACK,
            coversFrom = history.first().id,
            coversTo = coversTo,
            coversDigest = ContextCheckpoint.coversDigest(covered),
            messagesCovered = covered.size,
            userMessageIds = emptyList(),
            text = "fallback text",
            summary = "summary",
            language = null,
            model = MODEL_ID,
            packerVersion = ContextCheckpoint.PACKER_VERSION,
            createdAt = createdAt,
            cost = null,
        )
    }

    private companion object {
        const val ACCOUNT = LOCAL_PARTITION_ID
        const val PROVIDER_ID = "grok-1"
        const val MODEL_ID = "grok-4.7"
        const val TIMEOUT_MS = 20_000L
        val MODEL = AIModel(id = MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)
        val PROVIDER = Provider(id = PROVIDER_ID, kind = ProviderKind.Grok, apiKey = "byok-key", models = listOf(MODEL))
    }
}
