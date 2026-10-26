package ai.oriveo.community.core.data.dao

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.MessageEntity
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
 * Contract test for MessageDao's method signatures.
 *
 * The queries themselves are validated by Room at compile time, so this test does not execute
 * SQL. It reflects over the DAO to verify the window-loading methods exist with the right
 * signatures, so a refactor can't silently delete one and send [MessageWindowLoader] down the
 * wrong path.
 *
 * State-machine level coverage lives in [ai.oriveo.community.core.data.repository.chat.MessageWindowLoaderTest].
 * The inline-image text repair queries run as real SQL against an in-memory Room database.
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
        // The old full-table observer is still kept for non-chat-screen paths (export/backup/RecoveryCard); don't remove it by mistake.
        val methodNames = MessageDao::class.java.methods.map { it.name }.toSet()
        assertTrue("observeByConversation must be kept", methodNames.contains("observeByConversation"))
        assertTrue("getByConversation must be kept", methodNames.contains("getByConversation"))
    }

    @Test
    fun `dao exposes oversized attachmentsJson repair methods`() {
        // Companion methods for repairing legacy rows that hit SQLiteBlobTooBigException: locate,
        // read in chunks, and write back only that one column. Losing any of the three would
        // silently send MessageAttachmentRepairTask down the wrong path (see its class doc).
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

    private companion object {
        const val ACCOUNT = "account-1"
        const val CONV = "conv-1"
    }
}
