package ai.oriveo.community.feature.settings

import androidx.room.Room
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.MemoryCandidate
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.ChatSendCommandCoordinator
import ai.oriveo.community.feature.chat.ChatSendLauncher
import ai.oriveo.community.feature.chat.ChatUserSendLauncher
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.spyk
import java.io.IOException
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Memory page entry row and the candidate inbox page: lists pending, and save / edit / ignore all land on actual Room rows. */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class MemoryInboxViewModelTest {
    private val account = "account-1"
    private val dispatcher = StandardTestDispatcher()
    // The send entry generates candidates with real time (nowMs = System.currentTimeMillis()); the repository clock starts from now so candidates are not treated as expired and purged.
    private var clock = System.currentTimeMillis()

    private val db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
        .allowMainThreadQueries()
        .setQueryExecutor { it.run() }
        .setTransactionExecutor { it.run() }
        .build()
    private val items: MemoryItemRepository
    private val candidates: MemoryCandidateRepository
    private val toasts = mutableListOf<GlobalSnackbarMessage>()

    init {
        val preferences = AppPreferencesRepository(
            preferenceDao = db.preferenceDao(),
        )
        items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
        candidates = MemoryCandidateRepository(
            dao = db.memoryCandidateDao(),
            items = items,
            now = { clock },
            io = Dispatchers.Unconfined,
            preferences = preferences,
        )
    }

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        db.close()
    }

    /** Sentences are taken by id from the cases of the shared memory-intent.v1.json contract, not hard-coded. */
    private val cases: Map<String, JsonObject> by lazy {
        ContextContractFixture.cases(ContextContractFixture.load("memory-intent.v1.json"), "cases").associateBy { it.id() }
    }

    private fun text(id: String): String = cases.getValue(id)["text"]!!.jsonPrimitive.content

    /** Writes one candidate through the production generation entry; each is 1 second later. */
    private suspend fun generate(caseId: String, messageId: String): MemoryCandidate {
        clock += 1_000
        return candidates.generate(
            accountId = account,
            text = text(caseId),
            messageId = messageId,
            conversationId = "conversation-1",
            folderId = null,
            useMemory = true,
        )!!
    }

    private fun TestScope.viewModel(repository: MemoryCandidateRepository = candidates): MemoryInboxViewModel =
        MemoryInboxViewModel(
        candidates = repository,
        accountId = { account },
        actionScope = this,
        showToast = { toasts += it },
        ioContext = EmptyCoroutineContext,
    )

    @Test
    fun inbox_lists_pending_newest_first() = runTest {
        val older = generate("zh_explicit_01_golden", "message-1")
        val newer = generate("zh_implicit_04_golden", "message-2")

        val vm = viewModel()
        advanceUntilIdle()

        val listed = vm.state.value.candidates
        assertEquals(listOf(newer.id, older.id), listed.map { it.id })
        assertEquals(candidates.pending(account), listed)
        assertEquals(newer.content, listed.first().content)
        assertEquals(newer.proposedKind.let { MemoryItemGroup.of(it) ?: MemoryItemGroup.About }, listed.first().inboxGroup())
    }

    @Test
    fun entry_row_shows_pending_count() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        // With 0 items no value is shown.
        assertNull(vm.state.value.entryValue)

        generate("zh_explicit_01_golden", "message-1")
        generate("zh_implicit_04_golden", "message-2")
        // Back on the memory page it reloads.
        vm.refresh()
        advanceUntilIdle()

        assertEquals(candidates.pending(account).size, vm.state.value.count)
        assertEquals("2", vm.state.value.entryValue)
    }

    @Test
    fun inbox_save_creates_item_and_undo_deletes_it() = runTest {
        val candidate = generate("zh_explicit_01_golden", "message-1")
        val vm = viewModel()
        advanceUntilIdle()

        vm.save(candidate.id)
        // The row disappears immediately.
        assertTrue(vm.state.value.candidates.isEmpty())
        advanceUntilIdle()

        assertTrue(candidates.pending(account).isEmpty())
        val item = items.list(account).single()
        assertEquals(candidate.content, item.content)
        assertEquals(candidate.proposedKind, item.kind)
        assertEquals(candidate.scope, item.scope)
        assertEquals(candidate.source.type, item.source.type)
        assertEquals(listOf("message-1"), item.source.messageIds)

        val toast = toasts.single()
        assertEquals(UiText.Resource(R.string.memory_suggestion_saved), toast.message)
        assertEquals(UiText.Resource(R.string.undo), toast.action?.label)
        assertEquals(5000L, toast.durationMs)

        // Undo = the item repository deletes the just-created item normally.
        toast.action!!.onClick()
        advanceUntilIdle()
        assertNull(items.list(account).firstOrNull { it.id == item.id && it.deletedAt == null })

        // accept fails (candidate already gone): toast "Not saved" and reload.
        val gone = generate("zh_implicit_04_golden", "message-2")
        vm.refresh()
        advanceUntilIdle()
        db.memoryCandidateDao().delete(account, gone.id)
        vm.save(gone.id)
        advanceUntilIdle()
        assertEquals(UiText.Resource(R.string.memory_suggestion_failed), toasts.last().message)
        assertTrue(vm.state.value.candidates.isEmpty())
        assertTrue(vm.state.value.showsEmptyState)
    }

    @Test
    fun inbox_edit_saves_edited_content() = runTest {
        val candidate = generate("zh_explicit_01_golden", "message-1")
        val vm = viewModel()
        advanceUntilIdle()

        vm.edit(candidate.id)
        val opened = vm.editor.value
        assertNotNull(opened)
        assertNull(opened!!.state.itemId)
        assertEquals(candidate.content, opened.state.text)
        assertEquals(MemoryItemGroup.of(candidate.proposedKind) ?: MemoryItemGroup.About, opened.state.group)

        // Cancel keeps the row and leaves the candidate untouched.
        vm.dismissEditor()
        assertNull(vm.editor.value)
        assertEquals(listOf(candidate.id), vm.state.value.candidates.map { it.id })

        vm.edit(candidate.id)
        vm.updateEditorText("  \u6211\u504f\u597d\u7b80\u77ed\u76f4\u63a5\u7684\u56de\u7b54  ")
        vm.saveEditor()
        advanceUntilIdle()

        assertNull(vm.editor.value)
        assertTrue(vm.state.value.candidates.isEmpty())
        assertTrue(candidates.pending(account).isEmpty())
        val item = items.list(account).single()
        assertEquals("\u6211\u504f\u597d\u7b80\u77ed\u76f4\u63a5\u7684\u56de\u7b54", item.content)
        // Group unchanged: kind follows the candidate; scope unchanged; an edited body sets confidence = 1.0.
        assertEquals(candidate.proposedKind, item.kind)
        assertEquals(candidate.scope, item.scope)
        assertEquals(1.0, item.confidence, 0.0)
        assertEquals(UiText.Resource(R.string.memory_suggestion_saved), toasts.single().message)

        // kind is given only when the group changed.
        val second = generate("zh_implicit_04_golden", "message-2")
        vm.refresh()
        advanceUntilIdle()
        vm.edit(second.id)
        vm.updateEditorGroup(MemoryItemGroup.Projects)
        vm.saveEditor()
        advanceUntilIdle()
        assertEquals(MemoryKind.PROJECT, items.list(account).single { it.content != item.content }.kind)
    }

    @Test
    fun inbox_ignore_rejects_candidate() = runTest {
        val candidate = generate("zh_explicit_01_golden", "message-1")
        val vm = viewModel()
        advanceUntilIdle()

        vm.ignore(candidate.id)
        assertTrue(vm.state.value.candidates.isEmpty())
        advanceUntilIdle()

        assertTrue(candidates.pending(account).isEmpty())
        assertEquals(MemoryCandidateStatus.REJECTED, candidates.get(account, candidate.id)?.status)
        assertTrue(items.list(account).isEmpty())
        assertTrue(toasts.isEmpty())
    }

    @Test
    fun inbox_empty_shows_empty_state() = runTest {
        val vm = viewModel()
        // No empty-state flash before the first read finishes.
        assertFalse(vm.state.value.showsEmptyState)
        advanceUntilIdle()
        assertTrue(vm.state.value.showsEmptyState)

        val candidate = generate("zh_explicit_01_golden", "message-1")
        vm.refresh()
        advanceUntilIdle()
        assertFalse(vm.state.value.showsEmptyState)

        // Back to the empty state after the last one is handled.
        vm.ignore(candidate.id)
        advanceUntilIdle()
        assertTrue(vm.state.value.showsEmptyState)
    }

    @Test
    fun no_candidate_becomes_active_without_accept() = runTest {
        val first = generate("zh_explicit_01_golden", "message-1")
        generate("zh_implicit_04_golden", "message-2")
        val vm = viewModel()
        advanceUntilIdle()

        // List, open edit then cancel, ignore: none creates an item.
        vm.edit(first.id)
        vm.dismissEditor()
        vm.ignore(first.id)
        vm.refresh()
        advanceUntilIdle()

        assertEquals(1, vm.state.value.count)
        assertTrue(candidates.pending(account).all { it.status == MemoryCandidateStatus.PENDING })
        assertTrue(items.list(account).isEmpty())
    }

    @Test
    fun auto_suggest_defaults_on_and_persists() = runTest {
        val vm = viewModel()
        advanceUntilIdle()
        assertTrue(vm.autoSuggest.value)
        assertTrue(candidates.autoSuggestEnabled(account))

        vm.setAutoSuggest(false)
        advanceUntilIdle()
        assertFalse(vm.autoSuggest.value)
        assertFalse(candidates.autoSuggestEnabled(account))

        // A freshly opened page is still off.
        val reopened = viewModel()
        advanceUntilIdle()
        assertFalse(reopened.autoSuggest.value)

        reopened.setAutoSuggest(true)
        advanceUntilIdle()
        assertTrue(viewModel().also { advanceUntilIdle() }.autoSuggest.value)
    }

    @Test
    fun auto_suggest_off_skips_implicit_keeps_explicit() = runTest {
        // Pending items that existed before turning off are not deleted; the list shows as usual.
        val existing = generate("zh_explicit_01_golden", "message-0")
        val vm = viewModel()
        advanceUntilIdle()
        vm.setAutoSuggest(false)
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf(existing.id), vm.state.value.candidates.map { it.id })
        assertEquals(existing.id, candidates.pending(account).single().id)
        // Clear it, so below only what the new send generated is visible.
        db.memoryCandidateDao().delete(account, existing.id)

        val send = sendEntry()
        // Implicit intent: no candidate is generated once off.
        send(text("zh_implicit_04_golden"))
        assertTrue(candidates.pending(account).isEmpty())

        // An explicit "remember" still produces a candidate.
        send(text("zh_explicit_01_golden"))
        val explicit = candidates.pending(account).single()
        assertEquals("message-2", explicit.source.messageIds.single())
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf(explicit.id), vm.state.value.candidates.map { it.id })
        assertTrue(items.list(account).isEmpty())
    }

    /** Chat send entry: ChatSendCommandCoordinator new send -> candidate generation; returns a "send one sentence" function. */
    private fun TestScope.sendEntry(): suspend (String) -> Unit {
        val model = AIModel(id = "m-1", name = "Model", isDefault = true, capabilities = listOf(ModelCapability.Text))
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            models = listOf(model),
            catalogModels = listOf(model),
        )
        val conv = Conversation(
            id = "conversation-1",
            title = "t",
            providerID = provider.id,
            providerKind = ProviderKind.Relay,
            modelID = "m-1",
            messages = emptyList(),
            updatedAt = 1L,
        ).copy(useMemory = true)
        val providerRepository = mockk<ProviderRepository>()
        val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        coEvery { providerRepository.getById(provider.id) } returns provider
        // P10 rule 2: the real propose_memory mode decision reads the connection's tool-call verdict.
        io.mockk.every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.getWithMessages(conv.id) } returns conv
        var sends = 0
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conv },
            currentConversationId = { conv.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
            launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, _ ->
                sends++
                onUserMessageCreated("message-$sends", sent)
            },
            memoryCandidates = candidates,
            memoryAccountId = { account },
            memoryScope = this,
        )
        return { sentence ->
            clock += 1_000
            coordinator.sendMessage(sentence, null, provider.id, "m-1")
            advanceUntilIdle()
        }
    }

    @Test
    fun inbox_load_failure_keeps_previous_list() = runTest {
        var failPending = true
        val flaky = spyk(candidates)
        coEvery { flaky.pending(any(), any()) } answers {
            if (failPending) throw IOException("read failed") else callOriginal()
        }

        // The very first read fails: show the empty state, no blank page.
        val vm = viewModel(flaky)
        advanceUntilIdle()
        assertTrue(vm.state.value.loaded)
        assertTrue(vm.state.value.candidates.isEmpty())
        assertTrue(vm.state.value.showsEmptyState)

        failPending = false
        val candidate = generate("zh_explicit_01_golden", "message-1")
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf(candidate.id), vm.state.value.candidates.map { it.id })

        // A later read fails: keep the previous list.
        failPending = true
        vm.refresh()
        advanceUntilIdle()
        assertEquals(listOf(candidate.id), vm.state.value.candidates.map { it.id })
        assertFalse(vm.state.value.showsEmptyState)
    }

    @Test
    fun inbox_ignore_failure_reloads() = runTest {
        val candidate = generate("zh_explicit_01_golden", "message-1")
        val flaky = spyk(candidates)
        coEvery { flaky.reject(any(), any(), any()) } throws IOException("write failed")
        val vm = viewModel(flaky)
        advanceUntilIdle()

        vm.ignore(candidate.id)
        assertTrue(vm.state.value.candidates.isEmpty())
        advanceUntilIdle()

        // reject was not written: the row comes back after reload, no toast.
        assertEquals(MemoryCandidateStatus.PENDING, candidates.get(account, candidate.id)?.status)
        assertEquals(listOf(candidate.id), vm.state.value.candidates.map { it.id })
        assertTrue(toasts.isEmpty())
    }
}
