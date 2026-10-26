package ai.oriveo.community.core.data.attachment

import android.content.Context
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.entity.AttachmentsJsonPageRow
import ai.oriveo.community.core.data.entity.OversizedAttachmentsJsonRow
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.confirmVerified
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The attachment file cleanup entry points and the orphan sweep at launch.
 *
 * AttachmentStore is the real implementation on a temporary directory (it only reads and writes bytes, never touching a Bitmap); MessageDao is a mockk without relaxed,
 * so any call that is not stubbed (including every method that writes to the database) throws.
 */
class AttachmentOrphanSweeperTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var filesDir: File
    private lateinit var store: AttachmentStore
    private val messageDao = mockk<MessageDao>()

    @Before
    fun setUp() {
        filesDir = tempFolder.newFolder("files")
        val context = mockk<Context> { every { filesDir } returns this@AttachmentOrphanSweeperTest.filesDir }
        store = AttachmentStore(context)
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } returns emptyList()
        coEvery { messageDao.readAttachmentsJsonPageAllAccounts(any(), any(), any()) } returns emptyList()
    }

    private fun sweeper(launchAt: Long = LAUNCH) = AttachmentOrphanSweeper(
        messageDao = messageDao,
        attachmentStore = store,
        launchTimeMillis = { launchAt },
    )

    private fun saveImage(key: String, modifiedAt: Long = OLD) {
        store.saveImageRaw(key, byteArrayOf(1, 2, 3))
        store.saveThumbnailRaw(key, byteArrayOf(4, 5))
        File(filesDir, "attachments/images/$key.jpg").setLastModified(modifiedAt)
        File(filesDir, "attachments/thumbnails/$key.jpg").setLastModified(modifiedAt)
    }

    private fun saveBlob(key: String, modifiedAt: Long = OLD) {
        store.saveBlobRaw(key, byteArrayOf(9))
        File(filesDir, "attachments/blobs/$key").setLastModified(modifiedAt)
    }

    private fun imageGone(key: String) = !store.hasImage(key) && store.loadThumbnailBytes(key) == null

    private fun imageKept(key: String) = store.hasImage(key) && store.loadThumbnailBytes(key) != null

    private fun attachmentsJson(vararg attachments: Attachment) = Json.encodeToString(attachments.toList())

    private fun image(id: String, localImageId: String? = null, rawContentRef: String? = null) = Attachment(
        id = id,
        kind = AttachmentKind.Image,
        fileName = "a.jpg",
        mimeType = "image/jpeg",
        localImageId = localImageId,
        rawContentRef = rawContentRef,
    )

    private fun referencedBy(vararg json: String) {
        coEvery { messageDao.readAttachmentsJsonPageAllAccounts(any(), any(), any()) } returns
            json.mapIndexed { index, value -> AttachmentsJsonPageRow(rowId = index + 1L, attachmentsJson = value) }
    }

    // The freed bytes in each round's log include the thumbnail file (image 3 + thumbnail 2 + blob 1)
    @Test
    fun attachmentLog_countsThumbnailBytes() = runTest {
        saveImage("img-gone")
        saveBlob("img-gone")
        val lines = mutableListOf<String>()
        val sweeper = AttachmentOrphanSweeper(
            messageDao = messageDao,
            attachmentStore = store,
            launchTimeMillis = { LAUNCH },
            log = { lines += it },
        )

        assertEquals(1, sweeper.purgeUnreferencedAttachments(listOf("img-gone")))

        assertTrue(imageGone("img-gone"))
        assertEquals(1, lines.size)
        assertTrue("the logged bytes include the thumbnail, actual ${lines.single()}", lines.single().contains("deleted=1 bytes=6 "))
    }

    @Test
    fun attachmentPurge_deletesUnreferencedCandidate() = runTest {
        saveImage("img-gone")
        saveBlob("blob-gone")
        saveImage("img-other")
        referencedBy(attachmentsJson(image(id = "att-x", localImageId = "img-other")))

        val deleted = sweeper().purgeUnreferencedAttachments(listOf("img-gone", "blob-gone"))

        assertEquals(2, deleted)
        assertTrue(imageGone("img-gone"))
        assertFalse(store.hasBlob("blob-gone"))
        assertTrue(imageKept("img-other"))
    }

    @Test
    fun attachmentPurge_keepsSharedKey() = runTest {
        // A conflict copy and the original message share file keys: a hit on any of the three reference keys (localImageId / attachment.id / rawContentRef) keeps the file.
        saveImage("img-shared")
        saveImage("att-cloud-id")
        saveBlob("blob-shared")
        referencedBy(
            attachmentsJson(image(id = "att-1", localImageId = "img-shared")),
            attachmentsJson(image(id = "att-cloud-id"), image(id = "att-3", rawContentRef = "blob-shared")),
        )

        val deleted = sweeper().purgeUnreferencedAttachments(listOf("img-shared", "att-cloud-id", "blob-shared"))

        assertEquals(0, deleted)
        assertTrue(imageKept("img-shared"))
        assertTrue(imageKept("att-cloud-id"))
        assertTrue(store.hasBlob("blob-shared"))
    }

    @Test
    fun attachmentPurge_otherAccountStillReferences_keeps() = runTest {
        // The reference set spans accounts: an ordinary row of another account and a row over 2 MB read in chunks both count as references.
        saveImage("img-a")
        saveImage("img-b")
        val oversized = attachmentsJson(image(id = "att-b", localImageId = "img-b"))
        referencedBy(attachmentsJson(image(id = "att-a", localImageId = "img-a")))
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } returns
            listOf(OversizedAttachmentsJsonRow(id = "msg-b", accountId = "other-account", len = oversized.length))
        coEvery { messageDao.readAttachmentsJsonChunk("other-account", "msg-b", 1, any()) } returns oversized

        val deleted = sweeper().purgeUnreferencedAttachments(listOf("img-a", "img-b"))

        assertEquals(0, deleted)
        assertTrue(imageKept("img-a"))
        assertTrue(imageKept("img-b"))
        coVerify { messageDao.readAttachmentsJsonChunk("other-account", "msg-b", 1, any()) }
    }

    @Test
    fun attachmentPurge_referenceReadFails_deletesNothing() = runTest {
        saveImage("img-1")
        saveImage("img-2")

        // 1) the paged read throws
        coEvery { messageDao.readAttachmentsJsonPageAllAccounts(any(), any(), any()) } throws IllegalStateException("db")
        assertEquals(0, sweeper().purgeUnreferencedAttachments(listOf("img-1")))

        // 2) JSON parsing fails
        referencedBy("{not json")
        assertEquals(0, sweeper().purgeUnreferencedAttachments(listOf("img-1")))

        // 3) an oversized row returns an empty chunk halfway through the chunked read
        referencedBy(attachmentsJson(image(id = "att-9")))
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } returns
            listOf(OversizedAttachmentsJsonRow(id = "msg-big", accountId = "acc", len = 500_000))
        coEvery { messageDao.readAttachmentsJsonChunk("acc", "msg-big", 1, any()) } returns "["
        coEvery { messageDao.readAttachmentsJsonChunk("acc", "msg-big", not(1), any()) } returns null
        assertEquals(0, sweeper().purgeUnreferencedAttachments(listOf("img-1", "img-2")))
        assertEquals(0, sweeper().sweepOnLaunch())

        assertTrue(imageKept("img-1"))
        assertTrue(imageKept("img-2"))
    }

    @Test
    fun orphanSweep_deletesOrphansOutsideGrace() = runTest {
        saveImage("img-orphan")
        saveBlob("blob-orphan")
        saveImage("img-live")
        referencedBy(attachmentsJson(image(id = "att-live", localImageId = "img-live")))

        val deleted = sweeper().sweepOnLaunch()

        assertEquals(2, deleted)
        assertTrue(imageGone("img-orphan"))
        assertFalse(store.hasBlob("blob-orphan"))
        assertTrue(imageKept("img-live"))
    }

    @Test
    fun orphanSweep_keepsAvatarAndGrace() = runTest {
        saveImage("user-avatar-abc")
        saveImage("img-fresh", modifiedAt = LAUNCH - 60 * 60 * 1000L)
        saveBlob("blob-fresh", modifiedAt = LAUNCH - 60 * 60 * 1000L)
        // Old thumbnail, new image: the same key takes the latest modification time, so it is still within the grace period
        saveImage("img-mixed")
        File(filesDir, "attachments/images/img-mixed.jpg").setLastModified(LAUNCH - 1000L)

        val deleted = sweeper().sweepOnLaunch()

        assertEquals(0, deleted)
        assertTrue(imageKept("user-avatar-abc"))
        assertTrue(imageKept("img-fresh"))
        assertTrue(store.hasBlob("blob-fresh"))
        assertTrue(imageKept("img-mixed"))
    }

    @Test
    fun orphanSweep_noDbOrCloudWrites() = runTest {
        // The sweep depends only on MessageDao (reads) and AttachmentStore (files), and has nothing else to call;
        // apart from the two read queries there is no call on MessageDao at all.
        saveImage("img-orphan")
        saveImage("img-live")
        referencedBy(attachmentsJson(image(id = "att-live", localImageId = "img-live")))

        sweeper().sweepOnLaunch()
        sweeper().purgeUnreferencedAttachments(listOf("img-live"))

        coVerify(exactly = 2) { messageDao.readAttachmentsJsonPageAllAccounts(Long.MIN_VALUE, any(), any()) }
        coVerify(exactly = 2) { messageDao.findOversizedAttachmentsJsonRows(any()) }
        confirmVerified(messageDao)
        assertTrue(imageGone("img-orphan"))
        assertTrue(imageKept("img-live"))
    }

    @Test
    fun orphanSweep_graceFromLaunchTime() = runTest {
        // The grace baseline is the process start time, not the time the sweep runs: files within 24 h before the start and files written after it are never candidates.
        saveImage("img-before-grace", modifiedAt = LAUNCH - 25L * 60 * 60 * 1000)
        saveBlob("blob-before-grace", modifiedAt = LAUNCH - 25L * 60 * 60 * 1000)
        saveImage("img-in-grace", modifiedAt = LAUNCH - 23L * 60 * 60 * 1000)
        saveBlob("blob-after-launch", modifiedAt = LAUNCH + 30L * 60 * 60 * 1000)

        val deleted = sweeper(launchAt = LAUNCH).sweepOnLaunch()

        assertEquals(2, deleted)
        assertTrue(imageGone("img-before-grace"))
        assertFalse(store.hasBlob("blob-before-grace"))
        assertTrue(imageKept("img-in-grace"))
        assertTrue(store.hasBlob("blob-after-launch"))
    }

    @Test
    fun orphanSweep_partitionSwitchMidRun_aborts() = runTest {
        // The reference set is read across all accounts (the attachment directories are shared by the whole device), so the sweep does not depend on the current uid:
        // switching accounts mid-round does not change the reference set and so does not change the verdict. Keys referenced by either account are kept and only orphans neither references are deleted.
        saveImage("img-acc-a")
        saveImage("img-acc-b")
        saveBlob("blob-orphan")
        var activeAccount = "acc-a"
        val rows = listOf(
            AttachmentsJsonPageRow(rowId = 1L, attachmentsJson = attachmentsJson(image(id = "att-a", localImageId = "img-acc-a"))),
            AttachmentsJsonPageRow(rowId = 2L, attachmentsJson = attachmentsJson(image(id = "att-b", localImageId = "img-acc-b"))),
        )
        coEvery { messageDao.readAttachmentsJsonPageAllAccounts(any(), any(), any()) } answers {
            activeAccount = "acc-b"
            rows
        }

        val deleted = sweeper().sweepOnLaunch()

        assertEquals("acc-b", activeAccount)
        assertEquals(1, deleted)
        assertFalse(store.hasBlob("blob-orphan"))
        assertTrue(imageKept("img-acc-a"))
        assertTrue(imageKept("img-acc-b"))
    }

    @Test
    fun orphanSweep_massDeletionAborts() = runTest {
        // 201 candidates > 200 and more than half of the stored keys (201 + 150): judged abnormal, nothing is deleted this round.
        val orphans = (1..201).map { "blob-orphan-$it" }.onEach { saveBlob(it) }
        val live = (1..150).map { "blob-live-$it" }.onEach { saveBlob(it) }
        referencedBy(attachmentsJson(*live.map { image(id = "att-$it", rawContentRef = it) }.toTypedArray()))

        assertEquals(0, sweeper().sweepOnLaunch())
        assertTrue(orphans.all { store.hasBlob(it) })

        // Once the stored keys grow to 201 + 202 the candidates are no longer over half: all orphans are deleted as usual and the one referenced key stays.
        val moreLive = (151..202).map { "blob-live-$it" }.onEach { saveBlob(it) }
        val allLive = live + moreLive
        referencedBy(attachmentsJson(*allLive.map { image(id = "att-$it", rawContentRef = it) }.toTypedArray()))

        assertEquals(201, sweeper().sweepOnLaunch())
        assertTrue(orphans.none { store.hasBlob(it) })
        assertTrue(allLive.all { store.hasBlob(it) })
    }

    @Test
    fun orphanSweep_capPerRound() = runTest {
        // 501 orphans (not over half of the 1101 stored keys): one round deletes only 500 and the rest wait for the next round.
        val orphans = (1..501).map { "blob-orphan-$it" }.onEach { saveBlob(it) }
        val live = (1..600).map { "blob-live-$it" }.onEach { saveBlob(it) }
        referencedBy(attachmentsJson(*live.map { image(id = "att-$it", rawContentRef = it) }.toTypedArray()))

        assertEquals(500, sweeper().sweepOnLaunch())
        assertEquals(1, orphans.count { store.hasBlob(it) })
        assertEquals(1, sweeper().sweepOnLaunch())
        assertTrue(orphans.none { store.hasBlob(it) })
        assertTrue(live.all { store.hasBlob(it) })

        // purge has the same cap
        val purgeKeys = (1..501).map { "blob-purge-$it" }.onEach { saveBlob(it) }
        assertEquals(500, sweeper().purgeUnreferencedAttachments(purgeKeys))
        assertEquals(1, purgeKeys.count { store.hasBlob(it) })
    }

    @Test
    fun purge_partitionSwitchMidRun_aborts() = runTest {
        // Same as orphanSweep_partitionSwitchMidRun_aborts: the purge reference set also spans all accounts, so switching accounts mid-round changes nothing.
        saveImage("img-acc-b")
        saveImage("img-unreferenced")
        var activeAccount = "acc-a"
        coEvery { messageDao.readAttachmentsJsonPageAllAccounts(any(), any(), any()) } answers {
            activeAccount = "acc-b"
            listOf(AttachmentsJsonPageRow(rowId = 1L, attachmentsJson = attachmentsJson(image(id = "att-b", localImageId = "img-acc-b"))))
        }

        val deleted = sweeper().purgeUnreferencedAttachments(listOf("img-acc-b", "img-unreferenced"))

        assertEquals("acc-b", activeAccount)
        assertEquals(1, deleted)
        assertTrue(imageKept("img-acc-b"))
        assertTrue(imageGone("img-unreferenced"))
    }

    @Test
    fun references_includeNormalizedKeys() = runTest {
        // The reference set collects raw and normalised values (upper-case UUID), so a key whose case differs between disk and JSON still counts as referenced
        val lowerOnDisk = "3f2a8c1e-4b5d-4e6f-8a9b-0c1d2e3f4a5b"
        val upperOnDisk = "9E8D7C6B-5A4F-4E3D-9C2B-1A0F9E8D7C6B"
        saveImage(lowerOnDisk)
        saveBlob(upperOnDisk)
        saveImage("img-orphan")
        referencedBy(
            attachmentsJson(
                image(id = "att-1", localImageId = lowerOnDisk.uppercase()),
                image(id = "att-2", rawContentRef = upperOnDisk.lowercase()),
            ),
        )

        assertEquals(0, sweeper().purgeUnreferencedAttachments(listOf(lowerOnDisk, upperOnDisk)))
        assertEquals(1, sweeper().sweepOnLaunch())

        assertTrue(imageKept(lowerOnDisk))
        assertTrue(store.hasBlob(upperOnDisk))
        assertTrue(imageGone("img-orphan"))
    }

    @Test
    fun orphanSweep_unreadableMtime_skipped() = runTest {
        // An unreadable modification time (lastModified is 0) is skipped, not treated as very old
        saveImage("img-no-mtime", modifiedAt = 0L)
        saveBlob("blob-no-mtime", modifiedAt = 0L)
        saveImage("img-old-orphan")

        val deleted = sweeper().sweepOnLaunch()

        assertEquals(1, deleted)
        assertTrue(imageKept("img-no-mtime"))
        assertTrue(store.hasBlob("blob-no-mtime"))
        assertTrue(imageGone("img-old-orphan"))
    }

    private companion object {
        const val LAUNCH = 1_800_000_000_000L
        const val OLD = LAUNCH - 48L * 60 * 60 * 1000
    }
}
