package ai.oriveo.community.feature.notes

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.notes.NoteSort
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


@OptIn(ExperimentalCoroutinesApi::class)
class NotesViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val activeFlow = MutableStateFlow<List<Note>>(emptyList())
    private val foldersFlow = MutableStateFlow<List<NoteFolder>>(emptyList())
    private val trashFlow = MutableStateFlow<List<Note>>(emptyList())

    private lateinit var noteRepository: NoteRepository
    private lateinit var snackbar: GlobalSnackbarManager
    private lateinit var appPreferences: AppPreferencesRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)

        noteRepository = mockk(relaxed = true)
        every { noteRepository.observeActive() } returns activeFlow
        every { noteRepository.observeFolders() } returns foldersFlow
        every { noteRepository.observeTrash() } returns trashFlow

        snackbar = mockk(relaxed = true)

        appPreferences = mockk(relaxed = true)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun createViewModel() = NotesViewModel(noteRepository, snackbar, appPreferences)

    private fun note(
        id: String,
        title: String = id,
        tags: List<String> = emptyList(),
        folder: String? = null,
        updatedAt: String = "2026-06-01T00:00:00Z",
        createdAt: String = "2026-06-01T00:00:00Z",
    ) = Note(
        id = id,
        title = title,
        body = "b",
        tags = tags,
        noteFolderID = folder,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    private fun folder(id: String, name: String = id, sortOrder: Int = 1000) = NoteFolder(
        id = id,
        name = name,
        sortOrder = sortOrder,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
    )

    

    @Test
    fun `empty query lists via NoteListing without searchNotes`() = runTest {
        activeFlow.value = listOf(note("a"), note("b"))
        val vm = createViewModel()
        val out = mutableListOf<List<Note>>()
        val job = backgroundScope.launch { vm.displayedNotes.collect { out += it } }
        advanceUntilIdle()

        assertEquals(setOf("a", "b"), out.last().map { it.id }.toSet())
        coVerify(exactly = 0) { noteRepository.searchNotes(any(), any(), any(), any()) }
        job.cancel()
    }

    @Test
    fun `non-empty query lists via searchNotes`() = runTest {
        activeFlow.value = listOf(note("a"))
        coEvery {
            noteRepository.searchNotes("foo", null, emptyList(), NoteSort.UpdatedAt)
        } returns listOf(note("hit"))
        val vm = createViewModel()
        val out = mutableListOf<List<Note>>()
        val job = backgroundScope.launch { vm.displayedNotes.collect { out += it } }
        vm.setQuery("foo")
        advanceUntilIdle()

        assertEquals(listOf("hit"), out.last().map { it.id })
        coVerify { noteRepository.searchNotes("foo", null, emptyList(), NoteSort.UpdatedAt) }
        job.cancel()
    }

    

    @Test
    fun `setQuery resets paging`() = runTest {
        val vm = createViewModel()
        vm.showMore()
        assertEquals(NotesViewModel.PAGE_SIZE * 2, vm.visibleCount)
        vm.setQuery("x")
        assertEquals(NotesViewModel.PAGE_SIZE, vm.visibleCount)
    }

    @Test
    fun `setSort resets paging and updates sort`() = runTest {
        val vm = createViewModel()
        vm.showMore()
        val other = NoteSort.entries.firstOrNull { it != vm.sort.value } ?: vm.sort.value
        vm.setSort(other)
        assertEquals(NotesViewModel.PAGE_SIZE, vm.visibleCount)
        assertEquals(other, vm.sort.value)
    }

    @Test
    fun `selectFolder clears selected tags and resets paging`() = runTest {
        val vm = createViewModel()
        vm.toggleTag("t1")
        vm.showMore()
        vm.selectFolder("f")
        assertTrue(vm.selectedTags.value.isEmpty())
        assertEquals(NotesViewModel.PAGE_SIZE, vm.visibleCount)
        assertEquals("f", vm.selectedFolderId.value)
    }

    @Test
    fun `toggleTag adds then removes`() = runTest {
        val vm = createViewModel()
        vm.toggleTag("a")
        assertEquals(listOf("a"), vm.selectedTags.value)
        vm.toggleTag("a")
        assertTrue(vm.selectedTags.value.isEmpty())
    }

    @Test
    fun `clearTags removes all and resets paging`() = runTest {
        val vm = createViewModel()
        vm.toggleTag("a")
        vm.toggleTag("b")
        vm.showMore()
        vm.clearTags()
        assertTrue(vm.selectedTags.value.isEmpty())
        assertEquals(NotesViewModel.PAGE_SIZE, vm.visibleCount)
    }

    @Test
    fun `showMore increments visibleCount`() = runTest {
        val vm = createViewModel()
        val before = vm.visibleCount
        vm.showMore()
        assertEquals(before + NotesViewModel.PAGE_SIZE, vm.visibleCount)
    }

    @Test
    fun `selectTab switches tab`() = runTest {
        val vm = createViewModel()
        vm.selectTab(NotesViewModel.Tab.Trash)
        assertEquals(NotesViewModel.Tab.Trash, vm.tab)
    }

    

    @Test
    fun `createBlankNote uses current folder and callbacks new id`() = runTest {
        val vm = createViewModel()
        vm.selectFolder("f1")
        coEvery { noteRepository.createBlankNote(folderId = "f1") } returns note("new-id")
        var created: String? = null
        vm.createBlankNote { created = it }
        advanceUntilIdle()

        assertEquals("new-id", created)
        coVerify { noteRepository.createBlankNote(folderId = "f1") }
    }

    @Test
    fun `createBlankNote from uncategorized filter does not persist the filter sentinel`() = runTest {
        val vm = createViewModel()
        vm.selectFolder(NotesViewModel.UNCATEGORIZED)
        coEvery { noteRepository.createBlankNote(folderId = null) } returns note("uncategorized-id")
        var created: String? = null
        vm.createBlankNote { created = it }
        advanceUntilIdle()

        assertEquals("uncategorized-id", created)
        coVerify { noteRepository.createBlankNote(folderId = null) }
    }

    @Test
    fun `createFolder shows snackbar on success`() = runTest {
        val vm = createViewModel()
        coEvery { noteRepository.createFolder("F") } returns folder("fid", name = "F")
        vm.createFolder("F")
        advanceUntilIdle()
        verify { snackbar.show(any()) }
    }

    @Test
    fun `createFolder shows no snackbar when repo returns null`() = runTest {
        val vm = createViewModel()
        coEvery { noteRepository.createFolder("F") } returns null
        vm.createFolder("F")
        advanceUntilIdle()
        verify(exactly = 0) { snackbar.show(any()) }
    }

    @Test
    fun `softDeleteNote soft-deletes and shows undo snackbar`() = runTest {
        val vm = createViewModel()
        val slot = slot<GlobalSnackbarMessage>()
        every { snackbar.show(capture(slot)) } just runs
        vm.softDeleteNote("n1")
        advanceUntilIdle()

        coVerify { noteRepository.softDeleteNote("n1") }
        assertNotNull(slot.captured.action)
        assertEquals(5000L, slot.captured.durationMs)
    }

    @Test
    fun `restoreNote restores and shows snackbar`() = runTest {
        val vm = createViewModel()
        vm.restoreNote("n1")
        advanceUntilIdle()
        coVerify { noteRepository.restoreNote("n1") }
        verify { snackbar.show(any()) }
    }

    @Test
    fun `emptyTrash empties and shows snackbar`() = runTest {
        val vm = createViewModel()
        vm.emptyTrash()
        advanceUntilIdle()
        coVerify { noteRepository.emptyTrash() }
        verify { snackbar.show(any()) }
    }

    @Test
    fun `deleteFolder returns to All when deleting the selected folder`() = runTest {
        val vm = createViewModel()
        vm.selectFolder("f1")
        assertEquals("f1", vm.selectedFolderId.value)
        vm.deleteFolder("f1")
        advanceUntilIdle()

        assertNull(vm.selectedFolderId.value)
        coVerify { noteRepository.deleteFolder("f1") }
    }

    @Test
    fun `deleteFolder keeps selection when deleting a different folder`() = runTest {
        val vm = createViewModel()
        vm.selectFolder("a")
        vm.deleteFolder("b")
        advanceUntilIdle()

        assertEquals("a", vm.selectedFolderId.value)
        coVerify { noteRepository.deleteFolder("b") }
    }

    @Test
    fun `moveNoteToFolder delegates to repo`() = runTest {
        val vm = createViewModel()
        vm.moveNoteToFolder("n1", "f1")
        advanceUntilIdle()
        coVerify { noteRepository.moveToFolder("n1", "f1") }
    }

    

    @Test
    fun `folders are sorted by sortOrder`() = runTest {
        foldersFlow.value = listOf(folder("b", sortOrder = 2000), folder("a", sortOrder = 1000))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.folders.collect {} }
        advanceUntilIdle()
        assertEquals(listOf("a", "b"), vm.folders.value.map { it.id })
        job.cancel()
    }

    @Test
    fun `trashedNotes are sorted by updatedAt descending`() = runTest {
        trashFlow.value = listOf(
            note("old", updatedAt = "2026-01-01T00:00:00Z"),
            note("new", updatedAt = "2026-06-01T00:00:00Z"),
        )
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.trashedNotes.collect {} }
        advanceUntilIdle()
        assertEquals(listOf("new", "old"), vm.trashedNotes.value.map { it.id })
        job.cancel()
    }

    @Test
    fun `uncategorizedCount counts notes without folder`() = runTest {
        activeFlow.value = listOf(note("a"), note("b", folder = "f1"), note("c"))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.uncategorizedCount.collect {} }
        advanceUntilIdle()
        assertEquals(2, vm.uncategorizedCount.value)
        job.cancel()
    }

    

    @Test
    fun `displayedTrash with empty query returns all trashed notes`() = runTest {
        trashFlow.value = listOf(
            note("old", updatedAt = "2026-01-01T00:00:00Z"),
            note("new", updatedAt = "2026-06-01T00:00:00Z"),
        )
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.displayedTrash.collect {} }
        advanceUntilIdle()
        
        assertEquals(listOf("new", "old"), vm.displayedTrash.value.map { it.id })
        job.cancel()
    }

    @Test
    fun `displayedTrash filters trashed notes by query case-insensitively`() = runTest {
        trashFlow.value = listOf(
            note("a", title = "Grocery list"),
            note("b", title = "Meeting notes"),
            note("c", title = "Grocery budget"),
        )
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.displayedTrash.collect {} }
        vm.setQuery("grocery")
        advanceUntilIdle()
        assertEquals(setOf("a", "c"), vm.displayedTrash.value.map { it.id }.toSet())
        job.cancel()
    }

    @Test
    fun `displayedTrash matches by tag`() = runTest {
        trashFlow.value = listOf(
            note("a", title = "x", tags = listOf("work")),
            note("b", title = "y", tags = listOf("home")),
        )
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.displayedTrash.collect {} }
        vm.setQuery("work")
        advanceUntilIdle()
        assertEquals(listOf("a"), vm.displayedTrash.value.map { it.id })
        job.cancel()
    }
}
