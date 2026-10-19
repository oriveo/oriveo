package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.R
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.ContextManifestSegment
import ai.oriveo.community.core.context.ContextSegmentKind
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.repository.ChatContextProjector
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import androidx.compose.ui.graphics.compositeOver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.w3c.dom.Element

/** Usage summary (usage.v1), composer ring visibility and the spoken label. */
@RunWith(RobolectricTestRunner::class)
class ContextVisibilityTest {

    private val fixture = ContextContractFixture.load("usage.v1.json")

    @Test
    fun usage_summary_matches_fixture() {
        val cases = ContextContractFixture.cases(fixture, "summaryCases")
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val input = case.objOrNull("input")!!
            // input.currentB is passed only when the key exists (a null value = window unknown); an absent key = not passed, keeping the ledger B.
            val summary = ContextUsagePresentation.summary(
                manifests = manifests(input),
                checkpoint = checkpoint(input),
                currentB = if (input.containsKey("currentB")) ContextCurrentB(input.intOrNull("currentB")) else null,
            )
            assertSummary(case.id(), case.objOrNull("expected")!!, summary)
        }
    }

    @Test
    fun usage_summary_from_production_ledger() = runTest {
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            val ledger = db.contextLedgerDao()
            val store = ContextCompactionStore(db.contextCheckpointDao())
            val messages = (0 until 4).map { i ->
                message("m$i", if (i % 2 == 0) ChatRole.User else ChatRole.Assistant, "message $i " + "z".repeat(200))
            }
            val source = ContextUsageSource(
                ledger = ledger,
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { id -> conversation(messages).takeIf { it.id == id } },
                rhoHi = { RHO },
            )

            // No ledger -> none.
            assertEquals(ContextUsageDisplay.NONE, source.summary(CONVERSATION_ID).display)

            val case = ContextContractFixture.cases(fixture, "summaryCases").first { it.id() == "observed_38" }
            manifests(case.objOrNull("input")!!).forEach { ledger.appendManifest(ContextManifestEntity.of(it)) }
            assertSummary("ledger observed_38", case.objOrNull("expected")!!, source.summary(CONVERSATION_ID))

            // The checkpoint is older than the latest manifest: the summary segment = the estimated checkpoint text.
            val text = "<oriveo-context-checkpoint>" + "s".repeat(900) + "</oriveo-context-checkpoint>"
            store.save(ACCOUNT, record(messages, "c1", text, createdAt = 1_500))
            val withCheckpoint = source.summary(CONVERSATION_ID)
            val expectedSummaryTokens = ContextBudget.estimateMessage(text, RHO)
            assertEquals(expectedSummaryTokens, withCheckpoint.segments!!.summary)
            assertEquals(43_776 - 600 - 2_000 - 11_000 - expectedSummaryTokens, withCheckpoint.segments!!.conversation)
            assertEquals(ContextUsageCheckpoint(1, 1_500, expectedSummaryTokens), withCheckpoint.checkpoint)

            // A later checkpoint is newer than the latest manifest -> compacted_since.
            store.save(ACCOUNT, record(messages, "c2", text, createdAt = 3_000, covered = 3))
            val compacted = source.summary(CONVERSATION_ID)
            assertEquals(ContextUsageDisplay.UNAVAILABLE, compacted.display)
            assertEquals(ContextUsageReason.COMPACTED_SINCE, compacted.reason)
            assertEquals(2, compacted.checkpoint!!.count)
        } finally {
            db.close()
        }
    }

    @Test
    fun usage_follows_conversation_switch() = runTest {
        // the composer ring source (chatContextUsage) follows the shown conversation; after a switch it
        // shows the new conversation's usage, never the previous one's.
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            val case = ContextContractFixture.cases(fixture, "summaryCases").first { it.id() == "observed_38" }
            manifests(case.objOrNull("input")!!).forEach { db.contextLedgerDao().appendManifest(ContextManifestEntity.of(it)) }
            val first = conversation(defaultMessages)
            val second = first.copy(id = OTHER_CONVERSATION_ID)
            val deps = ChatCompactionDeps(
                // No checkpoint in this test, so rhoHi is never used for an estimate.
                chatRepository = io.mockk.mockk(relaxed = true),
                store = ContextCompactionStore(db.contextCheckpointDao()),
                thirdHint = ThirdCompactionHint(),
                conversationRepository = io.mockk.mockk<ai.oriveo.community.core.data.repository.ConversationRepository>(relaxed = true).also {
                    io.mockk.coEvery { it.getWithMessages(CONVERSATION_ID) } returns first
                    io.mockk.coEvery { it.getWithMessages(OTHER_CONVERSATION_ID) } returns second
                },
                accountId = { ACCOUNT },
                ledger = db.contextLedgerDao(),
            )
            val shown = MutableStateFlow(ConversationRenderState(first))
            val usage = chatContextUsage(deps, shown, backgroundScope)

            val observed = usage.first { it != null }!!
            assertSummary("switch observed_38", case.objOrNull("expected")!!, observed)

            shown.value = ConversationRenderState(second)
            // The second conversation has no ledger: its own summary (none) replaces the first one's.
            val switched = usage.first { it != null && it.display == ContextUsageDisplay.NONE }!!
            assertNull(switched.segments)

            shown.value = ConversationRenderState(first)
            assertSummary("switch back observed_38", case.objOrNull("expected")!!, usage.first { it != null && it.display != ContextUsageDisplay.NONE }!!)
        } finally {
            db.close()
        }
    }

    @Test
    fun usage_flow_drops_previous_conversation() = runTest {
        withSource { source, _, _ ->
            val result = source.flow(flowOf(CONVERSATION_ID), flowOf(Unit)).first()
            assertNotNull(result)
            // The result carries a conversation id: after switching to another conversation and before the new result is computed, the old conversation usage must not pose as the current one.
            assertEquals(CONVERSATION_ID, result!!.conversationId)
            assertEquals(result.summary, result.forConversation(CONVERSATION_ID))
            assertNull(result.forConversation("other"))
            assertNull(result.forConversation(null))
            assertNull(source.flow(flowOf(null), flowOf(Unit)).first())
        }
    }

    @Test
    fun usage_skips_history_without_checkpoints() = runTest {
        withSource { source, store, loads ->
            // No checkpoint row: the full conversation messages are not read.
            assertEquals(ContextUsageDisplay.NONE, source.summary(CONVERSATION_ID).display)
            assertEquals(0, loads())
            store.save(ACCOUNT, record(defaultMessages, "c1", "<oriveo-context-checkpoint>s</oriveo-context-checkpoint>", 1_500))
            assertEquals(1, source.summary(CONVERSATION_ID).checkpoint!!.count)
            assertEquals(1, loads())
        }
    }

    @Test
    fun cleared_compaction_shows_unavailable_until_next_send() = runTest {
        withLedgerSource { source, store, ledger ->
            val text = "<oriveo-context-checkpoint>" + "s".repeat(900) + "</oriveo-context-checkpoint>"
            store.save(ACCOUNT, record(defaultMessages, "c1", text, createdAt = 1_000))
            // The latest manifest was sent with c1 -> the percentage is shown as usual.
            ledger.appendManifest(ContextManifestEntity.of(usageManifest("r1", createdAt = 2_000, checkpointId = "c1")))
            assertEquals(ContextUsageDisplay.PERCENT, source.summary(CONVERSATION_ID).display)

            // Condensing is cleared: the old measurement is void -> unavailable, the hint says usage is shown after a message is sent, and the ring is hidden.
            store.deleteAll(ACCOUNT, CONVERSATION_ID)
            val cleared = source.summary(CONVERSATION_ID)
            assertEquals(ContextUsageDisplay.UNAVAILABLE, cleared.display)
            assertEquals(ContextUsageReason.CLEARED_SINCE, cleared.reason)
            assertNull(cleared.percent)
            assertNull(cleared.ring)
            assertNull(cleared.segments)
            assertNull(ContextUsagePresentation.ringAccessibility(cleared, "en"))
            assertEquals(R.string.context_usage_hint_empty, ContextUsagePanel.hintRes(cleared))
            assertEquals(ContextUsageValueText.Unavailable, ContextUsagePanel.settingsValue(cleared))

            // The next send stores a new manifest (without a checkpoint) -> the percentage comes back.
            ledger.appendManifest(ContextManifestEntity.of(usageManifest("r2", createdAt = 3_000, checkpointId = null)))
            val next = source.summary(CONVERSATION_ID)
            assertEquals(ContextUsageDisplay.PERCENT, next.display)
            assertEquals(40, next.percent)
        }
    }

    @Test
    fun cap_change_recomputes_denominator() = runTest {
        val currentB = MutableStateFlow<ContextCurrentB?>(null)
        withLedgerSource(currentB = { currentB.value }) { source, _, ledger ->
            ledger.appendManifest(ContextManifestEntity.of(usageManifest("r1", createdAt = 2_000, checkpointId = null)))
            val capChanged = MutableStateFlow<Any?>("auto")
            val results = source.flow(flowOf(CONVERSATION_ID), flowOf(Unit), capChanged)
            val before = results.first()!!.summary
            assertEquals(100_000, before.B)
            assertEquals(40, before.percent)

            // Changing the cap: the measured usage is kept and the denominator is recomputed from the new cap.
            currentB.value = ContextCurrentB(50_000)
            capChanged.value = "custom-50k"
            val after = results.first()!!.summary
            assertEquals(40_000, after.used)
            assertEquals(50_000, after.B)
            assertEquals(80, after.percent)

            // If the connection cannot be resolved (currentB not passed), the B of the manifest is used as before.
            currentB.value = null
            capChanged.value = "unresolved"
            assertEquals(100_000, results.first()!!.summary.B)

            // Window unknown and no custom cap (currentB key present with a null value) -> window_unknown, without falling back to the ledger B.
            currentB.value = ContextCurrentB(null)
            capChanged.value = "unknown"
            val unknown = results.first()!!.summary
            assertEquals(ContextUsageDisplay.UNAVAILABLE, unknown.display)
            assertEquals(ContextUsageReason.WINDOW_UNKNOWN, unknown.reason)
            assertNull(unknown.B)
        }
    }

    @Test
    fun production_window_b_follows_cap() {
        // What DI hands to ChatCompactionDeps.contextWindowB is ContextCapViewModel.currentB: the conversation cap first, otherwise the global default.
        var payload: String? = null
        val settings = ai.oriveo.community.core.model.GenerationParameterSettingsStore(
            readPayload = { payload },
            writePayload = { payload = it },
            putTombstone = { _, _ -> },
            clearTombstone = { },
        )
        val model = AIModel(id = "claude-window-200k", name = "Claude 200k", contextLength = 200_000, maxOutputTokens = 8192)
        val provider = PROVIDER.copy(models = listOf(model))
        val base = conversation(defaultMessages).copy(modelID = model.id)
        val custom = ai.oriveo.community.core.context.ContextBudgetCap.Custom(50_000)
        val auto = ai.oriveo.community.core.context.ContextBudgetCap.Auto

        assertEquals(50_000, ContextCapViewModel.currentB(settings, base.copy(contextCap = custom), provider, auto))
        assertEquals(50_000, ContextCapViewModel.currentB(settings, base, provider, custom))
        val autoB = ContextCapViewModel.currentB(settings, base, provider, auto)
        assertNotNull(autoB)
        assertTrue(autoB!! > 50_000)
        // Window unknown: the automatic cap is neither guessed nor backfilled (null); with a custom cap B is the custom value.
        val unknown = provider.copy(models = listOf(model.copy(contextLength = null)))
        assertNull(ContextCapViewModel.currentB(settings, base, unknown, auto))
        assertEquals(50_000, ContextCapViewModel.currentB(settings, base.copy(contextCap = custom), unknown, auto))
        assertEquals(50_000, ContextCapViewModel.currentB(settings, base, unknown, custom))

        // Model cannot be resolved: DI does not pass currentB (keeping the ledger B), and only passes null when the window is unknown.
        assertTrue(ContextCapViewModel.resolvesModel(settings, base, unknown))
        val unresolved = base.copy(modelID = "no-such-model-for-context-test")
        assertFalse(ContextCapViewModel.resolvesModel(settings, unresolved, provider))
        val ledger = listOf(usageManifest("r1", createdAt = 2_000, checkpointId = null))
        assertEquals(100_000, ContextUsagePresentation.summary(ledger, null, currentB = null).B)
    }

    private fun usageManifest(requestId: String, createdAt: Long, checkpointId: String?) = ContextManifest(
        requestId = requestId,
        conversationId = CONVERSATION_ID,
        purpose = RequestPurpose.CHAT,
        transport = "anthropic",
        model = "m1",
        W = 128_000,
        O = 8192,
        B = 100_000,
        basis = ContextBasis.OBSERVED,
        estimatedInput = 39_000,
        observedInput = 40_000,
        segments = emptyList(),
        checkpointId = checkpointId,
        unansweredMerged = 0,
        reminder = false,
        createdAt = createdAt,
    )

    private suspend fun withLedgerSource(
        currentB: suspend (String) -> ContextCurrentB? = { null },
        block: suspend (ContextUsageSource, ContextCompactionStore, ai.oriveo.community.core.data.dao.ContextLedgerDao) -> Unit,
    ) {
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            val store = ContextCompactionStore(db.contextCheckpointDao())
            val source = ContextUsageSource(
                ledger = db.contextLedgerDao(),
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { id -> conversation(defaultMessages).takeIf { it.id == id } },
                rhoHi = { RHO },
                currentB = currentB,
            )
            block(source, store, db.contextLedgerDao())
        } finally {
            db.close()
        }
    }

    private val defaultMessages = (0 until 4).map { i ->
        message("m$i", if (i % 2 == 0) ChatRole.User else ChatRole.Assistant, "message $i " + "z".repeat(200))
    }

    private suspend fun withSource(block: suspend (ContextUsageSource, ContextCompactionStore, () -> Int) -> Unit) {
        val context: Context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java).allowMainThreadQueries().build()
        try {
            db.openHelper.writableDatabase.execSQL(
                "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId) " +
                    "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
            )
            val store = ContextCompactionStore(db.contextCheckpointDao())
            var loads = 0
            val source = ContextUsageSource(
                ledger = db.contextLedgerDao(),
                store = store,
                accountId = { ACCOUNT },
                loadConversation = { id -> loads++; conversation(defaultMessages).takeIf { it.id == id } },
                rhoHi = { RHO },
            )
            block(source, store) { loads }
        } finally {
            db.close()
        }
    }

    @Test
    fun usage_ring_hidden_unless_percent() {
        for (case in ContextContractFixture.cases(fixture, "summaryCases")) {
            val input = case.objOrNull("input")!!
            val summary = ContextUsagePresentation.summary(manifests(input), checkpoint(input))
            val a11y = ContextUsagePresentation.ringAccessibility(summary, "en")
            if (summary.display == ContextUsageDisplay.PERCENT) {
                assertNotNull(case.id(), summary.ring)
                assertNotNull(case.id(), a11y)
            } else {
                assertNull(case.id(), summary.ring)
                assertNull(case.id(), a11y)
            }
        }
        val byId = ContextContractFixture.cases(fixture, "summaryCases").associateBy { it.id() }
        fun summaryOf(id: String) = byId.getValue(id).objOrNull("input")!!.let {
            ContextUsagePresentation.summary(manifests(it), checkpoint(it))
        }
        assertEquals(
            ContextUsageRingAccessibility(R.string.context_usage_ring_a11y, listOf(38, "115.2K")),
            ContextUsagePresentation.ringAccessibility(summaryOf("observed_38"), "en"),
        )
        assertEquals(
            ContextUsageRingAccessibility(R.string.context_usage_ring_over_a11y, emptyList()),
            ContextUsagePresentation.ringAccessibility(summaryOf("over_100_without_overflow_shows_bang"), "en"),
        )
    }

    @Test
    fun strings_present_in_16_locales() {
        val failures = mutableListOf<String>()
        for (locale in LOCALES) {
            val values = parseStrings(File("src/main/res/$locale/strings.xml"))
            val ring = values["context_usage_ring_a11y"]
            if (ring.isNullOrBlank() || !ring.contains("%1\$d") || !ring.contains("%2\$s")) {
                failures += "$locale context_usage_ring_a11y: $ring"
            }
            val over = values["context_usage_ring_over_a11y"]
            if (over.isNullOrBlank() || over.contains("%")) failures += "$locale context_usage_ring_over_a11y: $over"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun assertSummary(id: String, expected: JsonObject, actual: ContextUsageSummary) {
        val actualJson = summaryJson(actual)
        for ((key, value) in expected) {
            assertEquals("$id.$key", value, actualJson[key])
        }
    }

    private fun summaryJson(s: ContextUsageSummary): JsonObject = buildJsonObject {
        put("display", JsonPrimitive(s.display.wire))
        put("reason", s.reason?.wire.json())
        put("percent", s.percent.json())
        put("estimatedPercent", s.estimatedPercent.json())
        put("tone", s.tone?.wire.json())
        put(
            "ring",
            s.ring?.let { buildJsonObject { put("label", JsonPrimitive(it.label)); put("tone", JsonPrimitive(it.tone.wire)) } }
                ?: JsonNull,
        )
        put("basis", s.basis?.wire.json())
        put("used", s.used.json())
        put("B", s.B.json())
        put("W", s.W.json())
        put(
            "segments",
            s.segments?.let {
                buildJsonObject {
                    put("conversation", JsonPrimitive(it.conversation))
                    put("library", JsonPrimitive(it.library))
                    put("summary", JsonPrimitive(it.summary))
                    put("instructions", JsonPrimitive(it.instructions))
                    put("memory", JsonPrimitive(it.memory))
                    put("free", JsonPrimitive(it.free))
                }
            } ?: JsonNull,
        )
        put(
            "omitted",
            s.omitted?.let {
                buildJsonObject {
                    put("notes", JsonPrimitive(it.notes))
                    put("knowledge", JsonPrimitive(it.knowledge))
                    put("memory", JsonPrimitive(it.memory))
                }
            } ?: JsonNull,
        )
    }

    private fun String?.json(): JsonElement = this?.let(::JsonPrimitive) ?: JsonNull
    private fun Int?.json(): JsonElement = this?.let(::JsonPrimitive) ?: JsonNull

    private fun manifests(input: JsonObject): List<ContextManifest> =
        input["manifests"]!!.jsonArray.mapIndexed { index, el ->
            val m = el.jsonObject
            ContextManifest(
                requestId = "r$index",
                conversationId = CONVERSATION_ID,
                purpose = RequestPurpose.CHAT,
                transport = "anthropic",
                model = "m1",
                W = m.intOrNull("W"),
                O = 8192,
                B = m.intOrNull("B"),
                // usage.v1: manifest.basis does not take part in the decision, so a reversed value is filled in on purpose.
                basis = ContextBasis.UNKNOWN,
                estimatedInput = m.intOrNull("estimatedInput")!!,
                observedInput = m.intOrNull("observedInput"),
                segments = m["segments"]!!.jsonArray.map { s ->
                    val seg = s.jsonObject
                    ContextManifestSegment(
                        kind = ContextSegmentKind.entries.first { it.wire == seg.stringOrNull("kind") },
                        tokens = seg.intOrNull("tokens")!!,
                        omitted = seg.intOrNull("omitted"),
                    )
                },
                unansweredMerged = 0,
                reminder = false,
                stopReason = StopReason.fromStored(m.stringOrNull("stopReason")),
                checkpointId = m.stringOrNull("checkpointId"),
                createdAt = m.intOrNull("createdAt")!!.toLong(),
            )
        }

    private fun checkpoint(input: JsonObject): ContextUsageCheckpoint? = input.objOrNull("checkpoint")?.let {
        ContextUsageCheckpoint(
            count = it.intOrNull("count")!!,
            latestCreatedAt = it.intOrNull("latestCreatedAt")!!.toLong(),
            latestSummaryTokens = it.intOrNull("latestSummaryTokens")!!,
        )
    }

    private fun record(
        messages: List<ChatMessage>,
        id: String,
        text: String,
        createdAt: Long,
        covered: Int = 2,
    ): ContextCheckpointRecord {
        val history = ChatContextProjector.compactionHistory(messages, RHO).map { CheckpointCoveredMessage(it.id, it.text) }
        return ContextCheckpointRecord(
            conversationId = CONVERSATION_ID,
            checkpointId = id,
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = "m0",
            coversTo = "m${covered - 1}",
            coversDigest = ContextCheckpoint.coversDigest(history.subList(0, covered)),
            messagesCovered = covered,
            userMessageIds = listOf("m0"),
            text = text,
            summary = "s",
            language = null,
            model = "m1",
            packerVersion = "1",
            createdAt = createdAt,
            cost = null,
        )
    }

    private fun conversation(messages: List<ChatMessage>) = Conversation(
        id = CONVERSATION_ID,
        title = "Usage",
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        modelID = MODEL.id,
        useMemory = false,
        messages = messages,
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

    private fun parseStrings(file: File): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length).associate { index ->
            val element = nodes.item(index) as Element
            element.getAttribute("name") to element.textContent
        }
    }

    private companion object {
        const val RHO = 0.5
        const val CONVERSATION_ID = "conversation-usage"
        const val OTHER_CONVERSATION_ID = "conversation-usage-other"
        const val ACCOUNT = "acct-1"
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val PROVIDER = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val LOCALES = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in", "values-ja",
            "values-ko", "values-pt-rBR", "values-ru", "values-th", "values-tr", "values-vi", "values-zh-rCN",
            "values-zh-rTW",
        )
    }
    // Light-theme resample: the free segment (also the ring track) used to be hairline = white@70%, completely invisible on a white panel.
    @Test
    fun light_panel_track_and_free_legend_are_visible() {
        val colors = ai.oriveo.community.ui.theme.LightOriveoColors
        val track = legendColor(ContextUsageLegendKind.FREE, colors, memory = colors.info)
        assertTrue("free legend must not be transparent", track.alpha > 0f)
        for (base in listOf(colors.backgroundBase, colors.surface.compositeOver(colors.backgroundBase))) {
            val composited = track.compositeOver(base)
            val delta = maxOf(
                kotlin.math.abs(composited.red - base.red),
                kotlin.math.abs(composited.green - base.green),
                kotlin.math.abs(composited.blue - base.blue),
            )
            assertTrue("track must be distinguishable from $base, delta=$delta", delta > 0.05f)
        }
    }
}
