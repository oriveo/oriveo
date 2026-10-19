package ai.oriveo.community.core.data.repository

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.CheckpointFallbackMessage
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextCompactionMode
import ai.oriveo.community.core.context.ContextCompactor
import ai.oriveo.community.core.context.SummaryRequest
import ai.oriveo.community.core.context.SummaryRequestShape
import ai.oriveo.community.core.context.trimWhiteSpace
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The compaction coordinator: choosing the mode, calling the summary, the fallback, persisting, uploading and the circuit breaker.
 * Expectations are all computed by the production pure functions of core/context (checkpointId / coversDigest / fallback), and rows are read back from a real Room database.
 */
@RunWith(RobolectricTestRunner::class)
class ContextPipelineCompactionCoordinatorTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var store: ContextCompactionStore

    private var aiPref = false
    private var remoteOn = true
    private var outputs: MutableList<String?> = mutableListOf()
    private val requests = mutableListOf<SummaryRequest>()
    private val uploads = mutableListOf<Pair<ContextCheckpointRecord, List<String>>>()

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        db.openHelper.writableDatabase.execSQL(
            "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                "accountId) " +
                "VALUES ('$CONV', 'c', 0, 'p1', 'OpenAI', 'm1', 1, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
        )
        store = ContextCompactionStore(db.contextCheckpointDao())
    }

    @After
    fun tearDown() {
        db.close()
    }

    private fun coordinator() = ContextCompactionCoordinator(
        store = store,
        accountId = { ACCOUNT },
        aiSummaryEnabled = { aiPref },
        remoteCompactionEnabled = { remoteOn },
        summarize = { req ->
            requests += req
            if (outputs.isEmpty()) null else outputs.removeAt(0)
        },
        upload = { _, row, ids -> uploads += row to ids },
        now = { NOW },
    )

    private fun ctx(u: Int = 100_000) = ContextCompactionContext(
        messages = HISTORY,
        B = B,
        U = u,
        rhoHi = RHO,
        prefixTokens = 100,
        fixedTokens = 0,
        model = MODEL,
    )

    @Test
    fun `coordinator_fallback_mode_saves_fallback_row`() = runBlocking {
        aiPref = false
        val result = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        assertTrue(requests.isEmpty())
        assertEquals(CompactOutcome.FALLBACK, result.outcome)
        val expected = ContextCheckpoint.fallback(fallbackMessages(), B, RHO, 0, null)
        val row = store.list(ACCOUNT, CONV).single()
        assertEquals(row, result.row)
        assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
        assertEquals(expected.checkpointText, row.text)
        assertEquals("m0", row.coversFrom)
        assertEquals("m7", row.coversTo)
        assertEquals(8, row.messagesCovered)
        assertEquals(expected.keptUserIds, row.userMessageIds)
        assertEquals(ContextCheckpoint.checkpointId(CONV, "m7"), row.checkpointId)
        assertEquals(digestThrough(7), row.coversDigest)
        assertNull(row.summary)
        assertNull(row.language)
        assertNull(row.cost)
        assertEquals(MODEL, row.model)
        assertEquals(NOW, row.createdAt)
    }

    @Test
    fun `coordinator_ai_mode_saves_summary_row`() = runBlocking {
        aiPref = true
        // Blank lines around the summary: the stored summary follows the same rule as ContextCheckpoint.serialize (trimWhiteSpace).
        val padded = "\n\n$VALID\n\n"
        outputs = mutableListOf(padded)
        val coordinator = coordinator()
        val result = coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        assertEquals(CompactOutcome.SUMMARY, result.outcome)
        val req = requests.single()
        assertEquals(SummaryRequestShape.APPENDED, req.shape)
        assertTrue(req.messages.last().text.endsWith(ContextCompactor.summaryPrompt(null, SUMMARY_MAX)))
        val row = store.list(ACCOUNT, CONV).single()
        assertEquals(row, result.row)
        assertEquals(ContextCheckpointKind.SUMMARY, row.kind)
        assertEquals(VALID, row.summary)
        assertEquals(padded.trimWhiteSpace(), row.summary)
        assertEquals("m7", row.coversTo)
        assertEquals(ContextCheckpoint.checkpointId(CONV, "m7"), row.checkpointId)
        assertEquals(digestThrough(7), row.coversDigest)
        assertTrue(row.text.contains("<summary>"))
        assertNull(row.language)
        assertNull(row.cost)
        assertEquals(0, coordinator.breaker(CONV).failures)
    }

    @Test
    fun `coordinator_invalid_twice_falls_back_and_counts_failure`() = runBlocking {
        aiPref = true
        outputs = mutableListOf("not a checkpoint", null)
        val coordinator = coordinator()
        val result = coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        assertEquals(2, requests.size)
        assertEquals(CompactOutcome.FALLBACK, result.outcome)
        assertEquals(2, result.failures.size)
        assertEquals(listOf(ContextCompactor.REASON_CALL_ERROR), result.failures[1])
        assertEquals(ContextCheckpointKind.FALLBACK, store.list(ACCOUNT, CONV).single().kind)
        assertEquals(1, coordinator.breaker(CONV).failures)
    }

    @Test
    fun `coordinator_two_failed_compactions_trip_breaker`() = runBlocking {
        aiPref = true
        outputs = mutableListOf("bad", "bad", "bad", "bad")
        val coordinator = coordinator()
        coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        clearRows()
        coordinator.compact(CONV, ContextCompactionTrigger.OVERFLOW, ctx())
        clearRows()
        assertEquals(4, requests.size)
        assertEquals(ContextCompactionMode.FALLBACK_ONLY, coordinator.breaker(CONV).mode)
        assertEquals(ContextCompactionMode.LLM, coordinator.breaker("other").mode)

        val third = coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        assertEquals(4, requests.size)
        assertEquals(CompactOutcome.FALLBACK, third.outcome)

        coordinator.recordTurn(CONV)
        assertEquals(9, coordinator.breaker(CONV).turnsLeft)
        coordinator.retry(CONV)
        assertEquals(ContextCompactionMode.LLM, coordinator.breaker(CONV).mode)
    }

    @Test
    fun `coordinator_too_large_falls_back_without_failure`() = runBlocking {
        aiPref = true
        val coordinator = coordinator()
        val result = coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx(u = 500))

        assertTrue(requests.isEmpty())
        assertEquals(CompactOutcome.FALLBACK, result.outcome)
        assertTrue(result.failures.isEmpty())
        assertEquals(ContextCheckpointKind.FALLBACK, store.list(ACCOUNT, CONV).single().kind)
        assertEquals(0, coordinator.breaker(CONV).failures)
    }

    @Test
    fun `coordinator_remote_flag_off_forces_fallback`() = runBlocking {
        aiPref = true
        remoteOn = false
        outputs = mutableListOf(VALID)
        val coordinator = coordinator()
        val preSend = coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        // The previous row already covers up to m7; unless it is cleared the span is empty, which is a noop
        clearRows()
        val manual = coordinator.compact(CONV, ContextCompactionTrigger.MANUAL, ctx())

        assertTrue(requests.isEmpty())
        assertEquals(CompactOutcome.FALLBACK, preSend.outcome)
        assertEquals(CompactOutcome.FALLBACK, manual.outcome)
        assertEquals(ContextCheckpointKind.FALLBACK, store.list(ACCOUNT, CONV).single().kind)
    }

    @Test
    fun `coordinator_manual_ignores_pref_and_breaker`() = runBlocking {
        aiPref = true
        outputs = mutableListOf("bad", "bad", "bad", "bad", VALID)
        val coordinator = coordinator()
        coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        clearRows()
        coordinator.compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        clearRows()
        assertEquals(ContextCompactionMode.FALLBACK_ONLY, coordinator.breaker(CONV).mode)
        aiPref = false

        val manual = coordinator.compact(CONV, ContextCompactionTrigger.MANUAL, ctx())

        assertEquals(5, requests.size)
        assertEquals(CompactOutcome.SUMMARY, manual.outcome)
        assertEquals(ContextCheckpointKind.SUMMARY, manual.row?.kind)
        // A manual run still feeds the breaker: a success resets the failure count but does not lift an already tripped turn
        assertEquals(0, coordinator.breaker(CONV).failures)
        assertEquals(ContextCompactionMode.FALLBACK_ONLY, coordinator.breaker(CONV).mode)
    }

    @Test
    fun `coordinator_incremental_passes_previous_summary`() = runBlocking {
        val previous = ContextCheckpointRecord(
            conversationId = CONV,
            checkpointId = ContextCheckpoint.checkpointId(CONV, "m3"),
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = "m0",
            coversTo = "m3",
            coversDigest = digestThrough(3),
            messagesCovered = 4,
            userMessageIds = listOf("m0", "m2"),
            text = "<oriveo-context-checkpoint previous/>",
            summary = "old summary",
            language = null,
            model = MODEL,
            packerVersion = ContextCheckpoint.PACKER_VERSION,
            createdAt = 1,
            cost = null,
        )
        store.save(ACCOUNT, previous)

        aiPref = true
        outputs = mutableListOf(VALID)
        val result = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        // Only the incremental span from m4 is sent, with the previous checkpoint's text prepended before the first message
        val req = requests.single()
        assertTrue(req.messages.first().text.startsWith(previous.text + "\n\n"))
        // Four messages m4..m7 ending on the assistant, and the prompt goes in a separate user message
        assertEquals(5, req.messages.size)
        assertEquals("m7", result.row?.coversTo)

        // The fallback path carries the old summary: the history grows by 4 more messages, so only after m7 is there a non-empty span (an empty span is always a noop)
        aiPref = false
        val longer = ctx().copy(messages = HISTORY + EXTRA)
        val fallback = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, longer)
        assertEquals(CompactOutcome.FALLBACK, fallback.outcome)
        assertEquals(VALID, fallback.row?.summary)
        assertTrue(fallback.row!!.text.contains("<summary>"))
    }

    @Test
    fun `coordinator_saved_row_uploads_when_bound`() = runBlocking {
        aiPref = true
        outputs = mutableListOf(VALID)
        val result = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        val (row, ids) = uploads.single()
        assertNotNull(result.row)
        assertEquals(result.row, row)
        assertEquals(store.list(ACCOUNT, CONV).map { it.checkpointId }, ids)

        // A noop neither stores nor uploads
        val short = ContextCompactionContext(HISTORY.take(1), B, 100_000, RHO, 100, 0, MODEL)
        val noop = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, short)
        assertEquals(CompactOutcome.NOOP, noop.outcome)
        assertNull(noop.row)
        assertEquals(1, uploads.size)
    }

    @Test
    fun `coordinator_upload_passes_checkpoint_ids`() = runBlocking {
        // The upload carries all local checkpoint ids of this conversation, not message ids.
        store.save(ACCOUNT, previousRow())
        aiPref = true
        outputs = mutableListOf(VALID)
        val result = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        val (row, ids) = uploads.single()
        assertEquals(result.row, row)
        assertEquals(
            setOf(ContextCheckpoint.checkpointId(CONV, "m3"), ContextCheckpoint.checkpointId(CONV, "m7")),
            ids.toSet(),
        )
        assertEquals(store.list(ACCOUNT, CONV).map { it.checkpointId }, ids)
    }

    @Test
    fun `coordinator_save_failure_returns_no_row`() = runBlocking {
        // The conversation is not under this account: the foreign key makes save throw and the coordinator swallows it; both the summary and the fallback paths return noop with no row and no upload.
        fun coordinator(ai: Boolean) = ContextCompactionCoordinator(
            store = store,
            accountId = { "acct-missing" },
            aiSummaryEnabled = { ai },
            remoteCompactionEnabled = { remoteOn },
            summarize = { req ->
                requests += req
                if (outputs.isEmpty()) null else outputs.removeAt(0)
            },
            upload = { _, row, ids -> uploads += row to ids },
            now = { NOW },
        )
        val fallback = coordinator(ai = false).compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        assertEquals(CompactOutcome.NOOP, fallback.outcome)
        assertNull(fallback.row)

        // Summary path: the first output is non-compliant and the second compliant -> failures are carried back as-is
        outputs = mutableListOf("not a summary", VALID)
        val summary = coordinator(ai = true).compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())
        assertEquals(2, requests.size)
        assertEquals(CompactOutcome.NOOP, summary.outcome)
        assertNull(summary.row)
        assertEquals(1, summary.failures.size)

        assertTrue(uploads.isEmpty())
        assertTrue(store.list("acct-missing", CONV).isEmpty())
    }

    @Test
    fun `coordinator_empty_span_is_noop`() = runBlocking {
        // An existing row covers up to m7 and only m8..m9 remain in the tail: the span is empty, and the fallback mode does not store a fallback row either.
        val previous = previousRow().copy(
            checkpointId = ContextCheckpoint.checkpointId(CONV, "m7"),
            coversTo = "m7",
            coversDigest = digestThrough(7),
            messagesCovered = 8,
        )
        store.save(ACCOUNT, previous)
        aiPref = false
        val result = coordinator().compact(CONV, ContextCompactionTrigger.PRE_SEND, ctx())

        assertEquals(CompactOutcome.NOOP, result.outcome)
        assertNull(result.row)
        assertEquals(listOf(previous), store.list(ACCOUNT, CONV))
        assertTrue(uploads.isEmpty())
    }

    /** User messages among the compaction candidates are marked isDirective by the detector (production path compactionHistory). */
    @Test
    fun `compaction_inputs_mark_directives`() {
        fun chat(id: String, role: ChatRole, text: String) = ChatMessage(
            id = id,
            role = role,
            text = text,
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelName = "GPT",
            state = ChatMessageState.Delivered,
        )
        val history = ChatContextProjector.compactionHistory(
            listOf(
                chat("u1", ChatRole.User, "From now on, reply in English."),
                chat("a1", ChatRole.Assistant, "Sure."),
                chat("u2", ChatRole.User, "Tell me about the weather today."),
                chat("u3", ChatRole.User, "current"),
            ),
            RHO,
        )
        assertEquals(listOf("u1", "a1", "u2"), history.map { it.id })
        assertEquals(listOf(true, false, false), history.map { it.isDirective })
    }

    /**
     * The deterministic fallback keeps a directive user message through three wirings: compactionHistory marks isDirective, the coordinator fallback row,
     * and the projection's in-memory fallback (checkpointed). Control group: with the same history and no directive mark, the earliest directive user message is squeezed out.
     */
    @Test
    fun `fallback_keeps_directive_user`() = runBlocking {
        fun chat(id: String, role: ChatRole, text: String) = ChatMessage(
            id = id,
            role = role,
            text = text,
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelName = "GPT",
            state = ChatMessageState.Delivered,
        )
        val directive = "From now on, reply in English."
        // The directive is as long as an ordinary user message: in the control group it does not fit the remaining budget just by being short.
        val directiveText = directive + " Keep every answer short and plain.".repeat(20)
        // The first user message is always kept by the fallback, so the directive goes in the second user message to show the effect of isDirective.
        val raw = listOf(
            chat("first", ChatRole.User, "Hi there."),
            chat("first-a", ChatRole.Assistant, "Hello."),
            chat("d0", ChatRole.User, directiveText),
        ) +
            (1..40).flatMap { i ->
                listOf(
                    chat("u$i", ChatRole.User, "Question $i " + "x".repeat(700)),
                    chat("a$i", ChatRole.Assistant, "Answer $i " + "y".repeat(6_000)),
                )
            } + chat("now", ChatRole.User, "current")

        // 1. compactionHistory
        val history = ChatContextProjector.compactionHistory(raw, RHO)
        assertEquals(listOf("d0"), history.filter { it.isDirective }.map { it.id })

        // Control: without the directive mark the fallback does not keep d0, which shows that the two places below keep it because of isDirective.
        val unmarked = ContextCheckpoint.fallback(
            history.map { CheckpointFallbackMessage(it.id, it.role, it.estTokens, it.text, false) },
            B, RHO, 0,
        )
        assertTrue("control drops d0: ${unmarked.keptUserIds}", "d0" !in unmarked.keptUserIds)

        // 2. The coordinator fallback row
        aiPref = false
        val result = coordinator().compact(
            CONV,
            ContextCompactionTrigger.PRE_SEND,
            ContextCompactionContext(history, B, 100_000, RHO, 100, 0, MODEL),
        )
        val row = assertNotNullRow(result.row)
        assertTrue("coordinator keeps d0: ${row.userMessageIds}", "d0" in row.userMessageIds)
        assertTrue(row.text, directive in row.text)

        // 3. The projection's in-memory fallback (the overflow resend path)
        val projection = ChatContextProjector.project(
            request = ai.oriveo.community.core.context.ChatContextRequest(
                ai.oriveo.community.core.context.ContextConversation(id = CONV, useMemory = false),
            ),
            rawMessages = raw,
            window = ai.oriveo.community.core.context.ContextWindowInput(
                W = null,
                windowKind = ai.oriveo.community.core.context.ContextWindowKind.TOTAL,
                maxOutput = ai.oriveo.community.core.context.ContextMaxOutput(model = 8_192),
            ),
            rhoHi = RHO,
            overflowFallbackB = B,
        )
        val checkpointText = projection?.checkpointText
        assertNotNull("overflow fallback cuts a checkpoint", checkpointText)
        assertTrue(checkpointText!!, directive in checkpointText)
    }

    private fun assertNotNullRow(row: ContextCheckpointRecord?): ContextCheckpointRecord {
        assertNotNull("fallback row saved", row)
        return row!!
    }

    private fun previousRow() = ContextCheckpointRecord(
        conversationId = CONV,
        checkpointId = ContextCheckpoint.checkpointId(CONV, "m3"),
        kind = ContextCheckpointKind.SUMMARY,
        coversFrom = "m0",
        coversTo = "m3",
        coversDigest = digestThrough(3),
        messagesCovered = 4,
        userMessageIds = listOf("m0", "m2"),
        text = "<oriveo-context-checkpoint previous/>",
        summary = "old summary",
        language = null,
        model = MODEL,
        packerVersion = ContextCheckpoint.PACKER_VERSION,
        createdAt = 1,
        cost = null,
    )

    /** When an existing row covers up to m7 the span is empty (a noop), so it is cleared before back-to-back compactions. */
    private suspend fun clearRows() {
        store.invalidate(ACCOUNT, CONV, HISTORY.map { it.id }, setOf("m0"))
    }

    private fun fallbackMessages() = HISTORY.map {
        CheckpointFallbackMessage(it.id, it.role, it.estTokens, it.text, it.isDirective)
    }

    private fun digestThrough(index: Int) =
        ContextCheckpoint.coversDigest(HISTORY.take(index + 1).map { CheckpointCoveredMessage(it.id, it.text) })

    private companion object {
        const val ACCOUNT = "acct-1"
        const val CONV = "AAAAAAAA-0000-0000-0000-000000000001"
        const val MODEL = "gpt-test"
        const val NOW = 1_700_000_000_000L
        // B=20000 -> tail=5000, summaryMax=1000; at 1500 per message the tail is m8..m9 and the span is m0..m7
        const val B = 20_000
        const val SUMMARY_MAX = 1_000
        const val RHO = 0.5
        val HISTORY = (0 until 10).map { i ->
            ContextCompactionMessage(
                id = "m$i",
                role = if (i % 2 == 0) ChatRole.User else ChatRole.Assistant,
                text = "text $i",
                estTokens = 1_500,
            )
        }
        val EXTRA = (10 until 14).map { i ->
            ContextCompactionMessage(
                id = "m$i",
                role = if (i % 2 == 0) ChatRole.User else ChatRole.Assistant,
                text = "text $i",
                estTokens = 1_500,
            )
        }
        val VALID = ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
    }
}
