package ai.oriveo.community.feature.chat

import android.content.SharedPreferences
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.DirectiveDetection
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.data.database.OriveoDatabase
import androidx.room.Room
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The "Set as instruction" suggestion bar: detection, accept / undo, and ignore counting. */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class ConversationInstructionsSuggestionTest {
    private val directive = "From now on, reply in English. "
    private val span = "From now on, reply in English."

    private val instructions = mutableMapOf<String, String>()
    private val writes = mutableListOf<Pair<String, String>>()
    private val toasts = mutableListOf<GlobalSnackbarMessage>()
    private val prefsMap = mutableMapOf<String, Int>()
    private val store = DirectiveSuggestionStore(prefsProvider = { fakePrefs(prefsMap) })

    private fun TestScope.controller(scope: CoroutineScope = this) = DirectiveSuggestionController(
        scope = scope,
        store = store,
        instructionsOf = { instructions[it] },
        writeInstructions = { id, text ->
            writes += id to text
            instructions[id] = text
        },
        showToast = { toasts += it },
        ioContext = EmptyCoroutineContext,
    )

    @Test
    fun suggestion_shown_for_directive_message() = runTest {
        instructions["conversation-1"] = ""
        val controller = controller()
        val provider = provider()
        val providerRepository = mockk<ProviderRepository>()
        val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        coEvery { providerRepository.getById(provider.id) } returns provider
        // P10 rule 2: the real propose_memory mode decision reads the connection's tool-call verdict.
        io.mockk.every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation("conversation-1")
        var attemptKind = ContextConfirmAttempt.SEND
        var plainLaunches = 0
        var userLaunches = 0
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conversation("conversation-1") },
            currentConversationId = { "conversation-1" },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> plainLaunches++ },
            attemptKind = { attemptKind },
            directiveSuggestions = controller,
            launchUserSend = ChatUserSendLauncher { _, _, _, text, _, _, _, _, onUserMessageCreated, _ ->
                userLaunches++
                onUserMessageCreated("message-${userLaunches}", text)
            },
        )

        coordinator.sendMessage(directive, null, provider.id, "m-1")
        advanceUntilIdle()

        assertEquals(1, userLaunches)
        assertEquals(
            DirectiveSuggestion(conversationId = "conversation-1", messageId = "message-1", sentence = span),
            controller.pending.value["conversation-1"],
        )

        // Resending after an edit does not use the new-send entry and is not judged; the next user message clears the pending one without counting an ignore.
        attemptKind = ContextConfirmAttempt.EDIT
        coordinator.sendMessage(directive, null, provider.id, "m-1")
        advanceUntilIdle()
        assertEquals(1, plainLaunches)
        assertEquals(1, userLaunches)

        controller.onUserMessageCreated("conversation-1", "message-9", "What time is it?")
        advanceUntilIdle()
        assertNull(controller.pending.value["conversation-1"])
        assertEquals(0, store.ignoreCount("conversation-1"))

        // Switching conversations clears the pending one.
        controller.onUserMessageCreated("conversation-1", "message-10", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["conversation-1"])
        controller.retainOnly("conversation-2")
        assertNull(controller.pending.value["conversation-1"])
    }

    /** After a new user send a memory candidate is generated, but not on edit-resend; nothing is persisted when memory is off for the conversation. */
    @Test
    fun memory_candidate_generated_on_fresh_send() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .setQueryExecutor { it.run() }
            .setTransactionExecutor { it.run() }
            .build()
        try {
            val preferences = AppPreferencesRepository(
                preferenceDao = db.preferenceDao(),
            )
            val items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
            val memoryCandidates = MemoryCandidateRepository(
                dao = db.memoryCandidateDao(),
                items = items,
                io = Dispatchers.Unconfined,
            )
            val text = "\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54"
            val provider = provider()
            val providerRepository = mockk<ProviderRepository>()
            val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
            val conversationRepository = mockk<ConversationRepository>(relaxed = true)
            var conv = conversation("conversation-1").copy(folderID = "folder-1", useMemory = false)
            coEvery { providerRepository.getById(provider.id) } returns provider
            // P10 rule 2: the real propose_memory mode decision reads the connection's tool-call verdict.
            io.mockk.every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
            coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
            coEvery { conversationRepository.getWithMessages("conversation-1") } answers { conv }
            var attemptKind = ContextConfirmAttempt.SEND
            var userLaunches = 0
            val coordinator = ChatSendCommandCoordinator(
                viewModelScope = this,
                appPreferencesRepository = appPreferencesRepository,
                providerRepository = providerRepository,
                conversationRepository = conversationRepository,
                currentConversation = { conv },
                currentConversationId = { "conversation-1" },
                onProviderSelectionError = {},
                onProviderResolutionError = {},
                onModelSelectionError = {},
                onDisclosureRequired = { _, _ -> },
                onConversationActivated = {},
                onComposerConsumed = {},
                requestPin = {},
                onSendSettled = {},
                launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
                attemptKind = { attemptKind },
                directiveSuggestions = controller(),
                launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, _ ->
                    userLaunches++
                    onUserMessageCreated("message-$userLaunches", sent)
                },
                memoryCandidates = memoryCandidates,
                memoryAccountId = { "account-1" },
                memoryScope = this,
            )

            // Memory off for the conversation: send as usual, the candidate table gets no row.
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            assertEquals(1, userLaunches)
            assertTrue(db.memoryCandidateDao().list("account-1").isEmpty())

            conv = conv.copy(useMemory = true)
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            val pending = memoryCandidates.pending("account-1")
            assertEquals(1, pending.size)
            assertEquals(MemoryCandidateStatus.PENDING, pending.single().status)
            assertEquals("\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54", pending.single().content)
            assertEquals("conversation-1", pending.single().source.conversationId)
            assertEquals(listOf("message-2"), pending.single().source.messageIds)

            // Resending after an edit does not use the new-send entry, so nothing is generated.
            attemptKind = ContextConfirmAttempt.EDIT
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            assertEquals(2, userLaunches)
            assertEquals(pending, memoryCandidates.pending("account-1"))
        } finally {
            db.close()
        }
    }

    @Test
    fun suggestion_not_shown_after_three_ignores() = runTest {
        instructions["c"] = ""
        val controller = controller()
        repeat(3) { index ->
            controller.onUserMessageCreated("c", "m-$index", directive)
            advanceUntilIdle()
            assertNotNull(controller.pending.value["c"])
            controller.ignore("c")
            advanceUntilIdle()
            assertNull(controller.pending.value["c"])
        }
        assertEquals(3, prefsMap["directive_suggestion_ignores:c"])
        controller.onUserMessageCreated("c", "m-4", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["c"])
        // Counting is per conversation: other conversations are unaffected.
        instructions["other"] = ""
        controller.onUserMessageCreated("other", "m-5", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["other"])
    }

    @Test
    fun suggestion_accept_appends_and_undo_restores() = runTest {
        instructions["c"] = "Be brief"
        val controller = controller()
        controller.onUserMessageCreated("c", "m-1", directive)
        advanceUntilIdle()
        controller.accept("c")
        advanceUntilIdle()

        assertNull(controller.pending.value["c"])
        assertEquals(listOf("c" to "Be brief\n$span"), writes)
        val toast = toasts.single()
        assertEquals(UiText.Resource(R.string.directive_suggestion_added), toast.message)
        assertEquals(5000L, toast.durationMs)
        val action = toast.action!!
        assertEquals(UiText.Resource(R.string.undo), action.label)

        action.onClick()
        advanceUntilIdle()
        assertEquals("c" to "Be brief", writes.last())
        assertEquals("Be brief", instructions["c"])

        // Empty instructions: the append equals the sentence itself.
        instructions["d"] = ""
        controller.onUserMessageCreated("d", "m-2", directive)
        advanceUntilIdle()
        controller.accept("d")
        advanceUntilIdle()
        assertEquals("d" to span, writes.last())
    }

    @Test
    fun suggestion_skipped_when_already_in_instructions() = runTest {
        val controller = controller()
        instructions["c"] = "Rules:\n$span\nBe brief"
        controller.onUserMessageCreated("c", "m-1", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["c"])

        // Not shown when the append exceeds 8000 code points; shown at exactly 8000.
        val spanLength = span.codePointCount(0, span.length)
        instructions["long"] = "x".repeat(8000 - spanLength)
        controller.onUserMessageCreated("long", "m-2", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["long"])
        instructions["fits"] = "x".repeat(8000 - spanLength - 1)
        controller.onUserMessageCreated("fits", "m-3", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["fits"])

        // Not shown if it is not a persistent convention.
        instructions["plain"] = ""
        controller.onUserMessageCreated("plain", "m-4", "Can you reply in English?")
        advanceUntilIdle()
        assertNull(controller.pending.value["plain"])
        assertTrue(writes.isEmpty())
    }

    @Test
    fun suggestion_accept_resets_ignore_streak() = runTest {
        instructions["c"] = ""
        val controller = controller()
        repeat(2) { index ->
            controller.onUserMessageCreated("c", "m-$index", directive)
            advanceUntilIdle()
            controller.ignore("c")
            advanceUntilIdle()
        }
        assertEquals(2, store.ignoreCount("c"))
        controller.onUserMessageCreated("c", "m-2", directive)
        advanceUntilIdle()
        controller.accept("c")
        advanceUntilIdle()
        assertEquals(0, store.ignoreCount("c"))

        instructions["c"] = ""
        repeat(2) { index ->
            controller.onUserMessageCreated("c", "m-${index + 3}", directive)
            advanceUntilIdle()
            assertNotNull(controller.pending.value["c"])
            controller.ignore("c")
            advanceUntilIdle()
        }
        controller.onUserMessageCreated("c", "m-9", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["c"])
    }

    @Test
    fun suggestion_original_sentence_is_trimmed() = runTest {
        instructions["c"] = ""
        var span: String? = null
        val controller = DirectiveSuggestionController(
            scope = this,
            store = store,
            instructionsOf = { instructions[it] },
            writeInstructions = { id, text -> instructions[id] = text },
            showToast = {},
            ioContext = EmptyCoroutineContext,
            detect = { DirectiveDetection(isDirective = true, span = span) },
            classify = { ai.oriveo.community.core.context.MemoryIntentSuggestion.CONVERSATION_INSTRUCTION },
        )
        suspend fun sentenceFor(text: String): String? {
            controller.onUserMessageCreated("c", "m-${text.hashCode()}", text)
            advanceUntilIdle()
            return controller.pending.value["c"]?.sentence
        }
        // Unicode White_Space at both ends of the span (including full-width space / NBSP) is stripped.
        span = "\u3000 Reply in English.\u00A0\n"
        assertEquals("Reply in English.", sentenceFor("whatever"))
        // A span containing only whitespace counts as empty and falls back to trimming the full text.
        span = " \u3000\t"
        assertEquals("Write in Arabic.", sentenceFor("\u3000Write in Arabic.\u2003"))
        span = null
        assertEquals("Be brief.", sentenceFor("\n Be brief.\u00A0"))
        // Both the span and the full text are empty after trim: not shown.
        span = "\u3000"
        assertNull(sentenceFor(" \u3000 "))
    }

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

    private fun conversation(id: String) = Conversation(
        id = id,
        title = "t",
        providerID = "relay-1",
        providerKind = ProviderKind.Relay,
        modelID = "m-1",
        messages = emptyList(),
        updatedAt = 1L,
    )

    private fun fakePrefs(map: MutableMap<String, Int>): SharedPreferences {
        val editor = mockk<SharedPreferences.Editor>()
        every { editor.putInt(any(), any()) } answers {
            map[firstArg()] = secondArg()
            editor
        }
        every { editor.remove(any()) } answers {
            map.remove(firstArg<String>())
            editor
        }
        every { editor.apply() } just Runs
        val prefs = mockk<SharedPreferences>()
        every { prefs.getInt(any(), any()) } answers { map[firstArg()] ?: secondArg() }
        every { prefs.edit() } returns editor
        return prefs
    }
}
