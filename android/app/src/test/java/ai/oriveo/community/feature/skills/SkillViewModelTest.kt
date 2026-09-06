package ai.oriveo.community.feature.skills

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillCategory
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
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
import kotlinx.coroutines.flow.collect
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
class SkillViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val skillRepository = mockk<SkillRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>()

    private val catalogSkillsFlow = MutableStateFlow<List<Skill>>(emptyList())
    private val userSkillsFlow = MutableStateFlow<List<Skill>>(emptyList())
    private val allSkillsFlow = MutableStateFlow<List<Skill>>(emptyList())
    private val categoriesFlow = MutableStateFlow<List<SkillCategory>>(emptyList())
    private val providersFlow = MutableStateFlow<List<Provider>>(emptyList())
    private val lastUsedModelFlow = MutableStateFlow<LastUsedModelRef?>(null)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        MetadataTestFixtures.applyRaw(
            """{"version":1,"capabilityRuntime":{"revision":"runtime-r7","generatedAt":"2026-08-14T00:00:00Z","recipes":{},"controlDefinitions":{},"sourceIndex":{}},"providers":{"openAI":{"resolveMap":{"gpt-5.4":"gpt-5.4","gpt-5.4-mini":"gpt-5.4-mini"},"models":{"gpt-5.4":{"canonicalModelId":"gpt-5.4","transport":"openai_responses"},"gpt-5.4-mini":{"canonicalModelId":"gpt-5.4-mini","transport":"openai_responses"}}}}}""",
        )
        every { skillRepository.observeCatalogSkills() } returns catalogSkillsFlow
        every { skillRepository.observeUserSkills() } returns userSkillsFlow
        every { skillRepository.observeAllSkills() } returns allSkillsFlow
        every { skillRepository.categories } returns categoriesFlow
        coEvery { skillRepository.refreshAll() } returns Unit
        coEvery { skillRepository.delete(any()) } returns Unit
        coEvery { skillRepository.togglePin(any(), any(), any()) } returns Unit
        coEvery { skillRepository.recordUse(any()) } returns Unit

        every { providerRepository.observeAll() } returns providersFlow
        every { appPreferencesRepository.lastUsedModelRef } returns lastUsedModelFlow
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        every { globalSnackbarManager.show(any()) } just runs

        coEvery {
            conversationRepository.createDraft(any(), any(), any(), any(), any(), any())
        } returns Conversation(
            id = "conversation-1",
            title = "My Skill",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-5.4",
            isDraft = true,
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `createSkill forwards the skill to the repository`() = runTest {
        val requestSlot = slot<ai.oriveo.community.core.data.repository.CreateSkillRequest>()
        val createdSkill = sampleSkill("skill-created")
        coEvery { skillRepository.create(capture(requestSlot)) } returns createdSkill

        val viewModel = createViewModel()
        var receivedSkill: Skill? = null

        viewModel.createSkill(
            name = "Travel Planner",
            description = "Plan trips",
            icon = "T",
            color = "#ffffff",
            systemPrompt = "You are helpful.",
            suggestedProviderId = null,
            suggestedModelId = null,
            modelCapabilityHint = "any",
            temperature = null,
            reasoningLevel = null,
            webSearchEnabled = null,
            starterMessages = emptyList(),
            knowledgeFiles = listOf(sampleReferenceFile()),
            useMemory = true,
            onSuccess = { receivedSkill = it },
            onError = { error("unexpected error: $it") },
        )
        advanceUntilIdle()

        assertEquals(listOf("guide.txt"), requestSlot.captured.knowledgeFiles.map { it.name })
        assertEquals(createdSkill, receivedSkill)
    }

    @Test
    fun `updateSkill forwards the reference files to the repository`() = runTest {
        val requestSlot = slot<ai.oriveo.community.core.data.repository.UpdateSkillRequest>()
        val updatedSkill = sampleSkill("skill-updated")
        coEvery { skillRepository.update("skill-1", capture(requestSlot)) } returns updatedSkill

        val viewModel = createViewModel()
        var receivedSkill: Skill? = null

        viewModel.updateSkill(
            id = "skill-1",
            name = "Travel Planner",
            description = "Plan trips",
            icon = "T",
            color = "#ffffff",
            systemPrompt = "You are helpful.",
            suggestedProviderId = null,
            suggestedModelId = null,
            modelCapabilityHint = "any",
            temperature = null,
            reasoningLevel = null,
            webSearchEnabled = null,
            starterMessages = emptyList(),
            knowledgeFiles = listOf(sampleReferenceFile()),
            useMemory = true,
            onSuccess = { receivedSkill = it },
            onError = { error("unexpected error: $it") },
        )
        advanceUntilIdle()

        assertEquals(listOf("guide.txt"), requestSlot.captured.knowledgeFiles?.map { it.name })
        assertEquals(updatedSkill, receivedSkill)
    }

    @Test
    fun `deleteSkill deletes by id`() = runTest {
        val viewModel = createViewModel()

        viewModel.deleteSkill(id = "skill-1")
        advanceUntilIdle()

        coVerify(exactly = 1) { skillRepository.delete("skill-1") }
    }

    @Test
    fun `refresh clears loading flag when repository refresh fails`() = runTest {
        coEvery { skillRepository.refreshAll() } returns Unit andThenThrows RuntimeException("boom")
        val viewModel = createViewModel()
        advanceUntilIdle()

        viewModel.refresh()
        advanceUntilIdle()

        assertFalse(viewModel.isRefreshing)
    }

    @Test
    fun `togglePin past the old pin cap still succeeds`() = runTest {

        allSkillsFlow.value = listOf(
            sampleSkill("skill-1", isPinned = true, pinOrder = 1),
            sampleSkill("skill-2", isPinned = true, pinOrder = 2),
            sampleSkill("skill-3", isPinned = true, pinOrder = 3),
            sampleSkill("skill-4", isPinned = true, pinOrder = 4),
            sampleSkill("skill-5", isPinned = true, pinOrder = 5),
        )
        val viewModel = createViewModel()
        val collectJob = backgroundScope.launch { viewModel.allSkills.collect() }
        advanceUntilIdle()

        viewModel.togglePin(sampleSkill("skill-6", isPinned = false))
        advanceUntilIdle()

        coVerify(exactly = 1) { skillRepository.togglePin("skill-6", true, 6) }
        verify(exactly = 0) { globalSnackbarManager.show(any()) }
        collectJob.cancel()
    }

    @Test
    fun `togglePin assigns next pin order when pinning a skill`() = runTest {

        allSkillsFlow.value = listOf(
            sampleSkill("skill-1", isPinned = true, pinOrder = 2),
            sampleSkill("skill-2", isPinned = true, pinOrder = 8),
            sampleSkill("skill-3", isPinned = false, pinOrder = 0),
        )
        val viewModel = createViewModel()
        val collectJob = backgroundScope.launch { viewModel.allSkills.collect() }
        advanceUntilIdle()

        viewModel.togglePin(sampleSkill("skill-3", isPinned = false, pinOrder = 0))
        advanceUntilIdle()

        coVerify(exactly = 1) {
            skillRepository.togglePin("skill-3", true, 9)
        }
        collectJob.cancel()
    }

    @Test
    fun `startConversationWithSkill without available provider only reports prompt-worthy state`() {
        providersFlow.value = listOf(
            Provider(
                id = "provider-issue",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Issue("invalid key"),
                models = listOf(sampleModel("gpt-4.1")),
            ),
        )
        val viewModel = createViewModel()
        var missingProviderInvoked = false

        viewModel.startConversationWithSkill(
            skill = sampleSkill("skill-1"),
            onCreated = {},
            onMissingProvider = { missingProviderInvoked = true },
        )

        assertFalse(missingProviderInvoked)
        assertTrue(viewModel.showSkillProviderPrompt)
        verify(exactly = 1) {
            globalSnackbarManager.show(
                match {
                    val message = it.message
                    message is UiText.Resource &&
                        message.resId == R.string.skills_needProviderMessage
                },
            )
        }
        coVerify(exactly = 0) { conversationRepository.createDraft(any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { skillRepository.recordUse(any()) }
    }

    @Test
    fun `startConversationWithSkill uses suggested model and records usage`() = runTest {
        providersFlow.value = listOf(
            Provider(
                id = "provider-1",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(
                    sampleModel(
                        id = "gpt-5.4-2026-03-05",
                        canonicalModelId = "gpt-5.4",
                    ),
                ),
            ),
        )
        val viewModel = createViewModel()
        advanceUntilIdle()
        var createdConversationId: String? = null
        val skill = sampleSkill(
            id = "skill-1",
            suggestedProviderId = "provider-1",
            suggestedModelId = "gpt-5.4-2026-03-05",
        )

        viewModel.startConversationWithSkill(
            skill = skill,
            onCreated = { createdConversationId = it },
        )
        advanceUntilIdle()

        coVerify(exactly = 1) {
            appPreferencesRepository.setLastUsedModel(
                "provider-1",
                match<AIModel> { it.id == "gpt-5.4-2026-03-05" && it.canonicalModelId == "gpt-5.4" },
            )
        }
        coVerify(exactly = 1) {
            conversationRepository.createDraft(
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = "gpt-5.4",
                title = "My Skill",
                folderID = null,
                skillId = "skill-1",
                useMemory = true,
            )
        }
        coVerify(exactly = 1) { skillRepository.recordUse("skill-1") }
        assertEquals("conversation-1", createdConversationId)
    }

    private fun createViewModel(
        capabilityPreferenceStore: CapabilityPreferenceStore? = null,
    ) = SkillViewModel(
        skillRepository = skillRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        appPreferencesRepository = appPreferencesRepository,
        globalSnackbarManager = globalSnackbarManager,
        capabilityPreferenceStore = capabilityPreferenceStore,
    )

    private fun sampleSkill(
        id: String,
        isPinned: Boolean = false,
        pinOrder: Int = 0,
        suggestedProviderId: String? = null,
        suggestedModelId: String? = null,
        reasoningLevel: String? = null,
        webSearchEnabled: Boolean? = null,
    ) = Skill(
        id = id,
        name = "My Skill",
        systemPrompt = "You are helpful.",
        isPinned = isPinned,
        pinOrder = pinOrder,
        suggestedProviderId = suggestedProviderId,
        suggestedModelId = suggestedModelId,
        reasoningLevel = reasoningLevel,
        webSearchEnabled = webSearchEnabled,
    )

    private fun sampleModel(
        id: String,
        canonicalModelId: String? = null,
    ) = AIModel(
        id = id,
        name = id,
        isAvailable = true,
        isDefault = true,
        canonicalModelId = canonicalModelId,
    )

    private fun sampleReferenceFile() = SkillKnowledgeFile(
        id = "ref-1",
        name = "guide.txt",
        content = "Pack light.",
        charCount = 11,
    )

}
