package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ChatContextRejections
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.data.repository.ContextCompactionCoordinator
import ai.oriveo.community.core.data.repository.ContextCompactionResult
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.http.HttpHeaders
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.cancellation.CancellationException
import app.cash.turbine.test
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import ai.oriveo.community.core.streaming.ChatStreamingManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Presentation models of the separator row and the details (only the latestValid row is used, and tokens are estimated at display time).
 */
@RunWith(RobolectricTestRunner::class)
class ContextCompactionUiTest {

    @Test
    fun separator_summary_fields() {
        val messages = history(6)
        val row = record(ContextCheckpointKind.SUMMARY, coversTo = "m3", covered = 4, text = "summary text " + "x".repeat(4_000))

        val separator = ContextCompactionPresentation.separator(row, messages, RHO)!!

        val expectedBefore = messages.take(4).sumOf { ContextBudget.estimateMessage(it.text, RHO) }
        assertEquals(ContextCheckpointKind.SUMMARY, separator.kind)
        assertEquals(4, separator.count)
        assertEquals(expectedBefore, separator.before)
        assertEquals(ContextBudget.estimateMessage(row.text, RHO), separator.after)
        assertEquals(row.userMessageIds.size, separator.kept)
        assertEquals("gpt-test", separator.model)
        assertEquals("m3", separator.anchorMessageId)
        assertEquals("2K", ContextCompactionPresentation.compactTokenCount(separator.after, "en"))
        assertEquals("1.2M", ContextCompactionPresentation.compactTokenCount(1_200_000, "en"))
        assertEquals("999", ContextCompactionPresentation.compactTokenCount(999, "en"))
        assertNull(ContextCompactionPresentation.compactTokenCount(0, "en"))
    }

    @Test
    fun detail_kept_on_summary_row() {
        // Aligned across platforms: the separator row and the details of a summary row both carry kept = number of userMessageIds.
        val messages = history(6)
        val row = record(ContextCheckpointKind.SUMMARY, coversTo = "m3", covered = 4, summary = "s", userMessageIds = listOf("m0", "m2"))

        val separator = ContextCompactionPresentation.separator(row, messages, RHO)!!

        assertEquals(2, separator.kept)
        assertEquals(2, ContextCompactionPresentation.detail(row).kept)
    }

    @Test
    fun separator_fallback_counts() {
        val messages = history(8)
        val row = record(
            ContextCheckpointKind.FALLBACK,
            coversTo = "m4",
            covered = 5,
            userMessageIds = listOf("m0", "m2"),
        )

        val separator = ContextCompactionPresentation.separator(row, messages, RHO)!!

        // m0..m4: m1 and m3 are assistant messages.
        assertEquals(ContextCheckpointKind.FALLBACK, separator.kind)
        assertEquals(2, separator.count)
        assertEquals(2, separator.kept)
        assertNull(separator.before)
        assertNull(separator.after)
        assertEquals("m4", separator.anchorMessageId)
    }

    @Test
    fun separator_hidden_without_visible_checkpoint() {
        val messages = history(4)
        assertNull(ContextCompactionPresentation.separator(null, messages, RHO))
        val unloaded = record(ContextCheckpointKind.SUMMARY, coversTo = "m9", covered = 10)
        assertNull(ContextCompactionPresentation.separator(unloaded, messages, RHO))
    }

