package ai.oriveo.community.core.data.dao

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract test for MessageDao's method signatures.
 *
 * The queries themselves are validated by Room at compile time, so this test does not execute
 * SQL. It reflects over the DAO to verify the window-loading methods exist with the right
 * signatures, so a refactor can't silently delete one and send [MessageWindowLoader] down the
 * wrong path.
 *
 * State-machine level coverage lives in [ai.oriveo.community.core.data.repository.chat.MessageWindowLoaderTest].
 */
class MessageDaoTest {

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
}
