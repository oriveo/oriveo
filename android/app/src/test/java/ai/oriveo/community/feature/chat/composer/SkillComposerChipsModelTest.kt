package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.telemetry.TelemetryEvent
import ai.oriveo.community.feature.chat.ChatSendCommandCoordinator
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** P4 contracts 19 / 20: picker rows and composer skill chips. */
@OptIn(ExperimentalCoroutinesApi::class)
class SkillComposerChipsModelTest {

    private fun skill(
        id: String,
        name: String,
        auto: Boolean = false,
        lastUsedAt: String? = null,
        source: SkillSource = SkillSource.USER,
    ) = Skill(id = id, name = name, systemPrompt = "p", autoInvoke = auto, lastUsedAt = lastUsedAt, source = source)

    private val weekly = skill("s-weekly", "Weekly report", lastUsedAt = "2026-10-01T00:00:00Z")
    private val gym = skill("s-gym", "Weekend gym plan", auto = true, lastUsedAt = "2026-09-01T00:00:00Z")
    private val tone = skill("s-tone", "My writing tone", lastUsedAt = "2026-10-20T00:00:00Z")
    private val alpha = skill("s-alpha", "Alpha notes")
    private val templates = (1..5).map { skill("t-$it", "Template week $it", source = SkillSource.BUILTIN) }

    private val mine = MutableStateFlow(listOf(weekly, gym, tone, alpha))
    private val catalog = MutableStateFlow(templates)
    private val writes = mutableListOf<Pair<String, List<String>>>()
    private val tracked = mutableListOf<Pair<TelemetryEvent, Map<String, Any?>>>()

    private fun TestScope.model(): SkillComposerChipsModel {
        val model = SkillComposerChipsModel(
            scope = backgroundScope,
            userSkills = mine,
            templates = catalog,
            writeSkillIds = { conversationId, ids ->
                writes += conversationId to ids
                ids
            },
            track = { event, props -> tracked += event to props },
        )
        backgroundScope.launch { model.cache.collect {} }
        return model
    }

    @Test
    fun picker_sorts_auto_first_then_last_used_and_filters_by_name() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        val cache = model.cache.value!!
        val all = SkillComposerChipsModel.pickerContent(cache, "")!!
        assertEquals(listOf("s-gym", "s-tone", "s-weekly", "s-alpha"), all.mine.map { it.id })
        val filtered = SkillComposerChipsModel.pickerContent(cache, "WEEK")!!
        assertEquals(listOf("s-gym", "s-weekly"), filtered.mine.map { it.id })
    }

    @Test
    fun picker_shows_at_most_three_templates_with_the_same_filter() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        val cache = model.cache.value!!
        assertEquals(listOf("t-1", "t-2", "t-3"), SkillComposerChipsModel.pickerContent(cache, "")!!.templates.map { it.id })
        assertEquals(listOf("t-4"), SkillComposerChipsModel.pickerContent(cache, "week 4")!!.templates.map { it.id })
    }

    @Test
    fun picker_closes_when_nothing_matches() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        assertNull(SkillComposerChipsModel.pickerContent(model.cache.value!!, "zzz"))
    }

    @Test
    fun chips_stop_at_three_and_the_fourth_reports_max_reached() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        val upstream = emptyList<String>()
        assertEquals(SkillAttachResult.Added, model.attach("s-weekly", "slash", "c-1", upstream))
        assertEquals(SkillAttachResult.Added, model.attach("s-gym", "at", "c-1", upstream))
        assertEquals(SkillAttachResult.AlreadyAttached, model.attach("s-gym", "at", "c-1", upstream))
        assertEquals(SkillAttachResult.Added, model.attach("s-tone", "button", "c-1", upstream))
        assertEquals(SkillAttachResult.MaxReached, model.attach("s-alpha", "button", "c-1", upstream))
        runCurrent()
        assertEquals(listOf("s-weekly", "s-gym", "s-tone"), model.attachedIds("c-1", upstream))
        assertEquals("c-1" to listOf("s-weekly", "s-gym", "s-tone"), writes.last())
        // Once the conversation reports its stored ids, they win over the optimistic copy.
        assertEquals(listOf("s-gym"), model.attachedIds("c-1", listOf("s-gym")))
    }

    @Test
    fun missing_id_shows_deleted_and_is_dropped_on_next_send() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        val upstream = listOf("s-weekly", "s-gone")
        val chips = model.chips("c-1", upstream, model.cache.value)
        assertEquals(listOf(false, true), chips.map { it.deleted })
        assertEquals("Weekly report", chips.first().skill?.name)
        // Before the cache loads nothing counts as deleted.
        assertFalse(model.chips("c-1", upstream, null).any { it.deleted })
        model.pruneBeforeSend("c-1", upstream)
        runCurrent()
        assertEquals(listOf("c-1" to listOf("s-weekly")), writes)
    }

    @Test
    fun pending_chips_before_the_conversation_land_on_the_first_send() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        model.bind("draft-session")
        model.attach("s-tone", "slash", null, emptyList())
        model.attach("s-gone-later", "slash", null, emptyList())
        assertTrue(writes.isEmpty())
        assertEquals(listOf("s-tone", "s-gone-later"), model.pendingSkillIds)
        assertEquals(listOf("s-tone"), model.pendingForCreate())

        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val providerRepository = mockk<ProviderRepository>()
        val aiModel = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
        val provider = Provider(
            id = "openai-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            models = listOf(aiModel),
        )
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery {
            conversationRepository.create(any(), any(), any(), any(), any(), any(), any(), any())
        } returns Conversation(id = "c-new", title = "New Chat", providerID = provider.id, providerKind = provider.kind, modelID = aiModel.id)
        coEvery { conversationRepository.setSkillIds("c-new", any()) } answers { secondArg() }
        var activated: String? = null
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { null },
            currentConversationId = { activated },
            pendingDraftSkillIds = { model.pendingForCreate() },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = { activated = it },
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = { _, _, _, _, _, _, _, _, _, _, _, _, _, _ -> },
        )
        assertEquals("c-new", coordinator.createFirstConversation(provider.id, aiModel.id))
        coVerify(exactly = 1) { conversationRepository.setSkillIds("c-new", listOf("s-tone")) }

        // The new conversation id replaces the draft session: pending is cleared.
        model.bind("c-new")
        assertTrue(model.pendingSkillIds.isEmpty())
    }

    @Test
    fun manual_attached_is_tracked_with_via() = runTest(timeout = 30.seconds) {
        val model = model()
        runCurrent()
        model.attach("s-weekly", "slash", "c-1", emptyList())
        model.attach("s-weekly", "slash", "c-1", emptyList())
        model.attach("t-1", "at", null, emptyList())
        model.attach("s-gym", "button", null, emptyList())
        assertEquals(
            listOf(
                TelemetryEvent.SkillManualAttached to mapOf("skill_id" to "s-weekly", "via" to "slash"),
                TelemetryEvent.SkillManualAttached to mapOf("skill_id" to "t-1", "via" to "at"),
                TelemetryEvent.SkillManualAttached to mapOf("skill_id" to "s-gym", "via" to "button"),
            ),
            tracked,
        )
    }
}
