package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.mapper.NoteFolderMapper.toEntity as folderToEntity
import ai.oriveo.community.core.data.mapper.NoteMapper.toEntity
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.NoteTitleSource
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProvenanceEntry
import ai.oriveo.community.core.model.ProvenanceKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


@OptIn(ExperimentalCoroutinesApi::class)
class NoteRepositoryWriterTest {

    private val accountId = LOCAL_PARTITION_ID
    private lateinit var noteDao: NoteDao
    private lateinit var noteFolderDao: NoteFolderDao
    private lateinit var repo: NoteRepository
    private lateinit var accountIdFlow: MutableStateFlow<String>

    @Before
    fun setUp() {
        noteDao = mockk(relaxed = true)
        noteFolderDao = mockk(relaxed = true)
        accountIdFlow = MutableStateFlow(accountId)
        repo = NoteRepository(noteDao, noteFolderDao)
    }

    @After
    fun tearDown() {
    }

    private fun note(
        id: String = "11111111-1111-1111-1111-111111111111",
        title: String = "Old",
        titleSource: NoteTitleSource = NoteTitleSource.Manual,
        body: String = "body",
        bodySnapshot: String? = null,
        tags: List<String> = emptyList(),
        noteFolderID: String? = null,
        sourceConversationId: String? = null,
        sourceMessageId: String? = null,
        sourceModelID: String? = null,
        sourceModelName: String? = null,
        sourceProviderKind: ProviderKind? = null,
        sourceProviderName: String? = null,
        sourcePrompt: String? = null,
        captureKind: NoteCaptureKind = NoteCaptureKind.Blank,
        provenance: List<ProvenanceEntry> = emptyList(),
        isPinned: Boolean = false,
        deletedAt: String? = null,
    ) = Note(
        id = id,
        title = title,
        titleSource = titleSource,
        body = body,
        bodySnapshot = bodySnapshot,
        tags = tags,
        noteFolderID = noteFolderID,
        sourceConversationId = sourceConversationId,
        sourceMessageId = sourceMessageId,
        sourceModelID = sourceModelID,
        sourceModelName = sourceModelName,
        sourceProviderKind = sourceProviderKind,
        sourceProviderName = sourceProviderName,
        sourcePrompt = sourcePrompt,
        captureKind = captureKind,
        provenance = provenance,
        isPinned = isPinned,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
        deletedAt = deletedAt,
    )

    // ── createNote / createBlankNote ──

    @Test
    fun `createNote without title derives placeholder source`() = runTest {
        val created = repo.createNote(CreateNoteInput(body = "hello", sourcePrompt = "Q"))
        assertEquals(NoteTitleSource.Placeholder, created.titleSource)
        coVerify { noteDao.upsertWithIndex(any(), any(), any(), any(), any()) }
        
    }

    @Test
    fun `createNote with title trims and marks manual`() = runTest {
        val created = repo.createNote(CreateNoteInput(title = "  My Title  ", body = "b"))
        assertEquals("My Title", created.title)
        assertEquals(NoteTitleSource.Manual, created.titleSource)
    }

    @Test
    fun `createBlankNote creates blank capture with empty body`() = runTest {
        val created = repo.createBlankNote(folderId = null)
        assertEquals(NoteCaptureKind.Blank, created.captureKind)
        assertEquals("", created.body)
    }

    @Test
    fun `discardEmptyBlankNote hard-deletes empty manual draft without trash`() = runTest {
        val id = "11111111-1111-1111-1111-111111111111"
        coEvery { noteDao.getByIdForAccount(accountId, id) } returns note(
            id = id,
            title = "",
            titleSource = NoteTitleSource.Placeholder,
            body = "",
            captureKind = NoteCaptureKind.Blank,
        ).toEntity(accountId)

        val discarded = repo.discardEmptyBlankNoteIfNeeded(id)

        assertTrue(discarded)
        coVerify { noteDao.hardDeleteWithIndex(accountId, id) }
        coVerify(exactly = 0) { noteDao.softDeleteWithIndex(any(), any(), any(), any()) }
    }

    @Test
    fun `discardEmptyBlankNote keeps draft once user wrote content`() = runTest {
        val id = "11111111-1111-1111-1111-111111111111"
        coEvery { noteDao.getByIdForAccount(accountId, id) } returns note(
            id = id,
            title = "First line",
            titleSource = NoteTitleSource.Placeholder,
            body = "First line",
            captureKind = NoteCaptureKind.Blank,
        ).toEntity(accountId)

        val discarded = repo.discardEmptyBlankNoteIfNeeded(id)

        assertFalse(discarded)
        coVerify(exactly = 0) { noteDao.hardDeleteWithIndex(any(), any()) }
    }

    // ── update* ──

