package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.attachment.StoredImage
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.IOException
import java.util.Base64
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Some upstreams (e.g. image generation through a relay) stream images back inlined in the text as `![](data:image/...;base64,...)`.
 * Persisting the streaming partial verbatim pushes the row past the 2MB CursorWindow; generation then fails, the success-path inline-image extraction never runs, and the corrupt row stays forever.
 * Pins: the persisted partial carries no inline images; the failed final state saves already-received images as attachments and its text carries no base64.
 */
@RunWith(RobolectricTestRunner::class)
class ChatRepositoryInlineImagePersistenceTest {

    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val providerService = mockk<ProviderService>()
    private val attachmentStore = mockk<AttachmentStore>(relaxed = true).also { store ->
        every { store.saveOriginalImage(any(), any()) } returns StoredImage("IMG-1", "image/png")
    }

    private val repository = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = attachmentStore,
    )

    private val imageBase64 = Base64.getEncoder().encodeToString(ByteArray(7_500) { 7 })

    @Test
    fun `failed stream persists inline image as attachment and never writes base64 into text`() = runTest {
        val partialTexts = mutableListOf<String>()
        coEvery { conversationRepository.updatePartialText(any(), capture(partialTexts)) } returns 1
        val finalMessages = mutableListOf<ChatMessage>()
        coEvery { conversationRepository.updateMessage(any(), capture(finalMessages)) } returns Unit

        send(
            flow {
                emit(StreamEvent.Delta("Here is your picture:\n![generated](data:image/png;base64,$imageBase64)\n"))
                emit(StreamEvent.Delta("Want another one?"))
                throw IOException("connection reset")
            },
        )

        assertTrue("a long stream should trigger a partial write", partialTexts.isNotEmpty())
        assertTrue(partialTexts.none { it.contains("data:image") })
        val failed = finalMessages.last()
        assertEquals(ChatMessageState.Failed, failed.state)
        assertFalse(failed.text.contains("data:image"))
        assertTrue(failed.text.contains("Want another one?"))
        assertEquals(listOf("IMG-1"), failed.attachments.orEmpty().map { it.localImageId })
        assertTrue(failed.attachments.orEmpty().all { it.base64Data == null })
    }

    // Completion extracts inline images the same way as the failure path: base64 wrapped at 76 columns must become an attachment, never stay in the persisted text
    @Test
    fun `completed stream with line wrapped inline image never writes base64 into text`() = runTest {
        val finalMessages = mutableListOf<ChatMessage>()
        coEvery { conversationRepository.updateMessage(any(), capture(finalMessages)) } returns Unit
        val wrapped = imageBase64.chunked(76).joinToString("\n")
        val body = "Here is your picture:\n![generated](data:image/png;base64,$wrapped)\nWant another one?"

        send(
            flow {
                emit(StreamEvent.Delta(body))
                emit(StreamEvent.Done(ProviderChatResult(text = body)))
            },
        )

        val delivered = finalMessages.last()
        assertEquals(ChatMessageState.Delivered, delivered.state)
        assertFalse(delivered.text.contains("data:image"))
        assertTrue(delivered.text.contains("Want another one?"))
        assertEquals(listOf("IMG-1"), delivered.attachments.orEmpty().map { it.localImageId })
        assertTrue(delivered.attachments.orEmpty().all { it.base64Data == null })
    }

    private fun provider() = Provider(
        id = "p-openai",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "sk-openai",
    )

    private suspend fun send(stream: Flow<StreamEvent>) {
        val provider = provider()
        every { providerRepository.serviceFor(provider, any()) } returns providerService
        every {
            providerService.sendMessageStream(
                apiKey = any(),
                modelID = any(),
                messages = any(),
                baseUrl = any(),
                supportsImageGen = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
            )
        } returns stream
        repository.sendMessage(
            conversation = Conversation(
                id = "conv-1",
                title = "test",
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = "gpt-5",
            ),
            text = "draw a cat",
            provider = provider,
            modelID = "gpt-5",
            existingMessages = emptyList(),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow<String?>(null),
            ),
        )
    }
}
