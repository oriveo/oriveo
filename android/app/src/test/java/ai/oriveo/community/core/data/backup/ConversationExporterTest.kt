package ai.oriveo.community.core.data.backup

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import java.util.Locale
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The cost line of a conversation export: reads the conversation USD total plus nonUsdCostTotals, exports each currency on its own joined by ` + `, and never adds across currencies.
 * Reads the conversation row from an in-memory Room database (the nonUsdCostTotals JSON column is decoded by the production mapper).
 */
@RunWith(RobolectricTestRunner::class)
class ConversationExporterTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase
    private lateinit var exporter: ConversationExporter

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        exporter = ConversationExporter(
            conversationDao = db.conversationDao(),
            messageDao = db.messageDao(),
            localeProvider = { Locale.forLanguageTag("zh-Hans") },
        )
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun export_cost_line_splits_currencies() = runBlocking {
        seed(estimatedCost = 1.2, nonUsdCostTotals = """{"CNY":3.5}""")

        val markdown = exporter.exportMarkdown(CONV).orEmpty()

        assertTrue(markdown, markdown.contains("Estimated Cost: $1.20 + ¥3.50\n"))
    }

    @Test
    fun export_cny_only_conversation_never_shows_zero_dollars() = runBlocking {
        seed(estimatedCost = 0.0, nonUsdCostTotals = """{"CNY":0.0039}""")

        val markdown = exporter.exportMarkdown(CONV).orEmpty()

        assertTrue(markdown, markdown.contains("Estimated Cost: ¥0.0039\n"))
        assertFalse(markdown, markdown.contains("$0"))
    }

    @Test
    fun export_without_cost_omits_cost_line() = runBlocking {
        seed(estimatedCost = 0.0, nonUsdCostTotals = null)

        val markdown = exporter.exportMarkdown(CONV).orEmpty()

        assertFalse(markdown, markdown.contains("Estimated Cost"))
    }

    private suspend fun seed(estimatedCost: Double, nonUsdCostTotals: String?) {
        db.conversationDao().upsert(
            ConversationEntity(
                id = CONV,
                title = "Cost",
                hasCustomTitle = false,
                providerID = "provider-a",
                providerKind = "OpenAI",
                modelID = "gpt-4o",
                previewText = "",
                estimatedCost = estimatedCost,
                isDraft = false,
                draftText = "",
                createdAt = 1_700_000_000_000L,
                updatedAt = 1_700_000_000_000L,
                accountId = ACCOUNT,
                nonUsdCostTotals = nonUsdCostTotals,
            ),
        )
    }

    private companion object {
        const val ACCOUNT = LOCAL_PARTITION_ID
        const val CONV = "conv-1"
    }
}