    @Test
    fun separator_from_production_fallback_row() = runTest {
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        val client = HttpClient(MockEngine { respond("", HttpStatusCode.InternalServerError) })
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            val store = ContextCompactionStore(db.contextCheckpointDao())
            val messages = longHistory(bytes = 1_600)
            val conversation = Conversation(
                id = CONVERSATION_ID,
                title = "Separator",
                providerID = PROVIDER.id,
                providerKind = PROVIDER.kind,
                modelID = MODEL.id,
                useMemory = false,
                messages = messages,
            )
            val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
            val coordinator = ContextCompactionCoordinator(
                store = store,
                accountId = { ACCOUNT },
                aiSummaryEnabled = { true },
                remoteCompactionEnabled = { false },
                upload = { _, _, _ -> },
            )
            val repository = ChatRepository(
                conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
                    coEvery { it.getWithMessages(CONVERSATION_ID) } returns conversation
                },
                providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                    every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
                    coEvery { it.getById(any()) } returns null
                    coEvery { it.getById(PROVIDER.id) } returns PROVIDER
                },
                attachmentStore = mockk<AttachmentStore>(relaxed = true),
                contextRejections = ChatContextRejections(),
                contextCompaction = coordinator,
            )

            val result = repository.compactConversationNow(CONVERSATION_ID)

            assertEquals(CompactOutcome.FALLBACK, result.outcome)
            val row = store.list(ACCOUNT, CONVERSATION_ID).single()
            val separator = ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0)!!
            val covered = messages.take(row.messagesCovered)
            assertEquals(ContextCheckpointKind.FALLBACK, separator.kind)
            assertTrue("fallback covers some assistant replies", separator.count > 0)
            assertEquals(covered.count { it.role == ChatRole.Assistant }, separator.count)
            assertEquals(row.userMessageIds.size, separator.kept)
            assertEquals(row.coversTo, separator.anchorMessageId)
            val detail = ContextCompactionPresentation.detail(row)
            assertEquals(ContextCompactionCost.NoExtraCost, detail.cost)
            assertNull(detail.summary)
        } finally {
            client.close()
            db.close()
        }
    }

    @Test
    fun detail_cost_unavailable_when_null() {
        val summary = ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
        val unpriced = record(ContextCheckpointKind.SUMMARY, coversTo = "m3", covered = 4, summary = summary, cost = null)
        val detail = ContextCompactionPresentation.detail(unpriced)
        assertEquals(ContextCompactionCost.Unavailable, detail.cost)
        assertEquals(summary, detail.summary)
        assertEquals(1, detail.kept)
        assertEquals("gpt-test", detail.model)
        assertEquals(CREATED_AT, detail.createdAt)

        val priced = ContextCompactionPresentation.detail(unpriced.copy(cost = 0.0123))
        assertEquals(ContextCompactionCost.Amount(0.0123), priced.cost)

        // A fallback is always "no extra cost" whatever the cost field says; a blank summary is not shown.
        val fallback = ContextCompactionPresentation.detail(unpriced.copy(kind = ContextCheckpointKind.FALLBACK, summary = "  "))
        assertEquals(ContextCompactionCost.NoExtraCost, fallback.cost)
        assertNull(fallback.summary)
    }

    // ── transcript separator (separator) ──

    @Test
    fun transcript_separator_anchor() = runTest {
        withStore { store ->
            val messages = history(6)
            store.save(ACCOUNT, validRecord(messages, "m3"))

            val transcript = actions(store, messages, rhoHi = RHO).transcriptSeparator(CONVERSATION_ID)!!

            // The row hangs after coversTo (m3): it is drawn at the top of the item of the next message m4.
            assertEquals("m3", transcript.separator.anchorMessageId)
            assertEquals("m4", transcript.drawAboveMessageId)
            assertEquals(4, transcript.separator.count)
            assertEquals(messages.take(4).sumOf { ContextBudget.estimateMessage(it.text, RHO) }, transcript.separator.before)
            assertEquals("s", transcript.detail.summary)
        }
    }

    @Test
    fun transcript_separator_refreshes_on_change() = runTest {
        withStore { store ->
            val messages = history(6)
            val coordinator = actions(store, messages, rhoHi = RHO)
            val conversationId = MutableStateFlow<String?>(CONVERSATION_ID)
            val state = coordinator.separatorFlow(conversationId, flowOf(Unit))
                .stateIn(backgroundScope, SharingStarted.Eagerly, null)
            runCurrent()

            state.test {
                assertNull(awaitItem())
                store.save(ACCOUNT, validRecord(messages, "m3"))
                assertEquals("m4", awaitItem()?.drawAboveMessageId)
                store.deleteAll(ACCOUNT, CONVERSATION_ID)
                assertNull(awaitItem())
                cancelAndIgnoreRemainingEvents()
            }
        }
    }

    // ── actions (clear / recompact / manual) ──

    @Test
    fun clear_deletes_all() = runTest {
        withStore { store ->
            val messages = history(6)
            store.save(ACCOUNT, validRecord(messages, "m1"))
            store.save(ACCOUNT, validRecord(messages, "m3"))
            val actions = actions(store, messages)
            assertEquals(ContextCompactionToast.CLEARED, actions.clear(CONVERSATION_ID))
            assertTrue(store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
        }
    }

    @Test
    fun recompact_drops_latest_then_manual() = runTest {
        withStore { store ->
            val messages = history(6)
            store.save(ACCOUNT, validRecord(messages, "m1"))
            store.save(ACCOUNT, validRecord(messages, "m3"))
            var rowsAtCompaction: List<String>? = null
            val actions = actions(store, messages) {
                rowsAtCompaction = store.list(ACCOUNT, CONVERSATION_ID).map { it.checkpointId }
                CompactOutcome.SUMMARY
            }
            assertNull(actions.recompact(CONVERSATION_ID))
            assertEquals(listOf("cp-m1"), rowsAtCompaction)
            assertEquals(listOf("cp-m1"), store.list(ACCOUNT, CONVERSATION_ID).map { it.checkpointId })
        }
    }

    @Test
    fun manual_result_toasts() = runTest {
        withStore { store ->
            val messages = history(4)
            fun withOutcome(outcome: CompactOutcome) = actions(store, messages) { outcome }
            assertNull(withOutcome(CompactOutcome.SUMMARY).manualCompact(CONVERSATION_ID))
            assertEquals(ContextCompactionToast.FALLBACK, withOutcome(CompactOutcome.FALLBACK).manualCompact(CONVERSATION_ID))
            assertEquals(ContextCompactionToast.NOOP, withOutcome(CompactOutcome.NOOP).manualCompact(CONVERSATION_ID))
        }
    }

    @Test
    fun manual_compaction_passes_chat_context_from_caller() = runTest {
        withStore { store ->
            val messages = history(4)
            val memory = listOf(
                ai.oriveo.community.core.context.MemoryItem(
                    id = "m-1", kind = ai.oriveo.community.core.context.MemoryKind.FACT, content = "remember me",
                    mutationId = "mutation-1", deviceId = "device-1",
                ),
            )
            val chatContext = ChatContextRequest(
                conversation = ContextConversation(id = CONVERSATION_ID, useMemory = true, skillPrompt = "skill"),
                memoryItems = ChatContextRequest.memoryItems(true, memory, CONVERSATION_ID, null, java.time.Instant.now()),
            )
            val options = ChatRequestOptions(temperature = 0.25f)
            val memorySeen = mutableListOf<List<ai.oriveo.community.core.context.MemoryItem>>()
            var seen: Triple<String, ChatContextRequest?, ChatRequestOptions?>? = null
            val actions = ChatCompactionUiCoordinator(
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { id -> conversation(messages).takeIf { it.id == id } },
                memoryItems = { memory },
                chatContext = { conversation, items ->
                    memorySeen += items
                    assertEquals(CONVERSATION_ID, conversation.id)
                    chatContext
                },
                requestOptions = { options },
                compactNow = { id, context, requestOptions ->
                    seen = Triple(id, context, requestOptions)
                    ContextCompactionResult(CompactOutcome.SUMMARY, null, emptyList())
                },
            )
            actions.manualCompact(CONVERSATION_ID)
            assertEquals(Triple(CONVERSATION_ID, chatContext, options), seen)
            assertEquals(listOf(memory), memorySeen)
        }
    }

    @Test
    fun third_compaction_hint_once() = runTest {
        // After the local write the count == 3 and this process has not prompted for this conversation -> prompt once; acknowledged -> collapse and do not prompt again.
        withStore { store ->
            val messages = longHistory(bytes = 1_600)
            val hint = ThirdCompactionHint()
            val repository = fallbackRepository(store, messages, onSaved = hint::onSaved)
            val actions = actions(store, messages, hint = hint)
            store.save(ACCOUNT, record(ContextCheckpointKind.FALLBACK, coversTo = "x1", covered = 1))

            assertEquals(CompactOutcome.FALLBACK, repository.compactConversationNow(CONVERSATION_ID).outcome)
            val produced = store.list(ACCOUNT, CONVERSATION_ID).single { it.checkpointId != "cp-x1" }.checkpointId
            assertNull("two rows: no hint", actions.hint.value)

            store.delete(ACCOUNT, CONVERSATION_ID, listOf(produced))
            store.save(ACCOUNT, record(ContextCheckpointKind.FALLBACK, coversTo = "x2", covered = 1))
            assertEquals(CompactOutcome.FALLBACK, repository.compactConversationNow(CONVERSATION_ID).outcome)
            assertEquals(3, store.list(ACCOUNT, CONVERSATION_ID).size)
            assertEquals(CONVERSATION_ID, actions.hint.value)

            actions.dismissHint()
            assertNull(actions.hint.value)
            store.delete(ACCOUNT, CONVERSATION_ID, listOf(produced))
            assertEquals(CompactOutcome.FALLBACK, repository.compactConversationNow(CONVERSATION_ID).outcome)
            assertEquals(3, store.list(ACCOUNT, CONVERSATION_ID).size)
            assertNull("shown once per process", actions.hint.value)
        }
    }

    @Test
    fun detail_actions_wired() = runTest {
        // The three buttons of the details each call a coordinator action and close the sheet after a tap; re-condense is disabled while running; the toast maps to a localized key.
        withStore { store ->
            val messages = history(6)
            store.save(ACCOUNT, validRecord(messages, coversTo = "m3"))
            val gate = CompletableDeferred<Unit>()
            val compacted = mutableListOf<String>()
            val started = CompletableDeferred<QuoteContext?>()
            val coordinator = hosted(store, messages, backgroundScope, startNewChatWith = { started.complete(it) }) {
                compacted += CONVERSATION_ID
                gate.await()
                CompactOutcome.NOOP
            }
            var closed = 0
            val label = RuntimeEnvironment.getApplication().getString(R.string.context_compaction_quote_label)
            val actions = coordinator.detailActions(label) { closed++ }

            coordinator.toasts.test {
                actions.onRecompact()
                assertEquals(1, closed)
                assertTrue("recompact disabled while running", coordinator.actionRunning.value)
                gate.complete(Unit)
                assertEquals(ContextCompactionToast.NOOP, awaitItem())
                assertEquals(false, coordinator.actionRunning.value)
                assertEquals(listOf(CONVERSATION_ID), compacted)
                assertTrue("recompact dropped the latest row", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())

                store.save(ACCOUNT, validRecord(messages, coversTo = "m3"))
                actions.onClear()
                assertEquals(2, closed)
                assertEquals(ContextCompactionToast.CLEARED, awaitItem())
                assertTrue(store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
            }

            store.save(ACCOUNT, validRecord(messages, coversTo = "m3"))
            actions.onNewChatWithSummary()
            assertEquals(3, closed)
            assertEquals(label, started.await()?.leadingText)
        }
        assertEquals(R.string.context_compaction_toast_cleared, ContextCompactionToast.CLEARED.messageRes)
        assertEquals(R.string.context_compaction_toast_fallback, ContextCompactionToast.FALLBACK.messageRes)
        assertEquals(R.string.context_compaction_toast_noop, ContextCompactionToast.NOOP.messageRes)
    }

    @Test
    fun new_chat_consumes_pending_quote() = runTest {
        // Starting a new conversation with the summary -> clear the old quote first and open the new conversation, then attach the quote with its label to the input as pending; nothing is sent automatically.
        withStore { store ->
            val messages = history(6)
            store.save(ACCOUNT, validRecord(messages, coversTo = "m3"))
            val quotes = ChatQuoteCoordinator()
            var newChats = 0
            val conversation = MutableStateFlow(ConversationRenderState(conversation(messages)))
            val host = ChatCompactionUiCoordinator.newChatHost(backgroundScope, conversation, quotes) {
                newChats++
                quotes.clear()
            }
            val hint = ThirdCompactionHint().apply { onSaved(CONVERSATION_ID, 3) }
            val coordinator = hosted(store, messages, backgroundScope, host = host, hint = hint)
            val label = RuntimeEnvironment.getApplication().getString(R.string.context_compaction_quote_label)

            coordinator.startNewChatWithSummary(label)?.join()

            assertEquals(1, newChats)
            assertNull("hint dismissed", coordinator.hint.value)
            val pending = quotes.pending!!
            assertEquals(label, pending.leadingText)
            assertEquals("m3", pending.sourceMessageId)
            assertEquals(ChatRole.Assistant, pending.sourceRole)
            assertEquals("s", pending.selectedText)
        }
    }

    @Test
    fun new_chat_quote_from_summary() = runTest {
        // A non-empty summary is quoted; anything over 8000 graphemes is truncated at the tail.
        val messages = history(6)
        val row = record(ContextCheckpointKind.SUMMARY, coversTo = "m3", covered = 4, summary = "Summary text")
        val quote = ChatCompactionUiCoordinator.summaryQuote(row, messages, LABEL)!!
        assertEquals("m3", quote.sourceMessageId)
        assertEquals(ChatRole.Assistant, quote.sourceRole)
        assertEquals(LABEL, quote.leadingText)
        assertEquals("Summary text", quote.selectedText)
        assertEquals("", quote.trailingText)
        assertTrue(quote.isValid)

        val long = "😀".repeat(9_000)
        val truncated = ChatCompactionUiCoordinator.summaryQuote(row.copy(summary = long), messages, LABEL)!!
        assertEquals(QuoteContext.MAXIMUM_GRAPHEME_COUNT - LABEL.graphemeCount(), truncated.selectedText.graphemeCount())
        assertTrue(long.startsWith(truncated.selectedText))
        assertTrue(truncated.isValid)

        // No summary and no original messages -> no quote.
        assertNull(ChatCompactionUiCoordinator.summaryQuote(row.copy(summary = " ", userMessageIds = emptyList()), messages, LABEL))
    }

    @Test
    fun new_chat_quote_from_fallback() = runTest {
        // With an empty summary, the original messages of userMessageIds are used, one paragraph each in time order; if too long the oldest are dropped, and if a single one is still too long it is truncated at the tail.
        withStore { store ->
            val messages = longHistory(bytes = 1_600)
            fallbackRepository(store, messages).compactConversationNow(CONVERSATION_ID)
            val row = store.list(ACCOUNT, CONVERSATION_ID).single()
            assertNull(row.summary)
            assertTrue(row.userMessageIds.isNotEmpty())
            val actions = actions(store, messages)
            val quote = actions.quoteForNewChat(CONVERSATION_ID, LABEL)!!
            val expected = messages.filter { it.id in row.userMessageIds.toSet() }.joinToString("\n\n") { it.text }
            assertEquals(expected, quote.selectedText)
            assertEquals(row.coversTo, quote.sourceMessageId)
            assertEquals(ChatRole.Assistant, quote.sourceRole)
            assertEquals(LABEL, quote.leadingText)
            assertTrue(quote.isValid)
        }

        val big = listOf(
            message("u0", ChatRole.User, "oldest " + "a".repeat(3_000)),
            message("a0", ChatRole.Assistant, "reply"),
            message("u1", ChatRole.User, "middle " + "b".repeat(3_000)),
            message("u2", ChatRole.User, "newest " + "c".repeat(3_000)),
        )
        val row = record(ContextCheckpointKind.FALLBACK, coversTo = "a0", covered = 4, userMessageIds = listOf("u2", "u0", "u1"))
        val dropped = ChatCompactionUiCoordinator.summaryQuote(row, big, LABEL)!!
        assertEquals(big[2].text + "\n\n" + big[3].text, dropped.selectedText)
        assertTrue(dropped.isValid)

        val huge = listOf(message("u0", ChatRole.User, "x".repeat(5_000)), message("u1", ChatRole.User, "y".repeat(9_000)))
        val single = ChatCompactionUiCoordinator.summaryQuote(row.copy(userMessageIds = listOf("u0", "u1")), huge, LABEL)!!
        assertEquals("y".repeat(QuoteContext.MAXIMUM_GRAPHEME_COUNT - LABEL.graphemeCount()), single.selectedText)
        assertTrue(single.isValid)
    }

    @Test
    fun quote_marks_truncated_when_dropped() {
        // Aligned across platforms: contextTruncated = true when the summary is truncated or original messages are dropped or truncated, and false when everything fits as is.
        val messages = history(6)
        val summaryRow = record(ContextCheckpointKind.SUMMARY, coversTo = "m3", covered = 4, summary = "Summary text")
        assertEquals(false, ChatCompactionUiCoordinator.summaryQuote(summaryRow, messages, LABEL)!!.contextTruncated)
        val cut = ChatCompactionUiCoordinator.summaryQuote(summaryRow.copy(summary = "s".repeat(9_000)), messages, LABEL)!!
        assertEquals(true, cut.contextTruncated)

        val fits = record(ContextCheckpointKind.FALLBACK, coversTo = "m3", covered = 4, userMessageIds = listOf("m0", "m2"))
        assertEquals(false, ChatCompactionUiCoordinator.summaryQuote(fits, messages, LABEL)!!.contextTruncated)

        val big = listOf(
            message("u0", ChatRole.User, "oldest " + "a".repeat(3_000)),
            message("u1", ChatRole.User, "middle " + "b".repeat(3_000)),
            message("u2", ChatRole.User, "newest " + "c".repeat(3_000)),
        )
        val dropRow = record(ContextCheckpointKind.FALLBACK, coversTo = "u2", covered = 3, userMessageIds = listOf("u0", "u1", "u2"))
        val dropped = ChatCompactionUiCoordinator.summaryQuote(dropRow, big, LABEL)!!
        assertEquals(big[1].text + "\n\n" + big[2].text, dropped.selectedText)
        assertEquals(true, dropped.contextTruncated)

        val huge = listOf(message("u0", ChatRole.User, "y".repeat(9_000)))
        val single = ChatCompactionUiCoordinator.summaryQuote(dropRow.copy(userMessageIds = listOf("u0")), huge, LABEL)!!
        assertEquals(true, single.contextTruncated)
    }

    // ── in progress, cancel and stop (running state) ──

    @Test
    fun compacting_state_and_cancel_falls_back() = runTest {
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val harness = SummaryHarness(store, messages)

            // Manual: in progress while the summary call runs; cancel saves nothing and returns noop.
            val manual = async { harness.repository.compactConversationNow(CONVERSATION_ID) }
            harness.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), harness.coordinator.aiCompacting.value)
            harness.coordinator.cancel(CONVERSATION_ID)
            assertEquals(CompactOutcome.NOOP, manual.await().outcome)
            assertTrue("cancelled manual saves nothing", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
            assertEquals(emptySet<String>(), harness.coordinator.aiCompacting.value)

            // Pre-send: cancel falls back to the deterministic row and the send goes on.
            harness.resetSummary()
            val send = launch { runCatching { harness.send(messages.dropLast(1)) } }
            harness.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), harness.coordinator.aiCompacting.value)
            harness.coordinator.cancel(CONVERSATION_ID)
            send.join()

            assertEquals(emptySet<String>(), harness.coordinator.aiCompacting.value)
            val requests = harness.requests()
            assertEquals("summary then chat: ${requests.map { it.take(60) }}", 2, requests.size)
            assertTrue("chat request follows", !harness.isSummary(requests[1]))
            val row = store.list(ACCOUNT, CONVERSATION_ID).single()
            assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
            assertTrue("chat carries the fallback row", "<oriveo-context-checkpoint" in requests[1])
            assertEquals("cancel is not a failure", 0, harness.coordinator.breaker(CONVERSATION_ID).failures)
        }
    }

    @Test
    fun stop_during_compaction_saves_nothing() = runTest {
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val harness = SummaryHarness(store, messages)
            var thrown: Throwable? = null
            // Stop cancels the whole send coroutine (ChatStreamingManager.stopStream cancels the session job).
            val send = launch { thrown = runCatching { harness.send(messages.dropLast(1)) }.exceptionOrNull() }
            harness.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), harness.coordinator.aiCompacting.value)
            send.cancel()
            send.join()

            assertTrue("cancellation is not swallowed: $thrown", thrown is CancellationException)
            assertEquals("no chat request after stop", 1, harness.requests().size)
            assertTrue("stop saves no checkpoint", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
            assertEquals(emptySet<String>(), harness.coordinator.aiCompacting.value)
            assertEquals(0, harness.coordinator.breaker(CONVERSATION_ID).failures)
        }
    }

    @Test
    fun stop_during_compaction_finalizes_placeholder() = runTest {
        // Stop while condensing: the placeholder assistant message ends as "stopped before the first token" (Interrupted, empty text, INTERRUPTED) and no Generating is left.
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val harness = SummaryHarness(store, messages)
            val send = launch { runCatching { harness.send(messages.dropLast(1)) } }
            harness.summaryStarted.await()
            send.cancel()
            send.join()

            val added = mutableListOf<ChatMessage>()
            val updated = mutableListOf<ChatMessage>()
            coVerify { harness.conversationRepository.addMessage(CONVERSATION_ID, capture(added)) }
            coVerify { harness.conversationRepository.updateMessage(CONVERSATION_ID, capture(updated)) }
            val placeholder = added.single { it.role == ChatRole.Assistant }
            assertEquals(ChatMessageState.Generating, placeholder.state)
            val finalized = updated.last { it.id == placeholder.id }
            assertEquals(ChatMessageState.Interrupted, finalized.state)
            assertEquals(StopReason.INTERRUPTED, finalized.stopReason)
            assertEquals("", finalized.text)
        }
    }

    // ── pre-compaction on focus / first input (focus / first input) ──

    @Test
    fun precompaction_on_focus_ai_only() = runTest {
        withStore { store ->
            val messages = longHistory(bytes = 1_500)

            // AI mode and P-hat >= 0.75 B: one summary request, the summary row is stored.
            val ai = SummaryHarness(store, messages, hang = false)
            val saved = ai.repository.precompactIfNeeded(CONVERSATION_ID)
            assertEquals(CompactOutcome.SUMMARY, saved.outcome)
            assertEquals(1, ai.requests().size)
            assertTrue("summary request", ai.isSummary(ai.requests().single()))
            assertEquals(ContextCheckpointKind.SUMMARY, store.list(ACCOUNT, CONVERSATION_ID).single().kind)
            store.deleteAll(ACCOUNT, CONVERSATION_ID)

            // Preference off, P-hat below 0.75 B: no request, nothing stored.
            val off = SummaryHarness(store, messages, aiSummary = false)
            assertEquals(CompactOutcome.NOOP, off.repository.precompactIfNeeded(CONVERSATION_ID).outcome)
            assertTrue("preference off sends nothing", off.requests().isEmpty())
            val short = SummaryHarness(store, longHistory(bytes = 200))
            assertEquals(CompactOutcome.NOOP, short.repository.precompactIfNeeded(CONVERSATION_ID).outcome)
            assertTrue("P-hat below 0.75 B sends nothing", short.requests().isEmpty())
            assertTrue(store.list(ACCOUNT, CONVERSATION_ID).isEmpty())

            // Already running: the second call sends nothing; a cancelled pre-compaction stores no fallback row.
            val running = SummaryHarness(store, messages)
            val first = async { running.repository.precompactIfNeeded(CONVERSATION_ID) }
            running.summaryStarted.await()
            assertEquals(CompactOutcome.NOOP, running.repository.precompactIfNeeded(CONVERSATION_ID).outcome)
            assertEquals("no second summary request", 1, running.requests().size)
            running.coordinator.cancel(CONVERSATION_ID)
            assertEquals(CompactOutcome.NOOP, first.await().outcome)
            assertTrue("cancelled pre-compaction stores nothing", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
        }
    }

    @Test
    fun precompaction_launch_dedups_per_conversation() = runTest {
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val gate = CompletableDeferred<Unit>()
            var calls = 0
            val ui = ChatCompactionUiCoordinator(
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { id -> conversation(messages).takeIf { it.id == id } },
                memoryItems = { emptyList() },
                chatContext = { conversation, _ -> ChatContextRequest(ContextConversation(conversation.id, conversation.useMemory)) },
                requestOptions = { ChatRequestOptions() },
                compactNow = { _, _, _ -> error("manual compaction not expected") },
                precompact = { _, _, _ ->
                    calls++
                    gate.await()
                    ContextCompactionResult(CompactOutcome.SUMMARY, null, emptyList())
                },
                host = ChatCompactionUiCoordinator.Host(
                    this@runTest,
                    MutableStateFlow(ConversationRenderState(conversation(messages))),
                ) {},
            )
            val job = ui.launchPrecompact()
            runCurrent()
            assertNull("second launch while running is skipped", ui.launchPrecompact())
            gate.complete(Unit)
            job?.join()
            assertEquals(1, calls)
            ui.launchPrecompact()?.join()
            assertEquals("runs again once the first finished", 2, calls)
        }
    }

    // ── review fixes: send button, stop, single flight, action failures ──

    @Test
    fun precompaction_does_not_block_send() = runTest {
        // Only a compaction inside a send turns the send button into stop; pre-compaction and manual do not.
        withStore { store ->
            val messages = longHistory(bytes = 1_500)

            val pre = SummaryHarness(store, messages)
            val precompaction = async { pre.repository.precompactIfNeeded(CONVERSATION_ID) }
            pre.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), pre.coordinator.aiCompacting.value)
            assertEquals("pre-compaction is not a send", emptySet<String>(), pre.coordinator.sendCompacting.value)
            pre.coordinator.cancel(CONVERSATION_ID)
            precompaction.await()

            val manual = SummaryHarness(store, messages)
            val manualRun = async { manual.repository.compactConversationNow(CONVERSATION_ID) }
            manual.summaryStarted.await()
            assertEquals("manual is not a send", emptySet<String>(), manual.coordinator.sendCompacting.value)
            manual.coordinator.cancel(CONVERSATION_ID)
            manualRun.await()

            val send = SummaryHarness(store, messages)
            val sending = launch { runCatching { send.send(messages.dropLast(1)) } }
            send.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), send.coordinator.sendCompacting.value)
            send.coordinator.cancel(CONVERSATION_ID)
            sending.join()
            assertEquals(emptySet<String>(), send.coordinator.sendCompacting.value)
        }
    }

    @Test
    fun stop_send_before_register_writes_no_fallback_row() = runTest {
        // stop during a send compaction must not cancel the summary before the stop lands (that would
        // save a fallback row); the send coroutine is cancelled and nothing is stored.
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val harness = SummaryHarness(store, messages)
            val aiCancels = mutableListOf<String>()
            val confirmCancels = mutableListOf<String>()
            val ui = ChatCompactionUiCoordinator(
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { null },
                memoryItems = { emptyList() },
                chatContext = { conversation, _ -> ChatContextRequest(ContextConversation(conversation.id, conversation.useMemory)) },
                requestOptions = { ChatRequestOptions() },
                compactNow = { _, _, _ -> ContextCompactionResult(CompactOutcome.NOOP, null, emptyList()) },
                sendCompacting = harness.coordinator.sendCompacting,
                cancelAi = { id -> aiCancels += id; harness.coordinator.cancel(id) },
                cancelConfirm = { id -> confirmCancels += id },
            )
            val send = launch { runCatching { harness.send(messages.dropLast(1)) } }
            harness.summaryStarted.await()
            assertEquals(setOf(CONVERSATION_ID), harness.coordinator.sendCompacting.value)

            ui.stopSend(CONVERSATION_ID)
            send.cancel()
            send.join()

            assertEquals(emptyList<String>(), aiCancels)
            assertEquals(listOf(CONVERSATION_ID), confirmCancels)
            assertEquals("no chat request after stop", 1, harness.requests().size)
            assertTrue("stop writes no fallback row", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())

            // Outside a send compaction (manual / pre-compaction) the stop still cancels the AI summary.
            ui.stopSend("other")
            assertEquals(listOf("other"), aiCancels)
        }
    }

    @Test
    fun separator_zero_tokens_shows_zero() {
        // Measured 0 shows 0; only an unmeasured value is "not available" (same as iOS / Web).
        assertEquals("0", ContextCompactionPresentation.separatorTokenText(0, "en"))
        assertEquals("999", ContextCompactionPresentation.separatorTokenText(999, "en"))
        assertEquals("1.2M", ContextCompactionPresentation.separatorTokenText(1_200_000, "en"))
        assertNull(ContextCompactionPresentation.separatorTokenText(null, "en"))
        // The detail panel keeps compactTokenCount (0 → null there).
        assertNull(ContextCompactionPresentation.compactTokenCount(0, "en"))
    }

    @Test
    fun stop_generation_cancels_send_compaction() = runTest {
        val main = kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)
        kotlinx.coroutines.Dispatchers.setMain(main)
        try {
            val coordinator = mockk<ContextCompactionCoordinator>(relaxed = true).also {
                every { it.aiCompacting } returns MutableStateFlow(emptySet())
                every { it.sendCompacting } returns MutableStateFlow(setOf(CONVERSATION_ID))
            }
            val streaming = mockk<ChatStreamingManager>(relaxed = true).also {
                every { it.sessionsVersion } returns MutableStateFlow(0L)
            }
            val viewModel = stopViewModel(streaming, coordinator)

            viewModel.stopGeneration()

            // the send compaction ends with the send (stopStream); cancelling its summary first would fall back.
            verify(exactly = 1) { streaming.stopStream(CONVERSATION_ID) }
            verify(exactly = 0) { coordinator.cancel(CONVERSATION_ID) }
        } finally {
            kotlinx.coroutines.Dispatchers.resetMain()
        }
    }

    @Test
    fun send_waits_for_inflight_precompaction() = runTest {
        // Same conversation: the send waits for the running pre-compaction, then re-reads latestValid and
        // uses the new row instead of starting a second summary call.
        withStore { store ->
            val messages = longHistory(bytes = 1_500)
            val gate = CompletableDeferred<Unit>()
            val harness = SummaryHarness(store, messages, gate = gate)
            val precompaction = async { harness.repository.precompactIfNeeded(CONVERSATION_ID) }
            harness.summaryStarted.await()

            val send = launch { harness.send(messages.dropLast(1)) }
            harness.coordinator.sendCompacting.first { CONVERSATION_ID in it }
            gate.complete(Unit)
            assertEquals(CompactOutcome.SUMMARY, precompaction.await().outcome)
            send.join()

            val requests = harness.requests()
            assertEquals("one summary, then chat: ${requests.map { it.take(60) }}", 1, requests.count(harness::isSummary))
            assertTrue("chat carries the pre-compaction row", "<oriveo-context-checkpoint" in requests.last { !harness.isSummary(it) })
            assertEquals(ContextCheckpointKind.SUMMARY, store.list(ACCOUNT, CONVERSATION_ID).single().kind)
            assertEquals(emptySet<String>(), harness.coordinator.sendCompacting.value)
        }
    }

    @Test
    fun clear_failure_does_not_crash() = runTest {
        val store = mockk<ContextCompactionStore>(relaxed = true).also {
            coEvery { it.deleteAll(any(), any()) } throws IllegalStateException("disk I/O error")
        }
        val ui = hosted(store, history(4), this)
        ui.toasts.test {
            ui.launchClear()!!.join()
            expectNoEvents()
        }
        assertEquals("the action can run again", false, ui.actionRunning.value)
    }

    private fun stopViewModel(streaming: ChatStreamingManager, coordinator: ContextCompactionCoordinator): ChatViewModel {
        val windowStore = MessageWindowFakeStore()
        val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            it.stubMessageWindowLoaderDefaults(windowStore)
        }
        val preferences = mockk<ai.oriveo.community.core.app.AppPreferencesRepository>(relaxed = true).also {
            every { it.lastUsedModelRef } returns flowOf(null)
            every { it.memoryText } returns MutableStateFlow("")
            every { it.memoryAntiForgetEnabled } returns MutableStateFlow(false)
            every { it.memoryAntiForgetText } returns MutableStateFlow("")
        }
        return ChatViewModel(
            savedStateHandle = androidx.lifecycle.SavedStateHandle(mapOf("conversationId" to CONVERSATION_ID)),
            context = mockk<Context>(relaxed = true),
            appPreferencesRepository = preferences,
            providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.observeAll() } returns flowOf(listOf(PROVIDER))
            },
            conversationRepository = conversationRepository,
            noteRepository = mockk(relaxed = true),
            chatStreamingManager = streaming,
            skillRepository = mockk(relaxed = true),
            attachmentProcessor = mockk(relaxed = true),
            globalSnackbarManager = mockk(relaxed = true),
            applicationScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main),
            compactionDeps = ChatCompactionDeps(
                chatRepository = mockk(relaxed = true),
                store = mockk(relaxed = true),
                thirdHint = ThirdCompactionHint(),
                conversationRepository = conversationRepository,
                accountId = { ACCOUNT },
                contextCompaction = coordinator,
            ),
        )
    }

    /**
     * Real ChatRepository + coordinator. With [hang] the summary call hangs until cancelled;
     * otherwise it answers a valid summary.
     */
    private inner class SummaryHarness(
        store: ContextCompactionStore,
        messages: List<ChatMessage>,
        aiSummary: Boolean = true,
        provider: Provider = PROVIDER,
        hang: Boolean = true,
        /** When set, the summary call waits for it and then answers a valid summary (overrides [hang]). */
        private val gate: CompletableDeferred<Unit>? = null,
    ) {
        private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
        private val bodies = mutableListOf<String>()

        @Volatile
        var summaryStarted = CompletableDeferred<Unit>()
            private set

        fun resetSummary() {
            summaryStarted = CompletableDeferred()
            synchronized(bodies) { bodies.clear() }
        }

        fun requests(): List<String> = synchronized(bodies) { bodies.toList() }

        fun isSummary(body: String) =
            json.parseToJsonElement(body).jsonObject["stream"]?.jsonPrimitive?.content == "false"

        private val client = HttpClient(MockEngine { request ->
            val body = when (val content = request.body) {
                is TextContent -> content.text
                is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                else -> error("Unsupported request body type: ${content::class.java.name}")
            }
            synchronized(bodies) { bodies += body }
            if (isSummary(body)) {
                summaryStarted.complete(Unit)
                if (gate != null) gate.await() else if (hang) awaitCancellation()
                val reply = buildJsonObject {
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", VALID_SUMMARY) }) })
                    put("usage", buildJsonObject { put("input_tokens", 10); put("output_tokens", 10) })
                }
                respond(reply.toString(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            }
        })

        val coordinator = ContextCompactionCoordinator(
            store = store,
            accountId = { ACCOUNT },
            aiSummaryEnabled = { aiSummary },
            remoteCompactionEnabled = { true },
            upload = { _, _, _ -> },
        )

        val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.getWithMessages(CONVERSATION_ID) } returns
                conversation(messages).copy(useMemory = false, providerKind = provider.kind)
        }

        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
                coEvery { it.getById(any()) } returns null
                coEvery { it.getById(PROVIDER.id) } returns provider
            },
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = ChatContextRejections(),
            contextCompaction = coordinator,
        )

        suspend fun send(existing: List<ChatMessage>) {
            repository.sendMessage(
                conversation = conversation(emptyList()).copy(useMemory = false),
                text = "Next question",
                provider = PROVIDER,
                modelID = MODEL.id,
                existingMessages = existing,
                requestOptions = ChatRequestOptions(
                    activeModel = MODEL,
                    chatContext = ChatContextRequest(ContextConversation(id = CONVERSATION_ID, useMemory = false)),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
            )
        }
    }

    /** Production fallback path (remote flag off): ChatRepository → ContextCompactionCoordinator → store. */
    private fun fallbackRepository(
        store: ContextCompactionStore,
        messages: List<ChatMessage>,
        onSaved: (String, Int) -> Unit = { _, _ -> },
    ): ChatRepository {
        val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
        val client = HttpClient(MockEngine { respond("", HttpStatusCode.InternalServerError) })
        val coordinator = ContextCompactionCoordinator(
            store = store,
            accountId = { ACCOUNT },
            aiSummaryEnabled = { true },
            remoteCompactionEnabled = { false },
            upload = { _, _, _ -> },
            onSaved = onSaved,
        )
        return ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
                coEvery { it.getWithMessages(CONVERSATION_ID) } returns conversation(messages)
            },
            providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
                coEvery { it.getById(any()) } returns null
                coEvery { it.getById(PROVIDER.id) } returns PROVIDER
            },
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = ChatContextRejections(),
            contextCompaction = coordinator,
        )
    }

    private suspend fun withStore(block: suspend (ContextCompactionStore) -> Unit) {
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            block(ContextCompactionStore(db.contextCheckpointDao()))
        } finally {
            db.close()
        }
    }

    private fun actions(
        store: ContextCompactionStore,
        messages: List<ChatMessage>,
        hint: ThirdCompactionHint = ThirdCompactionHint(),
        rhoHi: Double = ContextBudget.RHO0,
        outcome: suspend () -> CompactOutcome = { CompactOutcome.SUMMARY },
    ) = ChatCompactionUiCoordinator(
        store = store,
        accountId = { ACCOUNT },
        loadConversation = { id -> conversation(messages).takeIf { it.id == id } },
        memoryItems = { emptyList() },
        chatContext = { conversation, _ -> ChatContextRequest(ContextConversation(conversation.id, conversation.useMemory)) },
        requestOptions = { ChatRequestOptions() },
        compactNow = { _, _, _ -> ContextCompactionResult(outcome(), null, emptyList()) },
        thirdHint = hint,
        rhoHi = { rhoHi },
    )

    private fun hosted(
        store: ContextCompactionStore,
        messages: List<ChatMessage>,
        scope: kotlinx.coroutines.CoroutineScope,
        startNewChatWith: suspend (QuoteContext?) -> Unit = {},
        host: ChatCompactionUiCoordinator.Host = ChatCompactionUiCoordinator.Host(
            scope,
            MutableStateFlow(ConversationRenderState(conversation(messages))),
            startNewChatWith,
        ),
        hint: ThirdCompactionHint = ThirdCompactionHint(),
        outcome: suspend () -> CompactOutcome = { CompactOutcome.SUMMARY },
    ) = ChatCompactionUiCoordinator(
        store = store,
        accountId = { ACCOUNT },
        loadConversation = { id -> conversation(messages).takeIf { it.id == id } },
        memoryItems = { emptyList() },
        chatContext = { conversation, _ -> ChatContextRequest(ContextConversation(conversation.id, conversation.useMemory)) },
        requestOptions = { ChatRequestOptions() },
        compactNow = { _, _, _ -> ContextCompactionResult(outcome(), null, emptyList()) },
        thirdHint = hint,
        host = host,
    )

    private fun conversation(messages: List<ChatMessage>) = Conversation(
        id = CONVERSATION_ID,
        title = "Actions",
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        modelID = MODEL.id,
        useMemory = true,
        messages = messages,
    )

    /** A row whose digest matches [messages] up to [coversTo], so latestValid accepts it. */
    private fun validRecord(messages: List<ChatMessage>, coversTo: String): ContextCheckpointRecord {
        val index = messages.indexOfFirst { it.id == coversTo }
        val covered = messages.take(index + 1).map { CheckpointCoveredMessage(it.id, it.text) }
        return record(ContextCheckpointKind.SUMMARY, coversTo = coversTo, covered = index + 1, summary = "s")
            .copy(coversDigest = ContextCheckpoint.coversDigest(covered), createdAt = CREATED_AT + index)
    }

    // ── fixtures ──

    private fun history(n: Int) = (0 until n).map { i ->
        message("m$i", if (i % 2 == 0) ChatRole.User else ChatRole.Assistant, "message $i " + "z".repeat(100 * (i + 1)))
    }

    private fun longHistory(bytes: Int): List<ChatMessage> = (0 until 5).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(bytes - 8)),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(bytes - 13)),
        )
    } + message("u-next", ChatRole.User, "Next question")

    private fun record(
        kind: ContextCheckpointKind,
        coversTo: String,
        covered: Int,
        text: String = "<oriveo-context-checkpoint/>",
        summary: String? = null,
        userMessageIds: List<String> = listOf("m0"),
        cost: Double? = null,
    ) = ContextCheckpointRecord(
        conversationId = CONVERSATION_ID,
        checkpointId = "cp-$coversTo",
        kind = kind,
        coversFrom = "m0",
        coversTo = coversTo,
        coversDigest = "digest",
        messagesCovered = covered,
        userMessageIds = userMessageIds,
        text = text,
        summary = summary,
        language = null,
        model = "gpt-test",
        packerVersion = ContextCheckpoint.PACKER_VERSION,
        createdAt = CREATED_AT,
        cost = cost,
    )

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        providerName = PROVIDER.displayName,
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    private companion object {
        const val RHO = 0.5
        const val CREATED_AT = 1_760_000_000_000L
        const val CONVERSATION_ID = "conversation-1"
        const val ACCOUNT = "acct-1"
        const val LABEL = "Earlier conversation summary\n"
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val PROVIDER = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val VALID_SUMMARY = ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
    }
}
