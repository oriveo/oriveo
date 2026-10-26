package ai.oriveo.community.core.data.dao

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.MonthlyBilledMessageCountRow
import ai.oriveo.community.core.data.entity.MonthlyCostRow
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.provider.CostSource
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * MessageDao contract tests.
 *
 * The signature part uses reflection to check that the window-loading methods exist, so a refactor cannot silently delete one and send [MessageWindowLoader] down the wrong path
 * (the state machine itself is covered by [ai.oriveo.community.core.data.repository.chat.MessageWindowLoaderTest]);
 * the cost aggregation and inline-image text repair parts run real SQL on an in-memory Room database.
 */
@RunWith(RobolectricTestRunner::class)
class MessageDaoTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun sum_by_currency_groups_null_as_usd() = runBlocking {
        seedMixedConversation()

        // A message without nonUsdCostCurrency only counts as USD; a mixed-currency message counts in both USD and CNY; a non-USD part with source UNKNOWN is skipped
        val rows = db.messageDao().sumDeliveredCostByCurrency(ACCOUNT, CONV, CostFormatter.COST_EPSILON)
            .sortedBy { it.currencyCode }

        assertEquals(listOf("CNY", "USD"), rows.map { it.currencyCode })
        assertEquals(3.62, rows.single { it.currencyCode == "CNY" }.totalCost, 1e-9)
        assertEquals(1.25, rows.single { it.currencyCode == "USD" }.totalCost, 1e-9)

