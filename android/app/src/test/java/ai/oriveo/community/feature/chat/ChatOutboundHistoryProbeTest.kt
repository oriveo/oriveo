package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The outbound-history video flag of the model panel file card: the same sequence before and after a streamed answer is persisted must follow the outbound answer. */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatOutboundHistoryProbeTest {
    private val conversationRepository = mockk<ConversationRepository>()

    private fun message(id: String, role: ChatRole, text: String, state: ChatMessageState, attachments: List<Attachment>? = null) =
        ChatMessage(
            id = id, role = role, text = text, providerKind = ProviderKind.Gemini, providerName = "Gemini",
            modelName = "gemini-3-flash", state = state, attachments = attachments,
        )

    private fun conversation(messages: List<ChatMessage>) = Conversation(
        id = "conversation-1", title = "Chat", providerID = "gemini-1", providerKind = ProviderKind.Gemini,
        modelID = "gemini-3-flash", messages = messages,
    )

    /**
     * After a user message with a video is sent, the assistant placeholder is persisted first (empty body, removed by outbound normalization -> the video user message becomes adjacent to this turn's placeholder, old dropped and new kept -> false);
     * once the answer is delivered the last id is unchanged and the flag must be recomputed to true (the next real send carries the video and goes through generateContent).
     */
    @Test
    fun `flag is recomputed when the streaming answer settles under the same message id`() = runTest {
        val video = Attachment(id = "v", kind = AttachmentKind.Video, fileName = "clip.mp4", mimeType = "video/mp4", base64Data = "AAAA")
        val user = message("u1", ChatRole.User, "What happens?", ChatMessageState.Delivered, listOf(video))
        val generating = conversation(listOf(user, message("a1", ChatRole.Assistant, "", ChatMessageState.Generating)))
        val delivered = conversation(listOf(user, message("a1", ChatRole.Assistant, "A ball rolls.", ChatMessageState.Delivered)))

        var stored = generating
        coEvery { conversationRepository.getWithMessages("conversation-1") } answers { stored }
        val states = MutableStateFlow(ConversationRenderState(conversation = generating))
        // The subscription lives in a separate scope on the same scheduler as the test and is cancelled at the end of the test.
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler) + SupervisorJob())
        val flag = ChatOutboundHistoryProbe({ mockk<AttachmentStore>(relaxed = true) }, conversationRepository)
            .hasVideoFlow(states, scope)
        scope.launch { flag.collect {} }
        testScheduler.advanceUntilIdle()
        assertFalse("with an empty placeholder answer, outbound normalization drops the video user message", flag.value)

        stored = delivered
        states.value = ConversationRenderState(conversation = delivered)
        testScheduler.advanceUntilIdle()
        assertTrue("after the answer is persisted the next send carries the video", flag.value)
        scope.cancel()
    }
}
