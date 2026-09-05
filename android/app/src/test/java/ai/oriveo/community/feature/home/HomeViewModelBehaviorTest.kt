package ai.oriveo.community.feature.home

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelBehaviorTest {

    private val dispatcher = StandardTestDispatcher()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val folderRepository = mockk<ai.oriveo.community.core.data.repository.FolderRepository>()
    private val noteRepository = mockk<ai.oriveo.community.core.data.repository.NoteRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    
    
    
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.pinnedConversationIds } returns flowOf(emptyList())
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeUngroupedEarlierCount(any()) } returns flowOf(0)
        every { conversationRepository.search(any()) } returns flowOf(emptyList())
        every { folderRepository.observeAll() } returns flowOf(emptyList())
        every { noteRepository.observeActive() } returns flowOf(emptyList())
        coEvery { folderRepository.migrateColorTags() } returns Unit
        coEvery { skillRepository.refreshAll() } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } returns Unit
        coEvery { conversationRepository.currentMonthlyCostTotal() } returns 0.0
        coEvery { conversationRepository.deleteMultiple(any()) } returns Unit
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `enableModel adds model without changing active selection or dismissing picker`() = runTest {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model("gpt-4o-mini", isDefault = true)),
            catalogModels = listOf(model("gpt-4o-mini", isDefault = true), model("gpt-4.1")),
        )
        coEvery { providerRepository.getById("provider-1") } returns provider
        coEvery { providerRepository.updateProvider(any()) } returns Unit

        val viewModel = HomeViewModel(
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            folderRepository = folderRepository,
            noteRepository = noteRepository,
            globalSnackbarManager = globalSnackbarManager,
            skillRepository = skillRepository,
            chatStreamingManager = chatStreamingManager,
            ioDispatcher = dispatcher,
        )
        viewModel.showModelPicker = true

        viewModel.enableModel("provider-1", "gpt-4.1")
        advanceUntilIdle()

        coVerify {
            providerRepository.updateProvider(
                match {
                    it.id == "provider-1" &&
                        it.models.map(AIModel::id) == listOf("gpt-4o-mini", "gpt-4.1") &&
                        it.models.first { model -> model.id == "gpt-4o-mini" }.isDefault &&
                        !it.models.first { model -> model.id == "gpt-4.1" }.isDefault
                },
            )
        }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) }
        verify(exactly = 0) { globalSnackbarManager.show(any()) }
        assertTrue(viewModel.showModelPicker)
    }

    @Test
    fun `enableModel makes first enabled model default`() = runTest {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = emptyList(),
            catalogModels = listOf(model("gpt-4.1")),
        )
        coEvery { providerRepository.getById("provider-1") } returns provider
        coEvery { providerRepository.updateProvider(any()) } returns Unit

        val viewModel = HomeViewModel(
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            folderRepository = folderRepository,
            noteRepository = noteRepository,
            globalSnackbarManager = globalSnackbarManager,
            skillRepository = skillRepository,
            chatStreamingManager = chatStreamingManager,
            ioDispatcher = dispatcher,
        )

        viewModel.enableModel("provider-1", "gpt-4.1")
        advanceUntilIdle()

        coVerify {
            providerRepository.updateProvider(
                match {
                    it.models.single().id == "gpt-4.1" &&
                        it.models.single().isDefault
                },
            )
        }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) }
        coVerify(exactly = 0) { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) }
    }

    @Test
    fun `enableModel adds metadata-backed official model when catalogModels is empty`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-5.4",
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-5.4",
                        canonicalModelId = "gpt-5.4",
                        displayName = "GPT-5.4",
                    ),
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-4.1",
                        canonicalModelId = "gpt-4.1",
                        displayName = "GPT-4.1",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model("gpt-5.4", isDefault = true)),
            catalogModels = emptyList(),
        )
        coEvery { providerRepository.getById("provider-1") } returns provider
        coEvery { providerRepository.updateProvider(any()) } returns Unit

        val viewModel = HomeViewModel(
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            folderRepository = folderRepository,
            noteRepository = noteRepository,
            globalSnackbarManager = globalSnackbarManager,
            skillRepository = skillRepository,
            chatStreamingManager = chatStreamingManager,
            ioDispatcher = dispatcher,
        )

        viewModel.enableModel("provider-1", "gpt-4.1")
        advanceUntilIdle()

        coVerify {
            providerRepository.updateProvider(
                match {
                    it.id == "provider-1" &&
                        it.models.map(AIModel::id) == listOf("gpt-5.4", "gpt-4.1") &&
                        it.models.first { model -> model.id == "gpt-5.4" }.isDefault &&
                        !it.models.first { model -> model.id == "gpt-4.1" }.isDefault
                },
            )
        }
    }

    @Test
    fun `setActiveModel stores matched snapshot model as canonical-capable model`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                resolveMap = mapOf(
                    "gpt-5.4" to "gpt-5.4",
                    "gpt-5.4-2026-03-05" to "gpt-5.4",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-5.4",
                        canonicalModelId = "gpt-5.4",
                        displayName = "GPT-5.4",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-5.4-2026-03-05",
                    name = "GPT-5.4",
                    canonicalModelId = "gpt-5.4",
                ),
            ),
        )
        coEvery { providerRepository.getById("provider-1") } returns provider

        val viewModel = HomeViewModel(
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            folderRepository = folderRepository,
            noteRepository = noteRepository,
            globalSnackbarManager = globalSnackbarManager,
            skillRepository = skillRepository,
            chatStreamingManager = chatStreamingManager,
            ioDispatcher = dispatcher,
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        viewModel.setActiveModel("provider-1", "gpt-5.4")
        advanceUntilIdle()

        coVerify {
            appPreferencesRepository.setLastUsedModel(
                "provider-1",
                match<AIModel> {
                    it.id == "gpt-5.4-2026-03-05" && it.canonicalModelId == "gpt-5.4"
                },
            )
        }
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `startEditingWithSelection exits search and keeps only tapped conversation selected`() {
        val viewModel = HomeViewModel(
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            folderRepository = folderRepository,
            noteRepository = noteRepository,
            globalSnackbarManager = globalSnackbarManager,
            skillRepository = skillRepository,
            chatStreamingManager = chatStreamingManager,
            ioDispatcher = dispatcher,
        )
        viewModel.isSearching = true
        viewModel.setSearchQuery("quota")

        viewModel.startEditingWithSelection("conversation-42")

        assertTrue(viewModel.isEditing)
        assertFalse(viewModel.isSearching)
        assertEquals("", viewModel.searchQuery.value)
        assertEquals(setOf("conversation-42"), viewModel.selectedIds)
    }

    @Test
    fun `selection helpers keep bulk selection state in sync`() {
        val viewModel = createHomeViewModel()
        val conversations = listOf(
            Conversation(id = "c1", title = "One", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1"),
            Conversation(id = "c2", title = "Two", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1"),
        )

        viewModel.toggleSelection("c1")
        assertEquals(setOf("c1"), viewModel.selectedIds)

        viewModel.selectAll(conversations)
        assertTrue(viewModel.areAllSelected(conversations))

        viewModel.toggleSectionSelection(conversations)
        assertTrue(viewModel.selectedIds.isEmpty())
        assertFalse(viewModel.areAllSelected(conversations))

        viewModel.toggleSectionSelection(conversations)
        assertEquals(setOf("c1", "c2"), viewModel.selectedIds)

        viewModel.deselectAll()
        assertTrue(viewModel.selectedIds.isEmpty())
    }

    @Test
    fun `moveSelectedConversationsToFolder clears edit mode and moves selected ids`() = runTest {
        val folder = Folder(id = "folder-1", name = "Work", sortOrder = 1000)
        every { folderRepository.observeAll() } returns flowOf(listOf(folder))
        coEvery { conversationRepository.batchMoveToFolder(any(), any()) } returns Unit

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.folders.collect {} }
        advanceUntilIdle()
        viewModel.startEditingWithSelection("c1")
        viewModel.toggleSelection("c2")

        viewModel.moveSelectedConversationsToFolder("folder-1")
        advanceUntilIdle()

        assertFalse(viewModel.isEditing)
        assertTrue(viewModel.selectedIds.isEmpty())
        coVerify {
            conversationRepository.batchMoveToFolder(
                match { it.toSet() == setOf("c1", "c2") },
                "folder-1",
            )
        }
        collectJob.cancel()
    }

    @Test
    fun `deleteSelectedConversations clears edit mode and deletes selected ids`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        viewModel.startEditingWithSelection("c1")
        viewModel.toggleSelection("c2")

        viewModel.deleteSelectedConversations()
        advanceUntilIdle()

        assertFalse(viewModel.isEditing)
        assertTrue(viewModel.selectedIds.isEmpty())
        coVerify {
            conversationRepository.deleteMultiple(
                match { it.toSet() == setOf("c1", "c2") },
            )
        }
    }

    @Test
    fun `copyLastMessage does nothing when conversation is missing`() = runTest {
        val clipboardManager = mockk<ClipboardManager>(relaxed = true)
        val context = mockk<Context>(relaxed = true)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns null
        every { context.getSystemService(Context.CLIPBOARD_SERVICE) } returns clipboardManager

        val viewModel = createHomeViewModel()

        viewModel.copyLastMessage("conversation-1", context)
        advanceUntilIdle()

        verify(exactly = 0) { clipboardManager.setPrimaryClip(any()) }
    }

    @Test
    fun `shareConversation does nothing when conversation is missing`() = runTest {
        val context = mockk<Context>(relaxed = true)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns null

        val viewModel = createHomeViewModel()

        viewModel.shareConversation("conversation-1", context)
        advanceUntilIdle()

        verify(exactly = 0) { context.startActivity(any<Intent>()) }
    }

    @Test
    fun `startConversationWithSkill persists chosen model creates draft and records usage`() = runTest {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model("gpt-4o", isDefault = true)),
        )
        val skill = Skill(
            id = "skill-1",
            name = "Brainstorm",
            systemPrompt = "Help me think",
            suggestedProviderId = "provider-1",
            suggestedModelId = "gpt-4o",
            useMemory = false,
        )
        val draftConversation = Conversation(
            id = "draft-1",
            title = "Brainstorm",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            isDraft = true,
            skillId = "skill-1",
            useMemory = false,
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery {
            conversationRepository.createDraft(any(), any(), any(), any(), any(), any(), any())
        } returns draftConversation

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.providers.collect {} }
        advanceUntilIdle()
        var createdId: String? = null
        var missingProviderCalled = false

        viewModel.startConversationWithSkill(
            skill = skill,
            onCreated = { createdId = it },
            onMissingProvider = { missingProviderCalled = true },
        )
        advanceUntilIdle()

        coVerify {
            appPreferencesRepository.setLastUsedModel(
                "provider-1",
                match<AIModel> { it.id == "gpt-4o" },
            )
        }
        coVerify {
            conversationRepository.createDraft(
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = "gpt-4o",
                title = "Brainstorm",
                folderID = null,
                skillId = "skill-1",
                useMemory = false,
            )
        }
        coVerify { skillRepository.recordUse("skill-1") }
        assertEquals("draft-1", createdId)
        assertFalse(missingProviderCalled)
        collectJob.cancel()
    }

    @Test
    fun `startConversationWithSkill shows snackbar without forcing navigation when no provider is available`() {
        val skill = Skill(
            id = "skill-1",
            name = "Vision",
            systemPrompt = "See",
            modelCapabilityHint = "vision",
        )
        val viewModel = createHomeViewModel()
        var missingProviderCalled = false

        viewModel.startConversationWithSkill(
            skill = skill,
            onCreated = {},
            onMissingProvider = { missingProviderCalled = true },
        )

        verify {
            globalSnackbarManager.show(
                match { message ->
                    (message.message as? UiText.Resource)?.resId == R.string.skills_needProviderMessage
                },
            )
        }
        assertFalse(missingProviderCalled)
        assertTrue(viewModel.showSkillProviderPrompt)
    }

    
    
    @Test
    fun `initial home refresh gate only allows one automatic refresh per loaded session`() = runTest {
        val activeProvider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            lastCheckedAt = null,
            models = listOf(model("gpt-4o", isDefault = true)),
        )
        every { providerRepository.observeAll() } returns MutableStateFlow(listOf(activeProvider))
        coEvery { providerRepository.resyncProvider("provider-1") } returns Unit

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()

        viewModel.refreshActiveProviderIfNeededOnInitialLoad()
        viewModel.refreshActiveProviderIfNeededOnInitialLoad()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.resyncProvider("provider-1") }
        collectJob.cancel()
    }

    

    private fun createHomeViewModel() = HomeViewModel(
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        folderRepository = folderRepository,
        noteRepository = noteRepository,
        globalSnackbarManager = globalSnackbarManager,
        skillRepository = skillRepository,
        chatStreamingManager = chatStreamingManager,
        ioDispatcher = dispatcher,
    )

    
    @Test
    fun `TC-6-1-1 new folder defaults to collapsed`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        assertFalse(viewModel.isFolderExpanded("folder-1"))
        assertTrue(viewModel.expandedFolderIds.isEmpty())
    }

    
    @Test
    fun `TC-6-1-2 toggleFolderExpand expands folder`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        viewModel.toggleFolderExpansion("folder-1")
        assertTrue(viewModel.isFolderExpanded("folder-1"))
        assertTrue(viewModel.expandedFolderIds.contains("folder-1"))
    }

    
    @Test
    fun `TC-6-1-3 toggleFolderExpand collapses when already expanded`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        viewModel.toggleFolderExpansion("folder-1")
        assertTrue(viewModel.isFolderExpanded("folder-1"))
        viewModel.toggleFolderExpansion("folder-1")
        assertFalse(viewModel.isFolderExpanded("folder-1"))
    }

    
    @Test
    fun `TC-6-1-4 double toggle is idempotent`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        val before = viewModel.isFolderExpanded("folder-1")
        viewModel.toggleFolderExpansion("folder-1")
        viewModel.toggleFolderExpansion("folder-1")
        val after = viewModel.isFolderExpanded("folder-1")
        assertEquals(before, after)
    }

    
    @Test
    fun `TC-6-1-6 multiple folders expand independently`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()
        viewModel.toggleFolderExpansion("folder-A")
        viewModel.toggleFolderExpansion("folder-C")
        assertTrue(viewModel.isFolderExpanded("folder-A"))
        assertFalse(viewModel.isFolderExpanded("folder-B"))
        assertTrue(viewModel.isFolderExpanded("folder-C"))
    }

    

    
    @Test
    fun `TC-9-1-4 renameFolder calls folderRepository rename`() = runTest {
        coEvery { folderRepository.rename("folder-1", "New Name") } returns null

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.renameFolder("folder-1", "New Name")
        advanceUntilIdle()

        coVerify { folderRepository.rename("folder-1", "New Name") }
    }

    
    @Test
    fun `TC-9-1-5 deleteFolder calls folderRepository delete`() = runTest {
        coEvery { folderRepository.delete("folder-1") } returns Unit

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.deleteFolder("folder-1")
        advanceUntilIdle()

        coVerify { folderRepository.delete("folder-1") }
    }

    

    private fun createHomeViewModelWithActiveModel(): HomeViewModel {
        val testModel = model("gpt-4o", isDefault = true)
        val testProvider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(testModel),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(testProvider))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(
            LastUsedModelRef(providerID = "provider-1", modelID = "gpt-4o"),
        )
        return createHomeViewModel()
    }

    @Test
    fun `activeModelState does not surface provider issue banner state for issue provider`() = runTest {
        val issueProvider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Issue("Key expired"),
            models = listOf(model("gpt-4o", isDefault = true)),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(issueProvider))
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(
            LastUsedModelRef(providerID = "provider-1", modelID = "gpt-4o"),
        )

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()

        assertEquals("gpt-4o", viewModel.activeModelState.value.activeModel?.model?.id)
        assertNull(viewModel.activeModelState.value.providerIssue)
        collectJob.cancel()
    }

    // TC-10.1.1: createConversationInFolder → createDraft with folderID → callback → folder auto-expanded
    @Test
    fun `TC-10-1-1 createConversationInFolder calls createDraft and auto-expands folder`() = runTest {
        val draftConversation = Conversation(
            id = "new-conv-1",
            title = "New Chat",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            isDraft = true,
            folderID = "folder-1",
        )
        coEvery { conversationRepository.createDraft(any(), any(), any(), any(), any(), any(), any()) } returns draftConversation

        val viewModel = createHomeViewModelWithActiveModel()
        
        val collectJob = backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()

        var callbackId: String? = null
        viewModel.createConversationInFolder("folder-1") { id -> callbackId = id }
        advanceUntilIdle()

        coVerify {
            conversationRepository.createDraft(
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = any(),
                folderID = "folder-1",
            )
        }
        assertEquals("new-conv-1", callbackId)
        assertTrue(
            "Folder should be auto-expanded after creating conversation",
            viewModel.isFolderExpanded("folder-1"),
        )
        collectJob.cancel()
    }

    
    @Test
    fun `TC-10-1-2 createConversationInFolder callback receives conversation ID`() = runTest {
        val draftConversation = Conversation(
            id = "draft-abc",
            title = "New Chat",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            isDraft = true,
            folderID = "folder-2",
        )
        coEvery { conversationRepository.createDraft(any(), any(), any(), any(), any(), any(), any()) } returns draftConversation

        val viewModel = createHomeViewModelWithActiveModel()
        val collectJob = backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()

        var receivedId: String? = null
        viewModel.createConversationInFolder("folder-2") { receivedId = it }
        advanceUntilIdle()

        assertEquals("draft-abc", receivedId)
        collectJob.cancel()
    }

    

    
    @Test
    fun `TC-11-1-1 folder expansion unaffected by other mutations`() = runTest {
        coEvery { folderRepository.rename(any(), any()) } returns null

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.toggleFolderExpansion("folder-1")
        assertTrue(viewModel.isFolderExpanded("folder-1"))

        
        viewModel.renameFolder("folder-2", "Renamed")
        advanceUntilIdle()

        
        assertTrue(
            "Folder expansion should persist through unrelated mutations",
            viewModel.isFolderExpanded("folder-1"),
        )
    }

    
    @Test
    fun `TC-11-1-4 createConversationInFolder auto-adds folderID to expandedFolderIds`() = runTest {
        val draftConversation = Conversation(
            id = "new-conv-2",
            title = "New Chat",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o",
            isDraft = true,
            folderID = "folder-3",
        )
        coEvery { conversationRepository.createDraft(any(), any(), any(), any(), any(), any(), any()) } returns draftConversation

        val viewModel = createHomeViewModelWithActiveModel()
        val collectJob = backgroundScope.launch { viewModel.activeModelState.collect {} }
        advanceUntilIdle()

        assertFalse(viewModel.isFolderExpanded("folder-3"))

        viewModel.createConversationInFolder("folder-3") {}
        advanceUntilIdle()

        assertTrue(
            "expandedFolderIds should contain folder-3 after creating conversation in it",
            viewModel.expandedFolderIds.contains("folder-3"),
        )
        collectJob.cancel()
    }

    
    @Test
    fun `TC-11-1-5 folder expansion persists through rename and survives unrelated delete`() = runTest {
        coEvery { folderRepository.rename(any(), any()) } returns null
        coEvery { folderRepository.delete(any()) } returns Unit

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.toggleFolderExpansion("folder-A")
        viewModel.toggleFolderExpansion("folder-B")
        assertTrue(viewModel.isFolderExpanded("folder-A"))
        assertTrue(viewModel.isFolderExpanded("folder-B"))

        
        viewModel.renameFolder("folder-A", "Renamed A")
        advanceUntilIdle()
        assertTrue("folder-A should stay expanded after rename", viewModel.isFolderExpanded("folder-A"))

        
        viewModel.deleteFolder("folder-B")
        advanceUntilIdle()
        assertTrue("folder-A should stay expanded after deleting folder-B", viewModel.isFolderExpanded("folder-A"))
        assertFalse("folder-B should be removed from expandedFolderIds after delete", viewModel.isFolderExpanded("folder-B"))
    }

    

    
    @Test
    fun `TC-12-1-1 moveConversationToFolder emits moved_to_folder snackbar with folder name`() = runTest {
        val folder = Folder(id = "folder-x", name = "Work", sortOrder = 1000)
        every { folderRepository.observeAll() } returns flowOf(listOf(folder))
        coEvery { conversationRepository.moveToFolder("conv-1", "folder-x") } returns Unit

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.folders.collect {} }
        advanceUntilIdle()

        viewModel.moveConversationToFolder("conv-1", "folder-x")
        advanceUntilIdle()

        verify {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.moved_to_folder &&
                        (msg.message as UiText.Resource).args == listOf("Work")
                },
            )
        }
        collectJob.cancel()
    }

    
    @Test
    fun `TC-12-1-2 moveConversationToFolder with null folderID emits removed_from_folder snackbar`() = runTest {
        coEvery { conversationRepository.moveToFolder("conv-1", null) } returns Unit

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.moveConversationToFolder("conv-1", null)
        advanceUntilIdle()

        verify {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.removed_from_folder
                },
            )
        }
    }

    
    @Test
    fun `TC-12-1-3 moveConversationIdsToFolder emits batch_moved_to_folder snackbar`() = runTest {
        val folder = Folder(id = "folder-y", name = "Projects", sortOrder = 2000)
        every { folderRepository.observeAll() } returns flowOf(listOf(folder))
        coEvery { conversationRepository.batchMoveToFolder(any(), any()) } returns Unit

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.folders.collect {} }
        advanceUntilIdle()

        viewModel.moveConversationIdsToFolder(listOf("c1", "c2", "c3"), "folder-y")
        advanceUntilIdle()

        verify {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.batch_moved_to_folder &&
                        (msg.message as UiText.Resource).args == listOf(3, "Projects")
                },
            )
        }
        collectJob.cancel()
    }

    
    @Test
    fun `TC-12-1-4 moveConversationIdsToFolder with null emits batch_removed_from_folder snackbar`() = runTest {
        coEvery { conversationRepository.batchMoveToFolder(any(), any()) } returns Unit

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.moveConversationIdsToFolder(listOf("c1", "c2", "c3"), null)
        advanceUntilIdle()

        verify {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.batch_removed_from_folder &&
                        (msg.message as UiText.Resource).args == listOf(3)
                },
            )
        }
    }

    // ── TC-13.2 Context Menu backing logic ─────────────────────────────────────

    
    @Test
    fun `TC-13-2-2 folderName returns correct name for valid folder id`() = runTest {
        val folder = Folder(id = "folder-1", name = "Work", sortOrder = 1000)
        every { folderRepository.observeAll() } returns flowOf(listOf(folder))

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.folders.collect {} }
        advanceUntilIdle()

        assertEquals("Work", viewModel.folderName("folder-1"))
        collectJob.cancel()
    }

    
    @Test
    fun `TC-13-2-4 folderName returns null for null id`() = runTest {
        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        assertNull(viewModel.folderName(null))
    }

    
    @Test
    fun `TC-13-2-4b folderName returns null for non-existent folder id`() = runTest {
        val folder = Folder(id = "folder-1", name = "Work", sortOrder = 1000)
        every { folderRepository.observeAll() } returns flowOf(listOf(folder))

        val viewModel = createHomeViewModel()
        val collectJob = backgroundScope.launch { viewModel.folders.collect {} }
        advanceUntilIdle()

        assertNull(viewModel.folderName("no-such-folder"))
        collectJob.cancel()
    }

    
    @Test
    fun `TC-13-3-1 createFolder emits folder_created snackbar on success`() = runTest {
        val folder = Folder(id = "new-folder", name = "My Folder", sortOrder = 1000)
        coEvery { folderRepository.create("My Folder") } returns folder

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.createFolder("My Folder")
        advanceUntilIdle()

        verify {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.folder_created
                },
            )
        }
    }

    
    @Test
    fun `TC-13-3-4 createFolder with null result does not emit snackbar`() = runTest {
        coEvery { folderRepository.create(any()) } returns null

        val viewModel = createHomeViewModel()
        advanceUntilIdle()

        viewModel.createFolder("Empty")
        advanceUntilIdle()

        verify(exactly = 0) {
            globalSnackbarManager.show(
                match { msg ->
                    (msg.message as? UiText.Resource)?.resId == R.string.folder_created
                },
            )
        }
    }

    
    private fun model(id: String, isDefault: Boolean = false) = AIModel(
        id = id,
        name = id,
        isDefault = isDefault,
    )

}
