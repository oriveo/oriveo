package ai.oriveo.community.feature.notes

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.NoteFolder
import ai.oriveo.community.core.model.Provider
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
import io.mockk.every
import io.mockk.mockk
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


@OptIn(ExperimentalCoroutinesApi::class)
class NoteDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val noteFlow = MutableStateFlow<Note?>(null)
    private val activeNotesFlow = MutableStateFlow<List<Note>>(emptyList())
    private val foldersFlow = MutableStateFlow<List<NoteFolder>>(emptyList())
    private val providersFlow = MutableStateFlow<List<Provider>>(emptyList())

    private lateinit var noteRepository: NoteRepository
    private lateinit var providerRepository: ProviderRepository
    private lateinit var appPreferencesRepository: AppPreferencesRepository
    private lateinit var snackbar: GlobalSnackbarManager

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)

        noteRepository = mockk(relaxed = true)
        every { noteRepository.observeNote(any()) } returns noteFlow
        every { noteRepository.observeActive() } returns activeNotesFlow
        every { noteRepository.observeFolders() } returns foldersFlow

        providerRepository = mockk(relaxed = true)
        every { providerRepository.observeAll() } returns providersFlow

        appPreferencesRepository = mockk(relaxed = true)
        every { appPreferencesRepository.language } returns MutableStateFlow(LanguageOption.System)
        coEvery { appPreferencesRepository.getLanguage() } returns LanguageOption.System

        snackbar = mockk(relaxed = true)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun createViewModel(noteId: String = "11111111-1111-1111-1111-111111111111"): NoteDetailViewModel {
        val handle = SavedStateHandle(mapOf("noteID" to noteId))
        return NoteDetailViewModel(handle, noteRepository, providerRepository, appPreferencesRepository, snackbar)
    }

    private fun note(
        id: String,
        tags: List<String> = emptyList(),
        sourceConversationId: String? = null,
    ) = Note(
        id = id,
        title = "t",
        body = "b",
        tags = tags,
        sourceConversationId = sourceConversationId,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
    )

    private fun folder(
        id: String,
        sortOrder: Int = 1000,
        name: String = id,
        colorTag: String? = null,
    ) = NoteFolder(
        id = id,
        name = name,
        colorTag = colorTag,
        sortOrder = sortOrder,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
    )

    // ── CRUD delegate ──

    @Test
    fun `updateTitle delegates to repo`() = runTest {
        val vm = createViewModel()
        vm.updateTitle("New")
        advanceUntilIdle()
        coVerify { noteRepository.updateTitle(vm.noteID, "New") }
    }

    @Test
    fun `updateBody delegates to repo`() = runTest {
        val vm = createViewModel()
        vm.updateBody("Body")
        advanceUntilIdle()
        coVerify { noteRepository.updateBody(vm.noteID, "Body") }
    }

    @Test
    fun `moveToFolder delegates to repo`() = runTest {
        val vm = createViewModel()
        vm.moveToFolder("f1")
        advanceUntilIdle()
        coVerify { noteRepository.moveToFolder(vm.noteID, "f1") }
    }

    @Test
    fun `createFolderAndMoveToIt creates folder with color then moves current note`() = runTest {
        coEvery { noteRepository.createFolder("Ideas", "green") } returns folder(
            id = "folder-created",
            name = "Ideas",
            colorTag = "green",
        )
        val vm = createViewModel()

        vm.createFolderAndMoveToIt("Ideas", "green")
        advanceUntilIdle()

        coVerifyOrder {
            noteRepository.createFolder("Ideas", "green")
            noteRepository.moveToFolder(vm.noteID, "folder-created")
        }
    }

    @Test
    fun `setPinned delegates to repo`() = runTest {
        val vm = createViewModel()
        vm.setPinned(true)
        advanceUntilIdle()
        coVerify { noteRepository.pinNote(vm.noteID, true) }
    }

    @Test
    fun `discardEmptyBlankNote delegates to repo before done callback`() = runTest {
        val vm = createViewModel()
        var done = false
        vm.discardEmptyBlankNoteIfNeeded { done = true }
        advanceUntilIdle()
        coVerify { noteRepository.discardEmptyBlankNoteIfNeeded(vm.noteID) }
        assertTrue(done)
    }

    

    @Test
    fun `addTag appends trimmed tag to existing`() = runTest {
        noteFlow.value = note("ID", tags = listOf("a"))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.note.collect {} }
        advanceUntilIdle()

        vm.addTag("  b  ")
        advanceUntilIdle()
        coVerify { noteRepository.updateTags(vm.noteID, listOf("a", "b")) }
        job.cancel()
    }

    @Test
    fun `addTag ignores case-insensitive duplicate`() = runTest {
        noteFlow.value = note("ID", tags = listOf("Tag"))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.note.collect {} }
        advanceUntilIdle()

        vm.addTag("tag")
        advanceUntilIdle()
        coVerify(exactly = 0) { noteRepository.updateTags(any(), any()) }
        job.cancel()
    }

    @Test
    fun `availableTags excludes current note tags`() = runTest {
        noteFlow.value = note("ID", tags = listOf("Vector"))
        activeNotesFlow.value = listOf(
            note("ID", tags = listOf("Vector")),
            note("OTHER", tags = listOf("vector", "compose", "Research")),
        )
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.availableTags.collect {} }
        advanceUntilIdle()

        assertEquals(listOf("compose", "Research"), vm.availableTags.value)
        job.cancel()
    }

    @Test
    fun `addTag ignores blank`() = runTest {
        val vm = createViewModel()
        vm.addTag("   ")
        advanceUntilIdle()
        coVerify(exactly = 0) { noteRepository.updateTags(any(), any()) }
    }

    @Test
    fun `removeTag removes from existing`() = runTest {
        noteFlow.value = note("ID", tags = listOf("a", "b"))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.note.collect {} }
        advanceUntilIdle()

        vm.removeTag("a")
        advanceUntilIdle()
        coVerify { noteRepository.updateTags(vm.noteID, listOf("b")) }
        job.cancel()
    }

    

    @Test
    fun `softDelete deletes shows snackbar and invokes onDone`() = runTest {
        val vm = createViewModel()
        var done = false
        vm.softDelete { done = true }
        advanceUntilIdle()

        coVerify { noteRepository.softDeleteNote(vm.noteID) }
        verify { snackbar.show(any()) }
        assertTrue(done)
    }

    @Test
    fun `restore restores and shows snackbar`() = runTest {
        val vm = createViewModel()
        vm.restore()
        advanceUntilIdle()
        coVerify { noteRepository.restoreNote(vm.noteID) }
        verify { snackbar.show(any()) }
    }

    

    @Test
    fun `openCrosscheck activates and closeCrosscheck deactivates`() = runTest {
        val vm = createViewModel()
        assertFalse(vm.crosscheckActive)
        vm.openCrosscheck()
        assertTrue(vm.crosscheckActive)
        vm.closeCrosscheck()
        assertFalse(vm.crosscheckActive)
    }

    

    @Test
    fun `folders sorted by sortOrder`() = runTest {
        foldersFlow.value = listOf(folder("b", 2000), folder("a", 1000))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.folders.collect {} }
        advanceUntilIdle()
        assertEquals(listOf("a", "b"), vm.folders.value.map { it.id })
        job.cancel()
    }

    @Test
    fun `note reflects observeNote`() = runTest {
        noteFlow.value = note("ID", tags = listOf("x"))
        val vm = createViewModel()
        val job = backgroundScope.launch { vm.note.collect {} }
        advanceUntilIdle()
        assertEquals(listOf("x"), vm.note.value?.tags)
        job.cancel()
    }

}
