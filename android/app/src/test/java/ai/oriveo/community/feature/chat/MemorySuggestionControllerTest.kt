package ai.oriveo.community.feature.chat

import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import android.content.SharedPreferences
import androidx.room.Room
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryProposeMode
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import ai.oriveo.community.feature.settings.MemoryItemGroup
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A new send is routed by classify to the "Save to memory?" bar, the "Set as instruction" bar, or no bar.
 * In tool mode the v1 routing does not run; the first propose candidate of the turn becomes the bar, which hangs under that turn's assistant answer and appears only after streaming ends.
 */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class MemorySuggestionControllerTest {
    private val account = "account-1"
    private val conversationId = "conversation-1"

    private val db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
        .allowMainThreadQueries()
        .setQueryExecutor { it.run() }
        .setTransactionExecutor { it.run() }
        .build()
    private val items: MemoryItemRepository
    private val candidates: MemoryCandidateRepository

    init {
        val preferences = AppPreferencesRepository(
            preferenceDao = db.preferenceDao(),
        )
        items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
        candidates = MemoryCandidateRepository(dao = db.memoryCandidateDao(), items = items, io = Dispatchers.Unconfined)
    }

    @After
    fun tearDown() = db.close()

    /** Sentences are taken by id from the cases of the shared memory-intent.v1.json contract, not hard-coded. */
    private val cases: Map<String, JsonObject> by lazy {
        ContextContractFixture.cases(ContextContractFixture.load("memory-intent.v1.json"), "cases").associateBy { it.id() }
    }

    private fun text(id: String): String = cases.getValue(id)["text"]!!.jsonPrimitive.content

    private fun expected(id: String, key: String): String =
        cases.getValue(id)["expected"]!!.jsonObject[key]!!.jsonPrimitive.content

    /**
     * Send chain: a new user send -> instruction detection + candidate generation -> the two suggestion bars. [chatScope] stands in for the chat page's viewModelScope,
     * and button actions run on [scope] (app level).
     */
    private inner class Harness(
        scope: TestScope,
        useMemory: Boolean,
        chatScope: CoroutineScope = scope,
        mode: MemoryProposeMode = MemoryProposeMode.FALLBACK,
    ) {
        val toasts = mutableListOf<GlobalSnackbarMessage>()
        private val convFlow = MutableStateFlow(conversation().copy(folderID = "folder-1", useMemory = useMemory))
        var conv: Conversation
            get() = convFlow.value
            set(value) {
                convFlow.value = value
            }

        /** State of the assistant answer persisted at send time; Generating means it is still streaming. */
        var replyState = ChatMessageState.Delivered
        val directive = DirectiveSuggestionController(
            scope = scope,
            store = DirectiveSuggestionStore(prefsProvider = { emptyPrefs() }),
            instructionsOf = { "" },
            writeInstructions = { _, _ -> },
            showToast = {},
            ioContext = EmptyCoroutineContext,
        )
        val memory = MemorySuggestionController(
            scope = chatScope,
            activeConversationId = MutableStateFlow(conversationId),
            latestUserMessageId = { _ -> conv.messages.lastOrNull { it.role == ChatRole.User }?.id },
            actionScope = scope,
            stateScope = scope.backgroundScope,
            ioContext = EmptyCoroutineContext,
            candidates = candidates,
            items = items,
            accountId = { account },
            showToast = { toasts += it },
            observeMessages = { _ -> convFlow.map { it.messages } },
        )
        private var sends = 0
        private val provider = provider()
        private val coordinator: ChatSendCommandCoordinator

        init {
            val providerRepository = mockk<ProviderRepository>()
            val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
            val conversationRepository = mockk<ConversationRepository>(relaxed = true)
            coEvery { providerRepository.getById(provider.id) } returns provider
            coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
            coEvery { conversationRepository.getWithMessages(conversationId) } answers { conv }
            coordinator = ChatSendCommandCoordinator(
                viewModelScope = scope,
                appPreferencesRepository = appPreferencesRepository,
                providerRepository = providerRepository,
                conversationRepository = conversationRepository,
                currentConversation = { conv },
                currentConversationId = { conversationId },
                onProviderSelectionError = {},
                onProviderResolutionError = {},
                onModelSelectionError = {},
                onDisclosureRequired = { _, _ -> },
                onConversationActivated = {},
                onComposerConsumed = {},
                requestPin = {},
                onSendSettled = {},
                launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
                directiveSuggestions = directive,
                launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, _ ->
                    sends++
                    appendUserMessage("message-$sends", sent)
                    onUserMessageCreated("message-$sends", sent)
                    appendReply("reply-$sends", replyState)
                },
                memoryCandidates = candidates,
                memoryAccountId = { account },
                memoryScope = scope,
                memorySuggestions = memory,
                memoryProposeMode = { _, _, _ -> mode },
            )
        }

        fun appendUserMessage(id: String, text: String) {
            conv = conv.copy(messages = conv.messages + userMessage(id, text))
        }

        fun appendReply(id: String, state: ChatMessageState) {
            conv = conv.copy(messages = conv.messages + assistantMessage(id, state))
        }

        fun finishReply(id: String) {
            conv = conv.copy(
                messages = conv.messages.map { if (it.id == id) it.copy(state = ChatMessageState.Delivered) else it },
            )
        }

        suspend fun TestScope.send(text: String) {
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            // advanceUntilIdle does not run the state collection in backgroundScope; runCurrent lets current catch up.
            runCurrent()
        }
    }

    /** The bar hangs under the assistant reply, so its lines start at the reply's leading edge. */
    @Test
    fun `suggestion bar hangs under the assistant answer`() {
        assertEquals(androidx.compose.ui.Alignment.Start, MemorySuggestionRowLayout.horizontalAlignment)
        assertEquals(androidx.compose.ui.text.style.TextAlign.Start, MemorySuggestionRowLayout.textAlign)
    }

    /** The suggestion bar follows the iOS look: a rounded card background plus 36dp capsule buttons (same as the memory inbox action buttons). */
    @Test
    fun `suggestion bar is a card background with capsule buttons`() {
        assertEquals(ai.oriveo.community.ui.theme.OriveoRadius.md, MemorySuggestionRowLayout.cardRadius)
        assertEquals(androidx.compose.foundation.shape.CircleShape, MemorySuggestionRowLayout.actionShape)
        assertEquals(36f, MemorySuggestionRowLayout.actionHeight.value, 0f)
    }

    /** The set-as-instruction bar has the prompt on top and the buttons below (same as iOS and the memory suggestion bar). */
    @Test
    fun `set-as-instruction bar puts prompt and buttons on two rows`() {
        assertEquals(true, MemorySuggestionRowLayout.directiveStacksActionsBelowPrompt)
    }

    /** The secondary capsule, composited on the card background, stays distinguishable from it (dark / light), so it no longer looks like plain text. */
    @Test
    fun `secondary capsule fill is distinguishable from the card background`() {
        listOf(false to ai.oriveo.community.ui.theme.LightOriveoColors, true to ai.oriveo.community.ui.theme.DarkOriveoColors)
            .forEach { (isDark, palette) ->
                // The card background is translucent: composite it onto this theme's page background first, then composite the capsule on top and compare luminance.
                val base = if (isDark) androidx.compose.ui.graphics.Color.Black else androidx.compose.ui.graphics.Color.White
                val card = MemorySuggestionRowLayout.cardFill(palette).compositeOver(palette.background.compositeOver(base))
                val pill = MemorySuggestionRowLayout.secondaryActionFill(isDark).compositeOver(card)
                val delta = kotlin.math.abs(pill.luminance() - card.luminance())
                org.junit.Assert.assertNotEquals("isDark=$isDark", card, pill)
                org.junit.Assert.assertTrue("isDark=$isDark luminance delta=$delta", delta > 0.02f)
            }
    }

    @Test
    fun memory_bar_shown_after_candidate_generated() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }

        val candidate = candidates.pending(account).single()
        assertEquals(expected("zh_explicit_01_golden", "proposition"), candidate.content)
        assertEquals(MemorySuggestion(conversationId, "reply-1", candidate), harness.memory.current.value)
        assertNull(harness.directive.pending.value[conversationId])

        // The bar only recognizes the last user message in the conversation's real message list and hangs under the assistant answer after it: if it is not in the list, no bar appears.
        harness.memory.onUserMessageCreated(conversationId, "message-9", text("zh_explicit_01_golden"), useMemory = true)
        harness.memory.onCandidateGenerated(conversationId, "message-9", candidate)
        advanceUntilIdle()
        runCurrent()
        assertNull(harness.memory.current.value)
        harness.appendUserMessage("message-9", text("zh_explicit_01_golden"))
        harness.appendReply("reply-9", ChatMessageState.Delivered)
        harness.memory.onCandidateGenerated(conversationId, "message-9", candidate)
        advanceUntilIdle()
        runCurrent()
        assertEquals("reply-9", harness.memory.current.value?.messageId)
    }

    @Test
    fun global_directive_routes_to_memory_bar() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_implicit_04_golden")) }

        val candidate = candidates.pending(account).single()
        assertEquals(MemorySuggestion(conversationId, "reply-1", candidate), harness.memory.current.value)
        // A global convention shows only the memory bar, not the "Set as instruction" bar.
        assertNull(harness.directive.pending.value[conversationId])
    }

    @Test
    fun conversation_directive_keeps_instruction_bar() = runTest {
        val harness = Harness(this, useMemory = true)
        // The lexical bar only appears for suggestionLanguages, so use a sentence in a gated language (zh-Hans).
        with(harness) { send(text("zh_implicit_03_golden")) }

        assertEquals(
            DirectiveSuggestion(conversationId, "message-1", expected("zh_implicit_03_golden", "span")),
            harness.directive.pending.value[conversationId],
        )
        assertNull(harness.memory.current.value)
        assertTrue(candidates.pending(account).isEmpty())
    }

    @Test
    fun secret_message_shows_no_bar() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("mixed_sensitive_02")) }

        assertNull(harness.memory.current.value)
        assertNull(harness.directive.pending.value[conversationId])
        assertTrue(db.memoryCandidateDao().list(account).isEmpty())
    }

    @Test
    fun memory_off_shows_hint_without_candidate() = runTest {
        val harness = Harness(this, useMemory = false)
        with(harness) { send(text("zh_explicit_01_golden")) }

        val bar = harness.memory.current.value
        assertEquals(MemorySuggestion(conversationId, "reply-1", candidate = null), bar)
        assertTrue(bar!!.memoryOff)
        assertNull(harness.directive.pending.value[conversationId])
        assertTrue(db.memoryCandidateDao().list(account).isEmpty())

        // With memory off, only sentences classified as memory show a prompt.
        with(harness) { send(text("en_transient_01_golden")) }
        assertNull(harness.memory.current.value)
    }

    @Test
    fun next_send_clears_bar_keeps_pending() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()
        assertEquals(candidate, harness.memory.current.value?.candidate)

        with(harness) { send(text("en_transient_01_golden")) }
        assertNull(harness.memory.current.value)
        // A bar disappearing does not count as ignoring: the candidate stays pending.
        val stillPending = candidates.pending(account).single()
        assertEquals(candidate.id, stillPending.id)
        assertEquals(MemoryCandidateStatus.PENDING, stillPending.status)

        // Switching conversations likewise only drops the bar.
        with(harness) { send(text("zh_implicit_04_golden")) }
        assertEquals("reply-3", harness.memory.current.value?.messageId)
        harness.memory.retainOnly("conversation-2")
        assertNull(harness.memory.pending.value[conversationId])
        assertEquals(2, candidates.pending(account).size)
    }

    @Test
    fun save_creates_item_and_undo_deletes_it() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()

        harness.memory.save(conversationId)
        advanceUntilIdle()
        runCurrent()

        assertNull(harness.memory.current.value)
        assertTrue(candidates.pending(account).isEmpty())
        val item = items.list(account).single()
        assertEquals(candidate.content, item.content)
        assertEquals(candidate.proposedKind, item.kind)
        assertEquals(candidate.scope, item.scope)
        assertEquals(candidate.source.type, item.source.type)
        assertEquals(conversationId, item.source.conversationId)
        assertEquals(listOf("message-1"), item.source.messageIds)
        assertEquals(candidate.confidence, item.confidence, 0.0)

        val toast = harness.toasts.single()
        assertEquals(UiText.Resource(R.string.memory_suggestion_saved), toast.message)
        assertEquals(UiText.Resource(R.string.undo), toast.action?.label)
        assertEquals(5000L, toast.durationMs)

        // Undo = the item repository deletes the just-created item normally (writes a tombstone).
        toast.action!!.onClick()
        advanceUntilIdle()
        assertTrue(items.list(account).all { it.deletedAt != null })
        assertNull(items.list(account).firstOrNull { it.id == item.id && it.deletedAt == null })
    }

    @Test
    fun undo_survives_leaving_chat() = runTest {
        val chat = CoroutineScope(coroutineContext.minusKey(Job) + Job())
        val harness = Harness(this, useMemory = true, chatScope = chat)
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()

        // Leave the chat page right after tapping Save: the chat page scope is cancelled, yet save and undo must still complete.
        harness.memory.save(conversationId)
        chat.cancel()
        advanceUntilIdle()

        val item = items.list(account).single()
        assertEquals(candidate.content, item.content)
        val toast = harness.toasts.single()
        assertEquals(UiText.Resource(R.string.memory_suggestion_saved), toast.message)

        toast.action!!.onClick()
        advanceUntilIdle()
        assertTrue(items.list(account).all { it.deletedAt != null })
        assertNull(items.list(account).firstOrNull { it.id == item.id && it.deletedAt == null })
    }

    @Test
    fun edit_saves_edited_content() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()

        harness.memory.edit(conversationId)
        val opened = harness.memory.editor.value
        assertNotNull(opened)
        assertNull(opened!!.state.itemId)
        assertEquals(candidate.content, opened.state.text)
        assertEquals(MemoryItemGroup.of(candidate.proposedKind) ?: MemoryItemGroup.About, opened.state.group)

        // Cancel keeps the bar and leaves the candidate untouched.
        harness.memory.dismissEditor()
        advanceUntilIdle()
        assertNull(harness.memory.editor.value)
        assertEquals(candidate, harness.memory.current.value?.candidate)

        harness.memory.edit(conversationId)
        harness.memory.updateEditorText("  \u6211\u504f\u597d\u7b80\u77ed\u76f4\u63a5\u7684\u56de\u7b54  ")
        harness.memory.saveEditor()
        advanceUntilIdle()
        runCurrent()

        assertNull(harness.memory.editor.value)
        assertNull(harness.memory.current.value)
        assertTrue(candidates.pending(account).isEmpty())
        val item = items.list(account).single()
        assertEquals("\u6211\u504f\u597d\u7b80\u77ed\u76f4\u63a5\u7684\u56de\u7b54", item.content)
        // Group unchanged: kind follows the candidate; scope unchanged; an edited body sets confidence = 1.0.
        assertEquals(candidate.proposedKind, item.kind)
        assertEquals(candidate.scope, item.scope)
        assertEquals(candidate.source.type, item.source.type)
        assertEquals(1.0, item.confidence, 0.0)
        assertEquals(UiText.Resource(R.string.memory_suggestion_saved), harness.toasts.single().message)

        // kind is given only when the group changed.
        with(harness) { send(text("zh_implicit_04_golden")) }
        harness.memory.edit(conversationId)
        harness.memory.updateEditorGroup(MemoryItemGroup.Projects)
        harness.memory.saveEditor()
        advanceUntilIdle()
        assertEquals(MemoryKind.PROJECT, items.list(account).single { it.content != item.content }.kind)
    }

    @Test
    fun ignore_rejects_candidate() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()

        harness.memory.ignore(conversationId)
        advanceUntilIdle()
        runCurrent()

        assertNull(harness.memory.current.value)
        assertTrue(candidates.pending(account).isEmpty())
        assertEquals(MemoryCandidateStatus.REJECTED, candidates.get(account, candidate.id)?.status)
        assertTrue(items.list(account).isEmpty())
        assertTrue(harness.toasts.isEmpty())
    }

    @Test
    fun no_candidate_becomes_active_without_accept() = runTest {
        val harness = Harness(this, useMemory = true)
        with(harness) { send(text("zh_explicit_01_golden")) }
        with(harness) { send(text("zh_implicit_04_golden")) }

        assertEquals(2, candidates.pending(account).size)
        assertTrue(candidates.pending(account).all { it.status == MemoryCandidateStatus.PENDING })
        // A candidate never becomes an item directly: without accept there are none.
        assertTrue(items.list(account).isEmpty())
    }

    @Test
    fun memory_bar_waits_for_reply_streaming_to_end() = runTest {
        val harness = Harness(this, useMemory = true)
        harness.replyState = ChatMessageState.Generating
        with(harness) { send(text("zh_explicit_01_golden")) }
        val candidate = candidates.pending(account).single()

        // The answer is still streaming: the candidate exists but the bar does not appear (avoids the streaming height floor).
        assertNull(harness.memory.current.value)

        harness.finishReply("reply-1")
        runCurrent()
        assertEquals(MemorySuggestion(conversationId, "reply-1", candidate), harness.memory.current.value)

        // Withdrawal follows the assistant message.
        harness.memory.withdraw(conversationId, "reply-1")
        runCurrent()
        assertNull(harness.memory.current.value)
        assertEquals(candidate.id, candidates.pending(account).single().id)
    }

    @Test
    fun tool_mode_skips_v1_memory_routing() = runTest {
        val harness = Harness(this, useMemory = true, mode = MemoryProposeMode.TOOL)
        with(harness) { send(text("zh_explicit_01_golden")) }

        // Tool mode: the v1 routing does not run, no candidate is generated and no bar appears.
        assertNull(harness.memory.current.value)
        assertTrue(db.memoryCandidateDao().list(account).isEmpty())

        // Tool mode does not run the lexical "Set as instruction" bar either (only the model's instruct call raises it), even for a gated-language sentence.
        with(harness) { send(text("zh_implicit_03_golden")) }
        assertNull(harness.directive.pending.value[conversationId])
        assertTrue(db.memoryCandidateDao().list(account).isEmpty())
    }

    @Test
    fun first_proposed_candidate_becomes_bar() = runTest {
        val harness = Harness(this, useMemory = true, mode = MemoryProposeMode.TOOL)
        val userText = text("zh_explicit_01_golden")
        with(harness) { send(userText) }

        suspend fun propose(proposition: String, prior: Int) = candidates.propose(
            accountId = account,
            argumentsJson = buildJsonObject {
                put("proposition", proposition)
                put("kind", "preference")
                put("scope", "unspecified")
                put("sourceQuote", userText)
            }.toString(),
            priorInTurn = prior,
            userText = userText,
            messageId = "message-1",
            conversationId = conversationId,
            folderId = "folder-1",
        )
        val first = propose(expected("zh_explicit_01_golden", "proposition"), 0)
        assertNotNull(first)
        harness.memory.onProposedCandidate(conversationId, "message-1", first!!)
        val second = propose("Prefers dark mode in every app", 1)
        assertNotNull(second)
        harness.memory.onProposedCandidate(conversationId, "message-1", second!!)
        advanceUntilIdle()
        runCurrent()

        // The first create of the turn becomes the bar under the assistant answer; the second stays only as a pending candidate.
        assertEquals(MemorySuggestion(conversationId, "reply-1", first), harness.memory.current.value)
        assertEquals(listOf("message-1"), first.source.messageIds)
        assertEquals(setOf(first.id, second.id), candidates.pending(account).map { it.id }.toSet())
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

    private fun userMessage(id: String, text: String) = ChatMessage(
        id = id,
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Relay,
        providerName = "Relay",
        modelName = "Model",
        state = ChatMessageState.Delivered,
    )

    private fun assistantMessage(id: String, state: ChatMessageState) = ChatMessage(
        id = id,
        role = ChatRole.Assistant,
        text = "ok",
        providerKind = ProviderKind.Relay,
        providerName = "Relay",
        modelName = "Model",
        state = state,
    )

    private fun conversation() = Conversation(
        id = conversationId,
        title = "t",
        providerID = "relay-1",
        providerKind = ProviderKind.Relay,
        modelID = "m-1",
        messages = emptyList(),
        updatedAt = 1L,
    )

    private fun emptyPrefs(): SharedPreferences {
        val prefs = mockk<SharedPreferences>(relaxed = true)
        every { prefs.getInt(any(), any()) } answers { secondArg() }
        return prefs
    }
}