        // Monthly totals have one row per (provider, currency), with the same rules
        val monthly = db.messageDao().getMonthlyCostByProviderKind(
            accountId = ACCOUNT,
            minimumCostExclusive = CostFormatter.COST_EPSILON,
            windowStartMillis = 0L,
            windowEndMillis = Long.MAX_VALUE,
        ).sortedBy { it.currencyCode }
        assertEquals(
            listOf(
                MonthlyCostRow(providerKind = "OpenAI", providerID = "provider-a", totalCost = monthly[0].totalCost, currencyCode = "CNY"),
                MonthlyCostRow(providerKind = "OpenAI", providerID = "provider-a", totalCost = monthly[1].totalCost, currencyCode = "USD"),
            ),
            monthly,
        )
        assertEquals(3.62, monthly[0].totalCost, 1e-9)
        assertEquals(1.25, monthly[1].totalCost, 1e-9)
    }

    // ── Monthly aggregation per provider (tested through the production SQL path)──

    @Test
    fun monthly_window_uses_message_time_then_conversation_updated_half_open() = runBlocking {
        val start = 1_772_323_200_000L // 2026-03-01T00:00:00Z
        val end = 1_775_001_600_000L // 2026-04-01T00:00:00Z
        conversation(CONV, providerID = "provider-a", updatedAt = start + 5_000L)
        listOf(
            // Message time before the window: not counted even if the conversation updatedAt is inside it
            assistant("w1", 1, estimatedCost = 0.4).copy(createdAt = start - 1),
            // The window start is inclusive
            assistant("w2", 2, estimatedCost = 0.6).copy(createdAt = start),
            // The window end is exclusive
            assistant("w3", 3, estimatedCost = 5.0).copy(createdAt = end),
            // An older message without createdAt falls back to the conversation updatedAt
            assistant("w4", 4, estimatedCost = 0.25).copy(createdAt = null),
        ).forEach { db.messageDao().upsert(it) }

        val rows = db.messageDao().getMonthlyCostByProviderKind(ACCOUNT, CostFormatter.COST_EPSILON, start, end)

        assertEquals(listOf("USD"), rows.map { it.currencyCode })
        assertEquals(0.85, rows.single().totalCost, 1e-9)
    }

    @Test
    fun monthly_rows_per_provider_id_skip_draft() = runBlocking {
        conversation(CONV, providerID = "relay-a")
        conversation("conv-draft", providerID = "relay-a", isDraft = true)
        listOf(
            assistant("r1", 1, estimatedCost = 1.0).copy(providerKind = "Relay", providerID = "relay-a"),
            assistant("r2", 2, estimatedCost = 2.5).copy(providerKind = "Relay", providerID = "relay-b"),
            // An older message without providerID falls back to the conversation-level providerID
            assistant("r3", 3, estimatedCost = 0.5).copy(providerKind = "Relay", providerID = null),
            // Draft conversations are not counted
            assistant("r5", 5, estimatedCost = 7.0).copy(conversationId = "conv-draft", providerKind = "Relay"),
        ).forEach { db.messageDao().upsert(it) }

        val rows = db.messageDao().getMonthlyCostByProviderKind(ACCOUNT, CostFormatter.COST_EPSILON, 0L, Long.MAX_VALUE)
            .associate { it.providerID to it.totalCost }

        assertEquals(setOf("relay-a", "relay-b"), rows.keys)
        assertEquals(1.5, rows.getValue("relay-a"), 1e-9)
        assertEquals(2.5, rows.getValue("relay-b"), 1e-9)
    }

    // ── Billed messages this month (used to rank providers)──

    @Test
    fun billed_message_count_checks_usd_and_non_usd_parts_once_per_message() = runBlocking {
        conversation(CONV, providerID = "provider-a")
        listOf(
            // USD part recorded: counts 1
            assistant("b1", 1, estimatedCost = 0.5).copy(costSource = CostSource.UPSTREAM.name),
            // CNY only: top level UNKNOWN + 0, so nonUsdCost decides: counts 1
            assistant("b2", 2, estimatedCost = 0.0, currency = "CNY", amount = 0.1, source = CostSource.LOCAL_ESTIMATE.name)
                .copy(costSource = CostSource.UNKNOWN.name),
            // Mixed currencies: both parts recorded, counts only 1
            assistant("b3", 3, estimatedCost = 0.001, currency = "CNY", amount = 0.2, source = CostSource.LOCAL_ESTIMATE.name)
                .copy(costSource = CostSource.LOCAL_ESTIMATE.name),
            // Older path with an empty costSource and an amount above 0: treated as LOCAL_ESTIMATE, counts 1
            assistant("b9", 9, estimatedCost = 0.3).copy(costSource = null),
            // Source UNKNOWN: not counted even with an amount
            assistant("b4", 4, estimatedCost = 1.0).copy(costSource = CostSource.UNKNOWN.name),
            // Source recorded but the amount is 0: not counted
            assistant("b5", 5, estimatedCost = 0.0).copy(costSource = CostSource.LOCAL_ESTIMATE.name),
            // Non-USD source UNKNOWN: not counted
            assistant("b6", 6, estimatedCost = 0.0, currency = "EUR", amount = 9.0, source = CostSource.UNKNOWN.name)
                .copy(costSource = CostSource.UNKNOWN.name),
            // Not delivered: not counted
            assistant("b7", 7, estimatedCost = 3.0, state = "Failed").copy(costSource = CostSource.UPSTREAM.name),
        ).forEach { db.messageDao().upsert(it) }

        val rows = db.messageDao().observeMonthlyBilledMessageCountByProvider(
            accountId = ACCOUNT,
            minimumCostExclusive = CostFormatter.COST_EPSILON,
            windowStartMillis = 0L,
            windowEndMillis = Long.MAX_VALUE,
        ).first()

        assertEquals(listOf(MonthlyBilledMessageCountRow(providerID = "provider-a", billedCount = 4)), rows)
    }

    @Test
    fun billed_message_count_groups_by_message_provider_then_conversation_within_window() = runBlocking {
        val start = 1_772_323_200_000L // 2026-03-01T00:00:00Z
        val end = 1_775_001_600_000L // 2026-04-01T00:00:00Z
        conversation(CONV, providerID = "relay-a", updatedAt = start + 5_000L)
        conversation("conv-draft", providerID = "relay-a", isDraft = true, updatedAt = start + 5_000L)
        listOf(
            assistant("g1", 1, estimatedCost = 0.2).copy(costSource = CostSource.UPSTREAM.name, providerID = "relay-a", createdAt = start),
            assistant("g2", 2, estimatedCost = 0.2).copy(costSource = CostSource.UPSTREAM.name, providerID = "relay-b", createdAt = start + 1),
            // An older message without providerID falls back to the conversation level
            assistant("g3", 3, estimatedCost = 0.2).copy(costSource = CostSource.UPSTREAM.name, providerID = null, createdAt = null),
            // Outside the window
            assistant("g4", 4, estimatedCost = 0.2).copy(costSource = CostSource.UPSTREAM.name, providerID = "relay-a", createdAt = end),
            // Draft conversation
            assistant("g5", 5, estimatedCost = 0.2).copy(costSource = CostSource.UPSTREAM.name, conversationId = "conv-draft", createdAt = start),
        ).forEach { db.messageDao().upsert(it) }

        val rows = db.messageDao().observeMonthlyBilledMessageCountByProvider(ACCOUNT, CostFormatter.COST_EPSILON, start, end)
            .first()
            .associate { it.providerID to it.billedCount }

        assertEquals(mapOf("relay-a" to 2, "relay-b" to 1), rows)
    }

    private suspend fun conversation(id: String, providerID: String, updatedAt: Long = 1_700_000_000_000L, isDraft: Boolean = false) {
        db.conversationDao().upsert(
            ConversationEntity(
                id = id,
                title = "Cost",
                hasCustomTitle = false,
                providerID = providerID,
                providerKind = "Relay",
                modelID = "gpt-4o",
                previewText = "",
                estimatedCost = 0.0,
                isDraft = isDraft,
                draftText = "",
                createdAt = updatedAt,
                updatedAt = updatedAt,
                accountId = ACCOUNT,
            ),
        )
    }

    private suspend fun seedMixedConversation() {
        db.conversationDao().upsert(
            ConversationEntity(
                id = CONV,
                title = "Cost",
                hasCustomTitle = false,
                providerID = "provider-a",
                providerKind = "OpenAI",
                modelID = "gpt-4o",
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 1_700_000_000_000L,
                updatedAt = 1_700_000_000_000L,
                accountId = ACCOUNT,
            ),
        )
        listOf(
            // USD only: nonUsdCostCurrency is empty
            assistant("m1", 1, estimatedCost = 1.0),
            // Mixed currencies: a USD part plus a CNY part
            assistant("m2", 2, estimatedCost = 0.25, currency = "CNY", amount = 0.12, source = CostSource.LOCAL_ESTIMATE.name),
            // CNY only
            assistant("m3", 3, estimatedCost = 0.0, currency = "CNY", amount = 3.5, source = CostSource.LOCAL_ESTIMATE.name),
            // A non-USD part with source UNKNOWN is skipped
            assistant("m4", 4, estimatedCost = 0.0, currency = "EUR", amount = 9.0, source = CostSource.UNKNOWN.name),
            // Not delivered: not counted
            assistant("m5", 5, estimatedCost = 7.0, currency = "CNY", amount = 7.0, source = CostSource.LOCAL_ESTIMATE.name, state = "Failed"),
        ).forEach { db.messageDao().upsert(it) }
    }

    private fun assistant(
        id: String,
        order: Int,
        estimatedCost: Double,
        currency: String? = null,
        amount: Double? = null,
        source: String? = null,
        state: String = "Delivered",
    ) = MessageEntity(
        id = id,
        conversationId = CONV,
        role = "Assistant",
        text = "reply",
        providerID = "provider-a",
        providerKind = "OpenAI",
        providerName = "OpenAI",
        modelName = "gpt-4o",
        estimatedCost = estimatedCost,
        state = state,
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = 1_700_000_000_000L + order,
        sortOrder = order,
        accountId = ACCOUNT,
        nonUsdCostCurrency = currency,
        nonUsdCostAmount = amount,
        nonUsdCostSource = source,
    )

    private companion object {
        const val ACCOUNT = "account-1"
        const val CONV = "conv-1"
    }

    @Test
    fun `dao exposes keyset window loader methods`() {
        val methodNames = MessageDao::class.java.methods.map { it.name }.toSet()

        assertTrue("observeLatestMessageWindow is missing", methodNames.contains("observeLatestMessageWindow"))
        assertTrue("fetchLatestMessageWindow is missing", methodNames.contains("fetchLatestMessageWindow"))
        assertTrue("fetchMessagesBefore is missing", methodNames.contains("fetchMessagesBefore"))
        assertTrue("fetchMessagesAfter is missing", methodNames.contains("fetchMessagesAfter"))
        assertTrue("existsBefore is missing", methodNames.contains("existsBefore"))
        assertTrue("existsAfter is missing", methodNames.contains("existsAfter"))
    }

    @Test
    fun `legacy observeByConversation remains for export and backup paths`() {
        // The old full observer is kept for paths outside the chat screen (export / backup / RecoveryCard) and must not be removed.
        val methodNames = MessageDao::class.java.methods.map { it.name }.toSet()
        assertTrue("observeByConversation must be kept", methodNames.contains("observeByConversation"))
        assertTrue("getByConversation must be kept", methodNames.contains("getByConversation"))
    }

    @Test
    fun `dao exposes oversized attachmentsJson repair methods`() {
        // Companion methods of the SQLiteBlobTooBigException repair for old bad rows: locate + read in chunks + write only this column;
        // if any one is missing, MessageAttachmentRepairTask silently takes the wrong path (see its class comment).
        val methodNames = MessageDao::class.java.methods.map { it.name }.toSet()
        assertTrue("findOversizedAttachmentsJsonRows is missing", methodNames.contains("findOversizedAttachmentsJsonRows"))
        assertTrue("readAttachmentsJsonChunk is missing", methodNames.contains("readAttachmentsJsonChunk"))
        assertTrue("updateAttachmentsJson is missing", methodNames.contains("updateAttachmentsJson"))
    }

    // Locate and rewrite SQL for repairing rows whose text carries inline images: matches only on
    // length + the inline-image marker, never reads the whole row.
    @Test
    fun oversized_inline_image_text_rows_are_located_and_rewritten_in_place() = runBlocking {
        db.conversationDao().upsert(
            ConversationEntity(
                id = CONV,
                title = "Inline images",
                hasCustomTitle = false,
                providerID = "provider-a",
                providerKind = "Relay",
                modelID = "gpt-4o",
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 1_700_000_000_000L,
                updatedAt = 1_700_000_000_000L,
                accountId = ACCOUNT,
            ),
        )
        val bigImage = "![g](data:image/png;base64,${"A".repeat(300)})"
        listOf(
            assistant("img", 1, text = "x $bigImage"),
            // Long but without an inline image: not this repair's concern
            assistant("long", 2, text = "y".repeat(400)),
            // Has an inline image but is short
            assistant("short", 3, text = "![g](data:image/png;base64,QQ==)"),
        ).forEach { db.messageDao().upsert(it) }
        val dao = db.messageDao()

        val rows = dao.findOversizedInlineImageTextRows(thresholdChars = 200)

        assertEquals(listOf("img"), rows.map { it.id })
        assertEquals(bigImage.length + 2, rows.single().len)
        assertEquals("x ![g]", dao.readTextChunk(ACCOUNT, "img", 1, 6))
        assertEquals(null, dao.attachmentsJsonLength(ACCOUNT, "img"))
        assertEquals(1, dao.updateTextAndAttachmentsJson(ACCOUNT, "img", "x ", "[]"))
        assertEquals("x ", dao.getById(ACCOUNT, "img")?.text)
        assertEquals("[]", dao.getById(ACCOUNT, "img")?.attachmentsJson)
        assertEquals(1, dao.sortOrderOf(ACCOUNT, "img"))
        assertEquals(null, dao.sortOrderOf(ACCOUNT, "missing"))
        // @Transaction does not change the result or order of a full read
        assertEquals(listOf("img", "long", "short"), dao.getByConversation(ACCOUNT, CONV).map { it.id })
    }

    private fun assistant(id: String, order: Int, text: String) = MessageEntity(
        id = id,
        conversationId = CONV,
        role = "Assistant",
        text = text,
        providerID = "provider-a",
        providerKind = "Relay",
        providerName = "Relay",
        modelName = "gpt-4o",
        estimatedCost = 0.0,
        state = "Delivered",
        errorTitle = null,
        errorDetail = null,
        attachmentsJson = null,
        createdAt = 1_700_000_000_000L + order,
        sortOrder = order,
        accountId = ACCOUNT,
    )
}