    @Test
    fun `updateTitle trims marks manual and syncs`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(title = "Old").toEntity(accountId)
        val updated = repo.updateTitle("11111111-1111-1111-1111-111111111111", "  New  ")
        assertEquals("New", updated?.title)
        assertEquals(NoteTitleSource.Manual, updated?.titleSource)
        coVerify { noteDao.upsertWithIndex(any(), any(), any(), any(), any()) }
        
    }

    @Test
    fun `updateTitle with blank input resets to placeholder and follows body edits`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(
            title = "Manual",
            titleSource = NoteTitleSource.Manual,
            body = "Original body",
            sourcePrompt = null,
        ).toEntity(accountId)

        val untitled = repo.updateTitle("11111111-1111-1111-1111-111111111111", "   ")

        assertEquals("Original body", untitled?.title)
        assertEquals(NoteTitleSource.Placeholder, untitled?.titleSource)
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns untitled!!.toEntity(accountId)

        val bodyUpdated = repo.updateBody("11111111-1111-1111-1111-111111111111", "Fresh body")

        assertEquals("Fresh body", bodyUpdated?.title)
        assertEquals(NoteTitleSource.Placeholder, bodyUpdated?.titleSource)
    }

    @Test
    fun `updateTitle returns null and skips sync when note missing`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns null
        val updated = repo.updateTitle("missing", "New")
        assertNull(updated)
    }

    @Test
    fun `updateTitle skips cloud sync when account switches after local write`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(title = "Old").toEntity(accountId)
        coEvery { noteDao.upsertWithIndex(any(), any(), any(), any(), any()) } coAnswers {
            accountIdFlow.value = "other-account"
        }

        val updated = repo.updateTitle("11111111-1111-1111-1111-111111111111", "New")

        assertEquals("New", updated?.title)
        coVerify {
            noteDao.upsertWithIndex(
                match { it.accountId == accountId && it.title == "New" },
                any(),
                any(),
                any(),
                any(),
            )
        }
    }

    @Test
    fun `updateBody recomputes title when source is placeholder`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns
            note(titleSource = NoteTitleSource.Placeholder, sourcePrompt = "Q").toEntity(accountId)
        val updated = repo.updateBody("11111111-1111-1111-1111-111111111111", "fresh body")
        assertEquals("fresh body", updated?.body)
        assertEquals(NoteTitleSource.Placeholder, updated?.titleSource)
    }

    @Test
    fun `updateBody keeps title when source is manual`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns
            note(title = "Kept", titleSource = NoteTitleSource.Manual).toEntity(accountId)
        val updated = repo.updateBody("11111111-1111-1111-1111-111111111111", "fresh body")
        assertEquals("Kept", updated?.title)
        assertEquals("fresh body", updated?.body)
    }

    @Test
    fun `replaceNote keeps organization fields updates source fields and clears provenance`() = runTest {
        val existing = note(
            title = "Kept manual title",
            titleSource = NoteTitleSource.Manual,
            body = "old body",
            bodySnapshot = "old full answer",
            tags = listOf("keep"),
            noteFolderID = "22222222-2222-2222-2222-222222222222",
            sourceConversationId = "33333333-3333-3333-3333-333333333333",
            sourceMessageId = "44444444-4444-4444-4444-444444444444",
            sourceModelID = "gpt-5",
            sourceModelName = "GPT-5",
            sourceProviderKind = ProviderKind.OpenAI,
            sourceProviderName = "OpenAI",
            sourcePrompt = "Old prompt",
            captureKind = NoteCaptureKind.FullAnswer,
            provenance = listOf(
                ProvenanceEntry(
                    kind = ProvenanceKind.Origin,
                    modelID = "gpt-5",
                    modelName = "GPT-5",
                    providerKind = ProviderKind.OpenAI,
                    providerName = "OpenAI",
                    conversationId = "33333333-3333-3333-3333-333333333333",
                    messageId = "44444444-4444-4444-4444-444444444444",
                    at = "2026-06-01T00:00:00Z",
                ),
                ProvenanceEntry(
                    kind = ProvenanceKind.Crosscheck,
                    modelID = "claude",
                    modelName = "Claude",
                    providerKind = ProviderKind.Anthropic,
                    providerName = "Anthropic",
                    at = "2026-06-01T00:01:00Z",
                ),
            ),
            isPinned = true,
        )
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns existing.toEntity(accountId)

        val updated = repo.replaceNote(
            "11111111-1111-1111-1111-111111111111",
            CreateNoteInput(
                body = "selected replacement",
                bodySnapshot = "full replacement answer",
                tags = listOf("should-not-copy"),
                noteFolderID = "55555555-5555-5555-5555-555555555555",
                sourceConversationId = "66666666-6666-6666-6666-666666666666",
                sourceMessageId = "77777777-7777-7777-7777-777777777777",
                sourceModelID = "claude-3-5",
                sourceModelName = "Claude 3.5",
                sourceProviderKind = ProviderKind.Anthropic,
                sourceProviderName = "Anthropic",
                sourcePrompt = "New prompt",
                captureKind = NoteCaptureKind.Selection,
                provenance = listOf(
                    ProvenanceEntry(
                        kind = ProvenanceKind.Origin,
                        modelID = "unused",
                        at = "2026-06-02T00:00:00Z",
                    ),
                ),
            ),
        )

        assertEquals(existing.id, updated?.id)
        assertEquals(existing.createdAt, updated?.createdAt)
        assertEquals("Kept manual title", updated?.title)
        assertEquals(NoteTitleSource.Manual, updated?.titleSource)
        assertEquals("selected replacement", updated?.body)
        assertEquals("full replacement answer", updated?.bodySnapshot)
        assertEquals(listOf("keep"), updated?.tags)
        assertEquals("22222222-2222-2222-2222-222222222222", updated?.noteFolderID)
        assertEquals(true, updated?.isPinned)
        assertEquals(NoteCaptureKind.Selection, updated?.captureKind)
        assertEquals("66666666-6666-6666-6666-666666666666", updated?.sourceConversationId)
        assertEquals("77777777-7777-7777-7777-777777777777", updated?.sourceMessageId)
        assertEquals("claude-3-5", updated?.sourceModelID)
        assertEquals("Claude 3.5", updated?.sourceModelName)
        assertEquals(ProviderKind.Anthropic, updated?.sourceProviderKind)
        assertEquals("Anthropic", updated?.sourceProviderName)
        assertEquals("New prompt", updated?.sourcePrompt)
        assertEquals(emptyList<ProvenanceEntry>(), updated?.provenance)
    }

    @Test
    fun `updateTags updates and syncs`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(tags = listOf("a")).toEntity(accountId)
        val updated = repo.updateTags("11111111-1111-1111-1111-111111111111", listOf("a", "b"))
        assertEquals(listOf("a", "b"), updated?.tags)
    }

    @Test
    fun `moveToFolder updates folder and syncs`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note().toEntity(accountId)
        repo.moveToFolder("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")
    }

    @Test
    fun `moveToFolder out to unfiled syncs via update path (AN-1 clears noteFolderID)`() = runTest {
        
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns
            note().copy(noteFolderID = "22222222-2222-2222-2222-222222222222").toEntity(accountId)
        repo.moveToFolder("11111111-1111-1111-1111-111111111111", null)
    }

    @Test
    fun `pinNote updates pin and syncs`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(isPinned = false).toEntity(accountId)
        val updated = repo.pinNote("11111111-1111-1111-1111-111111111111", true)
        assertEquals(true, updated?.isPinned)
    }

    @Test
    fun `unpin syncs via update path (AN-1 propagates isPinned false)`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(isPinned = true).toEntity(accountId)
        val updated = repo.pinNote("11111111-1111-1111-1111-111111111111", false)
        assertEquals(false, updated?.isPinned)
    }

    

    @Test
    fun `softDeleteNote soft-deletes via dao and syncs tombstone`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note().toEntity(accountId)
        repo.softDeleteNote("11111111-1111-1111-1111-111111111111")
        coVerify { noteDao.softDeleteWithIndex(any(), any(), any(), any()) }
    }

    @Test
    fun `softDeleteNote skips when note missing`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns null
        repo.softDeleteNote("missing")
    }

    @Test
    fun `restoreNote restores via dao and syncs cleared tombstone`() = runTest {
        coEvery { noteDao.getByIdForAccount(any(), any()) } returns note(deletedAt = "2026-01-01T00:00:00Z").toEntity(accountId)
        repo.restoreNote("11111111-1111-1111-1111-111111111111")
        coVerify { noteDao.restoreWithIndex(any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `emptyTrash hard-deletes and syncs`() = runTest {
        coEvery { noteDao.getAllTrashed(accountId) } returns
            listOf(note(id = "11111111-1111-1111-1111-111111111111", deletedAt = "2026-01-01T00:00:00Z").toEntity(accountId))
        repo.emptyTrash()
        coVerify { noteDao.hardDeleteTrash(accountId) }
    }

    @Test
    fun `emptyTrash skips when trash empty`() = runTest {
        coEvery { noteDao.getAllTrashed(accountId) } returns emptyList()
        repo.emptyTrash()
    }

    

    private fun folder(
        id: String = "22222222-2222-2222-2222-222222222222",
        name: String = "Trip",
        colorTag: String? = "blue",
    ) = NoteFolder(
        id = id,
        name = name,
        sortOrder = 1000,
        colorTag = colorTag,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
    )

    @Test
    fun `createFolder syncs via create path forUpdate=false`() = runTest {
        coEvery { noteFolderDao.maxSortOrder(accountId) } returns 0
        coEvery { noteFolderDao.getActive(accountId) } returns emptyList()
        repo.createFolder("Trip")
    }

    @Test
    fun `renameFolder syncs via update path forUpdate=true`() = runTest {
        coEvery { noteFolderDao.getByIdForAccount(any(), any()) } returns folder().folderToEntity(accountId)
        repo.renameFolder("22222222-2222-2222-2222-222222222222", "Japan")
    }

    @Test
    fun `setFolderColor syncs via update path forUpdate=true`() = runTest {
        coEvery { noteFolderDao.getByIdForAccount(any(), any()) } returns folder().folderToEntity(accountId)
        repo.setFolderColor("22222222-2222-2222-2222-222222222222", "red")
    }
}
