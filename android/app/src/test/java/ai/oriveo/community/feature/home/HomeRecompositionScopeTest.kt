package ai.oriveo.community.feature.home

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.entity.NoteSummary
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.FolderRepository
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
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

/**
 * Regression locks that keep the home screen's recomposition scope narrow.
 *
 * Each one guards a direct cause of "the main thread keeps being woken up on the first frame or
 * while a reply is streaming":
 *
 * 1. **List derivations stay off the main thread** -- the filter / associateBy / groupBy behind
 *    `allConversations`, `pinnedConversations` and `conversationsByFolder` must go through the
 *    injected `defaultDispatcher`.
 * 2. **The view model produces the folder grouping** -- HomeScreen no longer does
 *    `remember(allConversations) { ... }` during composition.
 * 3. **The home root scope subscribes neither to the whole conversation list nor to the search
 *    text** -- the former lets any row update invalidate the whole page, the latter lets every
 *    keystroke do the same. The root only consumes projections the view model has already computed.
 * 4. **Folder detail reads its own slice** of the grouping instead of filtering every conversation.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HomeRecompositionScopeTest {

    /**
     * Bookkeeping dispatcher: it only counts how many blocks were actually dispatched to it and
     * hands execution to the TestDispatcher, so the assertions stay deterministic (no real
     * background thread is introduced, and `advanceUntilIdle()` still drains everything).
     */
    private class RecordingDispatcher(
        private val delegate: CoroutineDispatcher,
    ) : CoroutineDispatcher() {
        val dispatchCount = AtomicInteger(0)

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatchCount.incrementAndGet()
            delegate.dispatch(context, block)
        }
    }

    private val dispatcher = StandardTestDispatcher()
    private val recordingDefaultDispatcher = RecordingDispatcher(dispatcher)

    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val folderRepository = mockk<FolderRepository>()
    private val noteRepository = mockk<NoteRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)

    private val now = 1_700_000_000_000L

    private val seededConversations = listOf(
        conversation("c-old", folderID = "folder-a", updatedAt = now - 5_000),
        conversation("c-new", folderID = "folder-a", updatedAt = now),
        conversation("c-other", folderID = "folder-b", updatedAt = now - 1_000),
        conversation("c-loose", folderID = null, updatedAt = now - 2_000),
        conversation("c-blank", folderID = "   ", updatedAt = now - 3_000),
        conversation("c-empty-draft", folderID = "folder-a", updatedAt = now, isDraft = true, messageCount = 0),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        every { appPreferencesRepository.pinnedConversationIds } returns flowOf(listOf("c-new", "missing"))
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeAll() } returns flowOf(seededConversations)
        every { conversationRepository.observeUngroupedEarlierCount(any()) } returns flowOf(0)
        every { conversationRepository.search(any()) } returns flowOf(emptyList())
        every { folderRepository.observeAll() } returns flowOf(emptyList())
        every { noteRepository.observeActiveSummary() } returns flowOf(NoteSummary(0, null))
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } returns Unit
        coEvery { folderRepository.migrateColorTags() } returns Unit
        coEvery { skillRepository.refreshAll() } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { conversationRepository.currentMonthlyCostTotal() } returns 0.0
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        Dispatchers.resetMain()
    }

    // ── 1 + 2: the view model groups folders on the injected dispatcher ──

    @Test
    fun `conversationsByFolder is produced by the view model off the main dispatcher`() = runTest {
        val viewModel = createViewModel()
        val before = recordingDefaultDispatcher.dispatchCount.get()

        val collector = launch { viewModel.conversationsByFolder.collect { } }
        advanceUntilIdle()

        // The asserted object comes from the production path: the view model's real StateFlow
        // value, not a fixture the test built itself.
        val grouped = viewModel.conversationsByFolder.value
        assertEquals(setOf("folder-a", "folder-b"), grouped.keys)
        // updatedAt descending within a group is groupConversationsByFolder's production semantics
        assertEquals(listOf("c-new", "c-old"), grouped.getValue("folder-a").map { it.id })
        assertEquals(listOf("c-other"), grouped.getValue("folder-b").map { it.id })
        // null / blank folderIDs are not grouped; empty drafts were already dropped by allConversations
        assertFalse(grouped.values.flatten().any { it.id == "c-loose" || it.id == "c-blank" })
        assertFalse(grouped.values.flatten().any { it.id == "c-empty-draft" })

        assertTrue(
            "the grouping must be dispatched through the injected defaultDispatcher (its dispatch count did not grow, " +
                "which means flowOn was removed and the work moved back onto the collecting main thread)",
            recordingDefaultDispatcher.dispatchCount.get() > before,
        )
        collector.cancel()
    }

    @Test
    fun `pinned conversations resolve in order and skip missing ids`() = runTest {
        val viewModel = createViewModel()
        val collector = launch { viewModel.pinnedConversations.collect { } }
        advanceUntilIdle()

        assertEquals(listOf("c-new"), viewModel.pinnedConversations.value.map { it.id })
        collector.cancel()
    }

    /** Turns red if HomeScreen brings back `remember(allConversations) { groupConversationsByFolder(...) }`. */
    @Test
    fun `home screen does not regroup folders inside composition`() {
        val source = homeSource("feature/home/HomeScreen.kt")
        assertFalse(
            "the home screen must not regroup folders during composition: that is main-thread work, and it subscribes the home scope to the entire conversation list",
            source.contains("remember(allConversations)"),
        )
        assertTrue(
            "the home screen should consume HomeViewModel.conversationsByFolder instead",
            source.contains("viewModel.conversationsByFolder.collectAsStateWithLifecycle()"),
        )
    }

    // ── 3: the root scope's subscription surface ──

    /** Structure lock: bringing back a root collect of `allConversations` or `searchQuery` turns this red. */
    @Test
    fun `home screen root subscribes to neither the conversation list nor the search text`() {
        val source = homeSource("feature/home/HomeScreen.kt")
        assertFalse(
            "the home root must not subscribe to the entire conversation list: any row update (a streaming write back, a rename) invalidates the whole page",
            source.contains("viewModel.allConversations"),
        )
        assertFalse(
            "the home root must not subscribe to the search text: every keystroke would invalidate the whole page, and only the search field needs the full text",
            source.contains("viewModel.searchQuery.collectAsStateWithLifecycle()"),
        )
        assertTrue(
            "the root should consume the view model's isSearchActive boolean projection instead",
            source.contains("viewModel.isSearchActive.collectAsStateWithLifecycle()"),
        )
        assertTrue(
            "the root should consume the view model's searchInFlight boolean projection instead",
            source.contains("viewModel.searchInFlight.collectAsStateWithLifecycle()"),
        )
        val rememberLine = source.lines().first { it.contains("val visibleTopLevelConversations = remember(") }
        assertFalse(
            "the visible list's remember keys must not include the search text, or typing recomputes it anyway: $rememberLine",
            rememberLine.contains("searchQuery"),
        )
    }

    /** While typing, `isSearchActive` flips once on the empty -> non-empty crossing; no character in between produces a new value. */
    @Test
    fun `search active boolean does not change on every keystroke`() = runTest {
        val viewModel = createViewModel()
        // Keep the WhileSubscribed upstream hot; without a subscriber the projection stops updating.
        val collector = launch { viewModel.isSearchActive.collect { } }
        advanceUntilIdle()

        val samples = mutableListOf(viewModel.isSearchActive.value)
        viewModel.enterSearch()
        advanceUntilIdle()
        samples += viewModel.isSearchActive.value
        "budget".forEachIndexed { index, _ ->
            viewModel.setSearchQuery("budget".substring(0, index + 1))
            advanceUntilIdle()
            samples += viewModel.isSearchActive.value
        }

        // Collapsed to its transitions the projection changes exactly once. The home root subscribes
        // to this boolean, so every extra value would be one more whole-page recomposition.
        val transitions = samples.filterIndexed { index, value -> index == 0 || samples[index - 1] != value }
        assertEquals("sampled after every keystroke: $samples", listOf(false, true), transitions)
        collector.cancel()
    }

    /** `searchInFlight` is true until results catch up with the input, then falls back to false. */
    @Test
    fun `search in flight clears once results catch up`() = runTest {
        val viewModel = createViewModel()
        val collector = launch { viewModel.searchInFlight.collect { } }
        advanceUntilIdle()

        viewModel.enterSearch()
        viewModel.setSearchQuery("budget")
        advanceTimeBy(100)
        assertTrue("before the debounce releases, results necessarily lag behind the input", viewModel.searchInFlight.value)

        advanceUntilIdle()
        assertFalse("once the query returns it has to fall back to false, or \"no results\" never shows", viewModel.searchInFlight.value)
        collector.cancel()
    }

    /**
     * "Is any selected conversation in a folder" is derived by the view model (it used to scan
     * `allConversations` inside composition). The predicate stays `folderID != null`: a blank string
     * still counts as being in a folder, character for character the old behaviour.
     */
    @Test
    fun `selected conversations in folder is derived by the view model`() = runTest {
        val viewModel = createViewModel()
        val collector = launch { viewModel.conversationsByFolder.collect { } }
        advanceUntilIdle()

        viewModel.startEditingWithSelection("c-loose")
        assertFalse(viewModel.selectedConversationsHaveFolder())

        viewModel.toggleSelection("c-new")
        assertTrue(viewModel.selectedConversationsHaveFolder())

        viewModel.startEditingWithSelection("c-blank")
        assertTrue(
            "a blank folderID counted as in-folder before; moving this into the view model must not change that",
            viewModel.selectedConversationsHaveFolder(),
        )
        collector.cancel()
    }

    // ── 4: folder detail no longer scans every conversation ──

    /** Structure lock: folder detail must not subscribe to the whole conversation list, nor lowercase every conversation per keystroke. */
    @Test
    fun `folder detail reads the folder's own list instead of filtering every conversation`() {
        val source = homeSource("feature/home/folders/FolderDetailScreen.kt")
        assertFalse(
            "folder detail must not subscribe to the entire conversation list: it only needs this one folder's slice",
            source.contains("viewModel.allConversations"),
        )
        assertTrue(
            "it should consume the grouping the view model computed in the background",
            source.contains("viewModel.conversationsByFolder.collectAsStateWithLifecycle()"),
        )
        val perKeystroke = source.lines().filter { it.contains("searchQuery") && it.contains("lowercase()") }
        assertTrue(
            "the lowercased haystack must be computed once per list, not once per keystroke; still per-keystroke here: $perKeystroke",
            perKeystroke.size <= 1,
        )
    }

    /** Folder detail is fed by the same grouping as home: still updatedAt descending within a folder, and a blank folderID is not a folder. */
    @Test
    fun `folder grouping feeding the detail screen keeps order and skips blank folder ids`() = runTest {
        val viewModel = createViewModel()
        val collector = launch { viewModel.conversationsByFolder.collect { } }
        advanceUntilIdle()

        val grouped = viewModel.conversationsByFolder.value
        assertEquals(listOf("c-new", "c-old"), grouped.getValue("folder-a").map { it.id })
        assertFalse("a blank folderID must not turn into a folder of its own", grouped.containsKey("   "))
        collector.cancel()
    }

    /** Both notes card values come from one single-row projection, and the title is trimmed (an empty title stays an empty string, never null). */
    @Test
    fun `notes card values come from the projected summary`() = runTest {
        every { noteRepository.observeActiveSummary() } returns flowOf(NoteSummary(3, "  Latest note  "))
        val viewModel = createViewModel()

        val countCollector = launch { viewModel.activeNoteCount.collect { } }
        val titleCollector = launch { viewModel.latestNoteTitle.collect { } }
        advanceUntilIdle()

        assertEquals(3, viewModel.activeNoteCount.value)
        assertEquals("Latest note", viewModel.latestNoteTitle.value)
        countCollector.cancel()
        titleCollector.cancel()
    }

    // ── helpers ──

    private fun createViewModel() = HomeViewModel(
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        folderRepository = folderRepository,
        noteRepository = noteRepository,
        globalSnackbarManager = globalSnackbarManager,
        skillRepository = skillRepository,
        chatStreamingManager = chatStreamingManager,
        ioDispatcher = dispatcher,
        defaultDispatcher = recordingDefaultDispatcher,
    )

    private fun conversation(
        id: String,
        folderID: String?,
        updatedAt: Long,
        isDraft: Boolean = false,
        messageCount: Int = 1,
    ) = Conversation(
        id = id,
        title = id,
        providerID = "p1",
        providerKind = ProviderKind.OpenAI,
        modelID = "m1",
        updatedAt = updatedAt,
        folderID = folderID,
        isDraft = isDraft,
        messageCount = messageCount,
    )

    /**
     * Reads a source file with comments stripped, the same way `IdleRenderingPerformanceContractTest`
     * does: a fix usually leaves a "this used to be X, removed because Y" comment in place, and
     * scanning the raw text would flag that explanation as a violation.
     */
    private fun homeSource(relativePath: String): String {
        val file = File("src/main/java/ai/oriveo/community/$relativePath")
        assertTrue("source file does not exist: ${file.absolutePath}", file.exists())
        return file.readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines()
            .joinToString("\n") { it.substringBefore("//") }
    }
}
