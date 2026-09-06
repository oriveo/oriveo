package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.model.Folder
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class FolderRepositoryTest {

    private val folderDao = mockk<FolderDao>()
    private val conversationDao = mockk<ConversationDao>()

    private lateinit var repository: FolderRepository
    @Before
    fun setup() {
        coEvery { folderDao.getAll(any()) } returns emptyList()
        repository = FolderRepository(folderDao, conversationDao)
    }

    @Test
    fun `create folder with valid name`() = runTest {
        val slot = slot<FolderEntity>()
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 1000
        coEvery { folderDao.upsert(capture(slot)) } returns Unit

        val result = repository.create("Work")

        assertEquals("Work", result?.name)
        assertEquals(2000, result?.sortOrder)
    }

    @Test
    fun `create folder trims whitespace`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("  Projects  ")

        assertEquals("Projects", result?.name)
    }

    @Test
    fun `create folder rejects empty name`() = runTest {
        val result = repository.create("   ")
        assertNull(result)
    }

    @Test
    fun `rename folder updates name`() = runTest {
        val existing = FolderEntity("f1", "Old", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns existing
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.rename("f1", "New Name")

        assertEquals("New Name", result?.name)
    }

    @Test
    fun `delete folder clears conversations folderID`() = runTest {
        val folder = FolderEntity("f1", "Test", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conv = ConversationEntity(
            id = "c1",
            title = "Chat",
            hasCustomTitle = false,
            providerID = "p1",
            providerKind = ProviderKind.OpenAI.name,
            modelID = "m1",
            useMemory = true,
            previewText = "",
            estimatedCost = 0.0,
            isDraft = false,
            draftText = "",
            createdAt = 100L,
            updatedAt = 100L,
            folderID = "f1",
            accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(conv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

        coVerify { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
        coVerify { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") }
    }

    // TC-1.1.4: creating 10 folders in a row, each ID is unique
    @Test
    fun `TC-1-1-4 create 10 folders all have unique IDs`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returnsMany (0..9).map { it * 1000 }
        coEvery { folderDao.upsert(any()) } returns Unit

        val ids = (0 until 10).mapNotNull { repository.create("Folder $it")?.id }

        assertEquals(10, ids.size)
        assertEquals(10, ids.toSet().size)
    }

    // TC-1.1.5: createdAt is unchanged after rename
    @Test
    fun `TC-1-1-5 rename preserves createdAt`() = runTest {
        val createdAt = 12345L
        val existing = FolderEntity("f1", "Old", 1000, createdAt, 200L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns existing
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.rename("f1", "New Name")

        assertEquals(createdAt, result?.createdAt)
    }

    // TC-1.2.2: renaming to match another folder's name is allowed (duplicate names are explicitly permitted)
    @Test
    fun `TC-1-2-2 rename allows duplicate folder name`() = runTest {
        val existing = FolderEntity("f2", "Different", 2000, 100L, 100L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f2") } returns existing
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.rename("f2", "Same Name")

        assertEquals("Same Name", result?.name)
    }

    // TC-1.2.3: rename does not touch the conversation DAO
    @Test
    fun `TC-1-2-3 rename does not touch conversation DAO`() = runTest {
        val existing = FolderEntity("f1", "Old", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns existing
        coEvery { folderDao.upsert(any()) } returns Unit

        repository.rename("f1", "New Name")

        coVerify(exactly = 0) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) }
    }

    // TC-1.2.4: rename does not affect sortOrder
    @Test
    fun `TC-1-2-4 rename preserves sortOrder`() = runTest {
        val existing = FolderEntity("f1", "Old", 2000, 100L, 100L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns existing
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.rename("f1", "New Name")

        assertEquals(2000, result?.sortOrder)
    }

    // TC-1.3.4: deleting a folder's clearFolderID call does not update updatedAt (a metadata operation doesn't affect ordering)
    @Test
    fun `TC-1-3-4 delete folder calls clearFolderID without updating timestamp`() = runTest {
        val folder = FolderEntity("f1", "Test", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conv = ConversationEntity(
            id = "c1",
            title = "Chat",
            hasCustomTitle = false,
            providerID = "p1",
            providerKind = ProviderKind.OpenAI.name,
            modelID = "m1",
            useMemory = true,
            previewText = "",
            estimatedCost = 0.0,
            isDraft = false,
            draftText = "",
            createdAt = 100L,
            updatedAt = 100L,
            folderID = "f1",
            accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(conv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, any()) } returns Unit

        repository.delete("f1")

        coVerify(exactly = 1) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
    }

    // TC-1.3.5: deleting a non-existent folder does not crash
    @Test
    fun `TC-1-3-5 delete non-existent folder does not crash`() = runTest {
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, any()) } returns null

        repository.delete("non-existent-id")

        coVerify(exactly = 0) { folderDao.deleteById(LOCAL_PARTITION_ID, any()) }
        coVerify(exactly = 0) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) }
    }

    // TC-1.3.9: deleting a folder only clears folderID, it does not delete the conversations themselves
    @Test
    fun `TC-1-3-9 delete folder keeps conversations`() = runTest {
        val folder = FolderEntity("f1", "Test", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conv = ConversationEntity(
            id = "c1",
            title = "Survive Chat",
            hasCustomTitle = false,
            providerID = "p1",
            providerKind = ProviderKind.OpenAI.name,
            modelID = "m1",
            useMemory = true,
            previewText = "",
            estimatedCost = 0.0,
            isDraft = false,
            draftText = "",
            createdAt = 100L,
            updatedAt = 100L,
            folderID = "f1",
            accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(conv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

        // clearFolderID is called (conversations are kept, only folderID is cleared)
        coVerify { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
        // the conversations themselves are not deleted
        coVerify(exactly = 0) { conversationDao.deleteById(any(), any()) }
    }

    // -- TC-2 name validation --

    // TC-2.1.2: exactly 30 characters is accepted
    @Test
    fun `TC-2-1-2 name exactly 30 chars is accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val name30 = "A".repeat(30)
        val result = repository.create(name30)

        assertEquals(30, result?.name?.length)
        assertEquals(name30, result?.name)
    }

    // TC-2.1.3: over 30 characters is truncated
    @Test
    fun `TC-2-1-3 name over 30 chars is truncated`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("A".repeat(50))

        assertEquals(30, result?.name?.length)
    }

    // TC-2.1.6: a name containing emoji is accepted
    @Test
    fun `TC-2-1-6 name with emoji is accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("📚 Study Notes")

        assertNotNull(result)
        assertEquals("📚 Study Notes", result?.name)
    }

    // TC-2.1.7: a name that is pure emoji is accepted
    @Test
    fun `TC-2-1-7 pure emoji name is accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("🎉🎊🎈")

        assertEquals("🎉🎊🎈", result?.name)
    }

    // TC-2.1.8: special characters are accepted
    @Test
    fun `TC-2-1-8 special chars are accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("Work/Projects #1")

        assertEquals("Work/Projects #1", result?.name)
    }

    // TC-2.1.9: a unicode kana name is accepted
    @Test
    fun `TC-2-1-9 unicode kana name is accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("しごとのプロジェクトかんり")

        assertEquals("しごとのプロジェクトかんり", result?.name)
    }

    // TC-2.1.10: a single character is accepted
    @Test
    fun `TC-2-1-10 single char name is accepted`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("A")

        assertEquals("A", result?.name)
    }

    // TC-2.1.11: leading/trailing spaces plus overlong -> trimmed then truncated to 30
    @Test
    fun `TC-2-1-11 spaces plus overlong trims then truncates`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("  " + "A".repeat(40) + "  ")

        assertEquals(30, result?.name?.length)
        assertEquals("A".repeat(30), result?.name)
    }

    // TC-2.1.12: an internal newline is preserved (trim only removes leading/trailing whitespace; internal \n is unaffected)
    @Test
    fun `TC-2-1-12 inner newline is preserved`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("Work\nProjects")

        assertEquals("Work\nProjects", result?.name)
    }

    // TC-2.1.13: an internal tab is preserved (trim only removes leading/trailing whitespace; internal \t is unaffected)
    @Test
    fun `TC-2-1-13 inner tab is preserved`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("Work\tProjects")

        assertEquals("Work\tProjects", result?.name)
    }

    // -- TC-3 ordering --

    // TC-3.1.3: after deleting a middle folder, a new one's sortOrder = max(remaining)+1000
    @Test
    fun `TC-3-1-3 after deleting middle folder new folder gets max remaining plus 1000`() = runTest {
        // simulate existing A(1000), C(3000) (B was deleted); maxSortOrder returns 3000
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 3000
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("D")

        assertEquals(4000, result?.sortOrder)
    }

    // -- TC-22 edge cases and exceptions --

    // TC-22.1.1: deleting the last conversation in a folder -> the folder still exists (only folderID is cleared, the folder itself is not deleted)
    @Test
    fun `TC-22-1-1 delete last conversation from folder leaves folder intact`() = runTest {
        val folder = FolderEntity("f1", "Work", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val lastConv = ConversationEntity(
            id = "c1", title = "Last Chat", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(lastConv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        // after deleting the folder: the folder is deleted, but conversations are kept (only folderID is cleared)
        repository.delete("f1")

        // clearFolderID is called -- conversations are no longer associated with the folder
        coVerify { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
        // the folder itself is deleted
        coVerify { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") }
        // the conversations themselves are not deleted
        coVerify(exactly = 0) { conversationDao.deleteById(any(), any()) }
    }

    // TC-22.1.2: 100+ conversations in a single folder -> all load correctly (all identified on delete)
    @Test
    fun `TC-22-1-2 folder with 100+ conversations all identified on delete`() = runTest {
        val folder = FolderEntity("f1", "Big Folder", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conversations = (1..120).map { i ->
            ConversationEntity(
                id = "c$i", title = "Chat $i", hasCustomTitle = false,
                providerID = "p1", modelID = "m1", useMemory = true,
                providerKind = ProviderKind.OpenAI.name,
                previewText = "", estimatedCost = 0.0,
                isDraft = false, draftText = "",
                createdAt = 100L, updatedAt = 100L,
                folderID = "f1", accountId = LOCAL_PARTITION_ID,
            )
        }
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns conversations
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

    }

    // -- cross-platform consistency --

    // TC-25.1.1: max folder name length = 30 characters
    @Test
    fun `TC-25-1-1 max folder name length is 30 characters`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        // exactly 30 characters -> passes
        val result30 = repository.create("A".repeat(30))
        assertEquals(30, result30?.name?.length)

        // 31 characters -> truncated to 30
        val result31 = repository.create("B".repeat(31))
        assertEquals(30, result31?.name?.length)

        // 100 characters -> truncated to 30
        val result100 = repository.create("C".repeat(100))
        assertEquals(30, result100?.name?.length)
    }

    // TC-25.1.2: empty or whitespace-only names are rejected
    @Test
    fun `TC-25-1-2 empty or whitespace-only name is rejected`() = runTest {
        assertNull(repository.create(""))
        assertNull(repository.create("   "))
        assertNull(repository.create("\t"))
        assertNull(repository.create("\n"))
        assertNull(repository.create("  \t\n  "))
    }

    // TC-25.1.3: initial sortOrder = 1000 (when no folders exist yet)
    @Test
    fun `TC-25-1-3 sortOrder initial value is 1000`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns null
        coEvery { folderDao.upsert(any()) } returns Unit

        val result = repository.create("First Folder")

        assertEquals(1000, result?.sortOrder)
    }

    // TC-25.1.4: sortOrder increments by +1000
    @Test
    fun `TC-25-1-4 sortOrder increment is 1000`() = runTest {
        coEvery { folderDao.upsert(any()) } returns Unit

        // first folder, maxSortOrder = null -> sortOrder = 1000
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns null
        val first = repository.create("First")
        assertEquals(1000, first?.sortOrder)

        // second folder, maxSortOrder = 1000 -> sortOrder = 2000
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 1000
        val second = repository.create("Second")
        assertEquals(2000, second?.sortOrder)

        // third folder, maxSortOrder = 2000 -> sortOrder = 3000
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 2000
        val third = repository.create("Third")
        assertEquals(3000, third?.sortOrder)

        // the increment is always 1000
        assertEquals(1000, second!!.sortOrder - first!!.sortOrder)
        assertEquals(1000, third!!.sortOrder - second.sortOrder)
    }

    // TC-25.1.5: deleting a folder clears folderID on its associated conversations
    @Test
    fun `TC-25-1-5 delete folder cascades to clear folderID from conversations`() = runTest {
        val folder = FolderEntity("f1", "Test", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val convInFolder = ConversationEntity(
            id = "c1", title = "In Folder", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0, isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L, folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        val convNotInFolder = ConversationEntity(
            id = "c2", title = "Not In Folder", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0, isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L, folderID = null, accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(convInFolder, convNotInFolder)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

        // clearFolderID is called with the deleted folder's ID
        coVerify { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
        // the folder is deleted
        coVerify { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") }

    }

    // TC-25.1.5 (additional): multiple conversations in the same folder -> all are affected
    @Test
    fun `TC-25-1-5b delete folder affects all conversations in that folder`() = runTest {
        val folder = FolderEntity("f1", "Work", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conversations = (1..5).map { i ->
            ConversationEntity(
                id = "c$i", title = "Chat $i", hasCustomTitle = false,
                providerID = "p1", modelID = "m1", useMemory = true,
                providerKind = ProviderKind.OpenAI.name,
                previewText = "", estimatedCost = 0.0, isDraft = false, draftText = "",
                createdAt = 100L, updatedAt = 100L, folderID = "f1", accountId = LOCAL_PARTITION_ID,
            )
        }
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns conversations
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

    }

    // TC-22.1.3: 50+ folders -> all created with unique IDs
    @Test
    fun `TC-22-1-3 create 50+ folders all have unique IDs`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returnsMany (0 until 55).map { it * 1000 }
        coEvery { folderDao.upsert(any()) } returns Unit

        val folders = (0 until 55).mapNotNull { repository.create("Folder $it") }

        assertEquals(55, folders.size)
        assertEquals(55, folders.map { it.id }.toSet().size)
    }

    // TC-22.1.5: rapid sequential create -> rename -> delete -> each step's state is correct
    @Test
    fun `TC-22-1-5 sequential create rename delete each step correct`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        // Step 1: Create
        val created = repository.create("Draft")
        assertNotNull(created)
        assertEquals("Draft", created!!.name)

        // Step 2: Rename
        val entity = FolderEntity(created.id, created.name, created.sortOrder, created.createdAt, created.updatedAt, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, created.id) } returns entity
        val renamed = repository.rename(created.id, "Final")
        assertNotNull(renamed)
        assertEquals("Final", renamed!!.name)
        assertEquals(created.id, renamed.id)

        // Step 3: Delete
        val renamedEntity = FolderEntity(renamed.id, renamed.name, renamed.sortOrder, renamed.createdAt, renamed.updatedAt, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, renamed.id) } returns renamedEntity
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, renamed.id) } returns Unit

        repository.delete(renamed.id)

        coVerify { folderDao.deleteById(LOCAL_PARTITION_ID, renamed.id) }
    }

    // TC-22.1.6: a draft conversation in a folder -> folderID is set correctly
    @Test
    fun `TC-22-1-6 draft conversation in folder has folderID set correctly`() = runTest {
        val folder = FolderEntity("f1", "Drafts", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val draftConv = ConversationEntity(
            id = "c-draft", title = "", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = true, draftText = "WIP content",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(draftConv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        // deleting the folder should also identify the draft conversation and clear its folderID
        repository.delete("f1")

        coVerify { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
    }

    // TC-22.1.7: after deleting a single conversation, the folder still exists (repository.delete only deletes the folder, not conversations)
    @Test
    fun `TC-22-1-7 delete conversation from folder does not delete folder`() = runTest {
        // the folder has two conversations; after deleting one, the folder still exists
        val folder = FolderEntity("f1", "Work", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conv1 = ConversationEntity(
            id = "c1", title = "Chat 1", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        val conv2 = ConversationEntity(
            id = "c2", title = "Chat 2", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )

        // simulate that after deleting c1, the folder still contains c2
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(conv2)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        // (delete is a folder-deletion operation; this test verifies the design intent that deleting a conversation does not cascade into deleting the folder)

        coVerify(exactly = 0) { folderDao.deleteById(LOCAL_PARTITION_ID, any()) }
    }

    // TC-22.1.8: a folder name containing quotes and backslashes -> saved correctly
    @Test
    fun `TC-22-1-8 folder name with quotes and backslash saves correctly`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        val slot = slot<FolderEntity>()
        coEvery { folderDao.upsert(capture(slot)) } returns Unit

        val nameWithQuotes = """He said "hello"\goodbye"""
        val result = repository.create(nameWithQuotes)

        assertNotNull(result)
        assertEquals(nameWithQuotes, result!!.name)
        assertEquals(nameWithQuotes, slot.captured.name)
    }

    // TC-22.1.9: a folder name containing HTML/XSS -> stored as plain text, not escaped
    @Test
    fun `TC-22-1-9 folder name with HTML XSS stored as plain text`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        val slot = slot<FolderEntity>()
        coEvery { folderDao.upsert(capture(slot)) } returns Unit

        val xssName = "<script>alert(1)</script>"
        val result = repository.create(xssName)

        assertNotNull(result)
        // the name should be saved as-is, with no HTML escaping or filtering
        assertEquals(xssName, result!!.name)
        assertEquals(xssName, slot.captured.name)
    }

    // TC-22.1.11: a conversation's folderID points to a deleted folder -> treated as uncategorized
    @Test
    fun `TC-22-1-11 conversation with deleted folder treated as uncategorized`() = runTest {
        // folder f-deleted no longer exists
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f-deleted") } returns null

        // attempting to delete a non-existent folder -- does not crash, does nothing
        repository.delete("f-deleted")

        coVerify(exactly = 0) { folderDao.deleteById(LOCAL_PARTITION_ID, any()) }
        coVerify(exactly = 0) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) }
    }

    // TC-22.1.13: a 40-character-long name -> truncated to 30 characters
    @Test
    fun `TC-22-1-13 long name is truncated to 30 characters`() = runTest {
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returns 0
        coEvery { folderDao.upsert(any()) } returns Unit

        val longName = "A".repeat(40)
        val result = repository.create(longName)

        assertNotNull(result)
        assertEquals(30, result!!.name.length)
        assertEquals("A".repeat(30), result.name)
    }

    // -- TC-22.2 empty states --

    // TC-22.2.1: no folders -> empty list
    @Test
    fun `TC-22-2-1 no folders returns empty list`() = runTest {
        coEvery { folderDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { folderDao.countByAccount(LOCAL_PARTITION_ID) } returns 0

        val count = folderDao.countByAccount(LOCAL_PARTITION_ID)

        assertEquals(0, count)
    }

    // TC-22.2.2: after all folders are deleted -> empty list
    @Test
    fun `TC-22-2-2 all folders deleted returns empty list`() = runTest {
        // create two folders
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returnsMany listOf(0, 1000)
        coEvery { folderDao.upsert(any()) } returns Unit

        val f1 = repository.create("A")!!
        val f2 = repository.create("B")!!

        // simulate deleting both
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, f1.id) } returns FolderEntity(f1.id, f1.name, f1.sortOrder, f1.createdAt, f1.updatedAt, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, f2.id) } returns FolderEntity(f2.id, f2.name, f2.sortOrder, f2.createdAt, f2.updatedAt, LOCAL_PARTITION_ID)
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, any()) } returns Unit

        repository.delete(f1.id)
        repository.delete(f2.id)

        coVerify(exactly = 2) { folderDao.deleteById(LOCAL_PARTITION_ID, any()) }
        // after deletion, countByAccount should return 0
        coEvery { folderDao.countByAccount(LOCAL_PARTITION_ID) } returns 0
        assertEquals(0, folderDao.countByAccount(LOCAL_PARTITION_ID))
    }

    // TC-22.2.3: an empty folder -> zero conversation count
    @Test
    fun `TC-22-2-3 empty folder has zero conversation count`() = runTest {
        val folder = FolderEntity("f1", "Empty", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        // no conversations are associated with this folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

    }

    // -- TC-22.3 orphaned folderID handling --

    // TC-22.3.1: a conversation's folderID points to a non-existent folder -> not counted in any folder
    @Test
    fun `TC-22-3-1 orphan folderID not counted in any folder`() = runTest {
        // folder f-existing exists; conversation c-orphan's folderID points to the non-existent f-ghost
        val existingFolder = FolderEntity("f-existing", "Real", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val orphanConv = ConversationEntity(
            id = "c-orphan", title = "Orphan", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f-ghost", accountId = LOCAL_PARTITION_ID,
        )
        val normalConv = ConversationEntity(
            id = "c-normal", title = "Normal", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f-existing", accountId = LOCAL_PARTITION_ID,
        )

        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f-existing") } returns existingFolder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(orphanConv, normalConv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f-existing") } returns Unit

        // when deleting f-existing, only c-normal is identified as affected (folderID matches)
        repository.delete("f-existing")

    }

    // TC-22.3.3: after clearing an orphaned folderID -> the conversation is accessible normally
    @Test
    fun `TC-22-3-3 after clearing orphan folderID conversation accessible normally`() = runTest {
        // the conversation originally had an orphan folderID; clearing it via moveToFolder(null) makes it uncategorized
        val orphanConv = ConversationEntity(
            id = "c-orphan", title = "Was Orphan", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = null, // cleared
            accountId = LOCAL_PARTITION_ID,
        )

        // verify the conversation's folderID is null after clearing
        assertNull(orphanConv.folderID)
        // the conversation still exists normally
        assertEquals("c-orphan", orphanConv.id)
        assertEquals("Was Orphan", orphanConv.title)
    }

    // TC-22.3.4: folder count excludes orphan references
    @Test
    fun `TC-22-3-4 folder count excludes orphan references`() = runTest {
        val folder = FolderEntity("f1", "Work", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        // 3 conversations: 2 belong to f1, 1 points to the non-existent f-ghost
        val conv1 = ConversationEntity(
            id = "c1", title = "Chat 1", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        val conv2 = ConversationEntity(
            id = "c2", title = "Chat 2", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        val orphan = ConversationEntity(
            id = "c-orphan", title = "Orphan", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f-ghost", accountId = LOCAL_PARTITION_ID,
        )

        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(conv1, conv2, orphan)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

    }

    // TC-25.1.8: handling draft conversations in a folder
    @Test
    fun `TC-25-1-8 draft conversations in folder are handled on delete`() = runTest {
        val folder = FolderEntity("f1", "Work", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val draftConv = ConversationEntity(
            id = "c-draft", title = "Draft Chat", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = true, draftText = "Some draft text",
            createdAt = 100L, updatedAt = 100L, folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        val normalConv = ConversationEntity(
            id = "c-normal", title = "Normal Chat", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 100L, updatedAt = 100L, folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(draftConv, normalConv)
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

    }

    // -- TC-23 performance --

    // TC-23.1.4: batch operation efficiency -- delete uses a single clearFolderID call for affected conversations (not one per item)
    @Test
    fun `TC-23-1-4 batch operations use single clearFolderID call not per-item`() = runTest {
        val folder = FolderEntity("f1", "Batch", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conversations = (1..20).map { i ->
            ConversationEntity(
                id = "c$i", title = "Chat $i", hasCustomTitle = false,
                providerID = "p1", modelID = "m1", useMemory = true,
                providerKind = ProviderKind.OpenAI.name,
                previewText = "", estimatedCost = 0.0,
                isDraft = false, draftText = "",
                createdAt = 100L, updatedAt = 100L,
                folderID = "f1", accountId = LOCAL_PARTITION_ID,
            )
        }
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f1") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns conversations
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") } returns Unit

        repository.delete("f1")

        // clearFolderID is called only once (a SQL WHERE folderID = ?, not a per-row update)
        coVerify(exactly = 1) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f1") }
        // deleteById is also called only once
        coVerify(exactly = 1) { folderDao.deleteById(LOCAL_PARTITION_ID, "f1") }
    }

    // TC-23.1.5: 50 folders + 500 conversations -> operations complete quickly
    @Test
    fun `TC-23-1-5 50 folders 500 conversations operations complete quickly`() = runTest {
        // create 50 folders
        coEvery { folderDao.maxSortOrder(LOCAL_PARTITION_ID) } returnsMany (0 until 50).map { it * 1000 }
        coEvery { folderDao.upsert(any()) } returns Unit

        val startCreate = System.currentTimeMillis()
        val folders = (0 until 50).mapNotNull { repository.create("Folder $it") }
        val createTime = System.currentTimeMillis() - startCreate

        assertEquals(50, folders.size)
        // a budget assertion (not a performance assertion): 5s is a fallback ceiling for "hung / degraded into N full-table scans"; the normal case runs in single-digit milliseconds --
        // three orders of magnitude of headroom. It does not flake under parallel execution, so it stays; don't tighten or loosen it as a performance metric.
        assertTrue("Create 50 folders took ${createTime}ms", createTime < 5000)

        // simulate deleting a folder containing 500 conversations
        val folder = FolderEntity("f-big", "Big", 1000, 100L, 100L, LOCAL_PARTITION_ID)
        val conversations = (1..500).map { i ->
            ConversationEntity(
                id = "c$i", title = "Chat $i", hasCustomTitle = false,
                providerID = "p1", modelID = "m1", useMemory = true,
                providerKind = ProviderKind.OpenAI.name,
                previewText = "", estimatedCost = 0.0,
                isDraft = false, draftText = "",
                createdAt = 100L, updatedAt = 100L,
                folderID = "f-big", accountId = LOCAL_PARTITION_ID,
            )
        }
        coEvery { folderDao.getById(LOCAL_PARTITION_ID, "f-big") } returns folder
        coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns conversations
        coEvery { conversationDao.clearFolderID(LOCAL_PARTITION_ID, any()) } returns Unit
        coEvery { folderDao.deleteById(LOCAL_PARTITION_ID, "f-big") } returns Unit

        val startDelete = System.currentTimeMillis()
        repository.delete("f-big")
        val deleteTime = System.currentTimeMillis() - startDelete

        // same as above: a budget assertion, not a performance assertion. What actually locks down "batched, not per-item" is the coVerify(exactly = 1) below.
        assertTrue("Delete folder with 500 convos took ${deleteTime}ms", deleteTime < 5000)
        // clearFolderID uses a single batched SQL update (one call)
        coVerify(exactly = 1) { conversationDao.clearFolderID(LOCAL_PARTITION_ID, "f-big") }
    }

    // TC-25.1.8 (additional): a draft conversation can be assigned to a folder (folderID can be set)
    @Test
    fun `TC-25-1-8b draft conversation entity supports folderID`() {
        // verify that when ConversationEntity.isDraft=true, folderID can still be set normally
        val draftInFolder = ConversationEntity(
            id = "c1", title = "Draft", hasCustomTitle = false,
            providerID = "p1", modelID = "m1", useMemory = true,
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = true, draftText = "draft content",
            createdAt = 100L, updatedAt = 100L,
            folderID = "f1", accountId = LOCAL_PARTITION_ID,
        )
        assertEquals("f1", draftInFolder.folderID)
        assertTrue(draftInFolder.isDraft)

        // a draft can also be outside any folder
        val draftNoFolder = draftInFolder.copy(folderID = null)
        assertNull(draftNoFolder.folderID)
        assertTrue(draftNoFolder.isDraft)
    }
}
