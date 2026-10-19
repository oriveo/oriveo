package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Conversation settings sheet: draft instructions, save on close, inherited source and copy. */
@OptIn(ExperimentalCoroutinesApi::class)
class ConversationInstructionsSettingsTest {
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    private fun provider(): Provider {
        val model = AIModel(id = "m-1", name = "Model", isDefault = true, capabilities = listOf(ModelCapability.Text))
        return Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            models = listOf(model),
            catalogModels = listOf(model),
        )
    }

    private fun conversation(id: String, updatedAt: Long, instructions: String = "") =
        Conversation(
            id = id,
            title = "t",
            providerID = "relay-1",
            providerKind = ProviderKind.Relay,
            modelID = "m-1",
            messages = emptyList(),
            updatedAt = updatedAt,
            instructions = instructions,
        )

    @Test
    fun settings_draft_instructions_written_on_create() = runTest {
        val provider = provider()
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery {
            conversationRepository.create(any(), any(), any(), any(), any(), any(), any(), any())
        } returns conversation("conversation-1", 1L, instructions = "Write in Arabic")
        var activated: String? = null
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { null },
            currentConversationId = { null },
            pendingDraftInstructions = { "Write in Arabic" },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = { activated = it },
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
        )

        coordinator.sendMessage("hello", null, provider.id, "m-1")
        advanceUntilIdle()

        coVerify(exactly = 1) {
            conversationRepository.create(
                providerID = "relay-1",
                providerKind = ProviderKind.Relay,
                modelID = any(),
                title = any(),
                folderID = any(),
                skillId = any(),
                useMemory = any(),
                instructions = "Write in Arabic",
            )
        }
        coVerify(exactly = 0) { conversationRepository.updateInstructions(any(), any()) }
        assertEquals("conversation-1", activated)
    }

    @Test
    fun settings_save_normalizes_on_close() {
        // An unchanged value is not written
        assertNull(ConversationSettings.instructionsToSave(opened = "Be brief", edited = "Be brief"))
        // All whitespace is normalized to empty: already empty -> not written; previously non-empty -> an empty string is written (clears it)
        assertNull(ConversationSettings.instructionsToSave(opened = "", edited = " \n\t "))
        assertEquals("", ConversationSettings.instructionsToSave(opened = "Be brief", edited = " \n "))
        // Not trimmed; anything over 8000 code points is truncated
        assertEquals("  Be brief ", ConversationSettings.instructionsToSave(opened = "", edited = "  Be brief "))
        assertEquals(8000, ConversationSettings.instructionsToSave(opened = "", edited = "x".repeat(8001))?.length)
        // Draft state: the saved value is normalized the same way
        assertEquals("", ConversationSettings.draftInstructions("   "))
        assertEquals("y".repeat(8000), ConversationSettings.draftInstructions("y".repeat(8005)))
    }

    @Test
    fun settings_close_without_edit_keeps_remote_change() {
        // The snapshot is "Old" when opened and the live value changes to "Remote" meanwhile; the user did not touch the editor (still "Old") -> not written, the live value is kept
        assertNull(ConversationSettings.instructionsToSave(opened = "Old", edited = "Old"))
        // The user edited it -> written from the editor, even if the live value is already the changed one
        assertEquals("Mine", ConversationSettings.instructionsToSave(opened = "Old", edited = "Mine"))
        // Not written either when the normalized editor text equals the snapshot
        assertNull(ConversationSettings.instructionsToSave(opened = "", edited = "   "))
    }

    @Test
    fun settings_carry_over_source_is_latest_other_conversation() {
        val conversations = listOf(
            conversation("current", updatedAt = 900L),
            conversation("older", updatedAt = 100L, instructions = "Older rules"),
            conversation("latest", updatedAt = 500L, instructions = "Latest rules"),
        )
        assertEquals(
            "Latest rules",
            ConversationSettings.carryOverSource(conversations, currentConversationId = "current", currentInstructions = ""),
        )
        // Draft state (no current conversation): take the latest among all undeleted conversations
        assertEquals(
            "Latest rules",
            ConversationSettings.carryOverSource(
                conversations.filter { it.id != "current" },
                currentConversationId = null,
                currentInstructions = "",
            ),
        )
        // The latest one has empty instructions -> not shown, and it does not fall back to an older one
        val latestEmpty = conversations + conversation("newest-empty", updatedAt = 700L)
        assertNull(ConversationSettings.carryOverSource(latestEmpty, currentConversationId = "current", currentInstructions = ""))
    }

    @Test
    fun settings_carry_over_hidden_when_current_non_empty() {
        val conversations = listOf(
            conversation("current", updatedAt = 900L, instructions = "Mine"),
            conversation("latest", updatedAt = 500L, instructions = "Latest rules"),
        )
        assertNull(
            ConversationSettings.carryOverSource(conversations, currentConversationId = "current", currentInstructions = "Mine"),
        )
        assertNull(ConversationSettings.carryOverSource(conversations, currentConversationId = null, currentInstructions = "Draft"))
    }

    @Test
    fun settings_carry_over_hidden_when_editor_non_empty() {
        assertEquals("Latest rules", ConversationSettings.visibleCarryOver(editorText = "", source = "Latest rules"))
        // An editor holding only whitespace normalizes to "" and is still shown
        assertEquals("Latest rules", ConversationSettings.visibleCarryOver(editorText = " \n ", source = "Latest rules"))
        // Hidden as soon as the user types
        assertNull(ConversationSettings.visibleCarryOver(editorText = "W", source = "Latest rules"))
        assertNull(ConversationSettings.visibleCarryOver(editorText = "", source = null))
        // Draft state (no conversation id) does not show the memory switch; it looks at "an active semantic item exists"
        val tea = ai.oriveo.community.core.context.MemoryItem(
            id = "m-1",
            kind = ai.oriveo.community.core.context.MemoryKind.PREFERENCE,
            content = "likes tea",
            mutationId = "mutation-1",
            deviceId = "device-1",
        )
        assertTrue(ConversationSettings.memoryToggleVisible(conversationId = "c-1", memoryItems = listOf(tea)))
        assertFalse(ConversationSettings.memoryToggleVisible(conversationId = null, memoryItems = listOf(tea)))
        assertFalse(ConversationSettings.memoryToggleVisible(conversationId = "c-1", memoryItems = emptyList()))
        assertFalse(
            ConversationSettings.memoryToggleVisible(
                conversationId = "c-1",
                memoryItems = listOf(tea.copy(status = ai.oriveo.community.core.context.MemoryStatus.DELETED)),
            ),
        )
    }

    @Test
    fun strings_present_in_16_locales() {
        val keys = listOf(
            "conversation_settings_title",
            "conversation_settings_instructions_header",
            "conversation_settings_instructions_placeholder",
            "conversation_settings_instructions_footer",
            "conversation_settings_carry_over",
            "conversation_settings_usage",
            "conversation_instructions_badge",
            "conversation_instructions_badge_a11y",
            "directive_suggestion_prompt",
            "directive_suggestion_accept",
            "directive_suggestion_ignore",
            "directive_suggestion_added",
        )
        val dirs = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in",
            "values-ja", "values-ko", "values-pt-rBR", "values-ru", "values-th",
            "values-tr", "values-vi", "values-zh-rCN", "values-zh-rTW",
        )
        val missing = mutableListOf<String>()
        for (dir in dirs) {
            val values = strings(dir)
            for (key in keys) if (values[key].isNullOrBlank()) missing += "$dir $key"
        }
        assertTrue("missing: $missing", missing.isEmpty())
        assertEquals("\u5bf9\u8bdd\u8bbe\u7f6e", strings("values-zh-rCN")["conversation_settings_title"])
        assertEquals("Chat Settings", strings("values")["conversation_settings_title"])
        assertEquals("Pengaturan percakapan", strings("values-in")["conversation_settings_title"])
    }

    private fun strings(dir: String): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$dir/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length).associate { index ->
            val node = nodes.item(index)
            node.attributes.getNamedItem("name").nodeValue to node.textContent
        }
    }
}
