package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRequestContext
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRuntime
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * End-to-end handling of a Grok subscription rejected upstream with HTTP 426: the real
 * [GrokService] parses the 426 into subscription semantics, and the catch block of the real
 * [ChatRepository] stores the failure.
 *
 * Everything asserted comes from the production path: the stored [ChatMessage] is the argument
 * `conversationRepository.updateMessage` actually received. The test builds no
 * `ProviderServiceError` of its own.
 */
class ChatRepositoryGrokSubscription426Test {

    // The code and message are what the upstream returns to an outdated client; the outer JSON key
    // names follow the shape of the existing tests.
    private val upstream426Body =
        """{"code":"ClientVersionRejected","error":"Your Grok CLI version (1.0.4) is outdated. Please update to version 1.0.13 or later via `grok update` or the installation documentation."}"""

    private val json = Json { ignoreUnknownKeys = true }
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val attachmentStore = mockk<ai.oriveo.community.core.data.attachment.AttachmentStore>(relaxed = true)

    private val repository = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = attachmentStore,
    )

    private val provider = Provider(
        id = "grok-subscription",
        kind = ProviderKind.Grok,
        status = ProviderConnectionState.Connected,
        models = emptyList(),
        catalogModels = emptyList(),
        apiKey = "connected-marker",
        apiKeyPreview = "",
        authMode = ProviderAuthMode.Subscription,
    )

    private val conversation = Conversation(
        id = "conv-grok-426",
        title = "Grok chat",
        providerID = provider.id,
        providerKind = ProviderKind.Grok,
        modelID = "grok-4.6",
    )

    private var upstreamCalls = 0

    @Test
    fun `a 426 through the real GrokService and ChatRepository is stored as the subscription unavailable copy`() = runTest {
        arrange(clientIdentifier = "oriveo-426-stored-detail")

        send()

        assertEquals(1, upstreamCalls)
        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
        val failed = updates.filter { it.role == ChatRole.Assistant && it.state == ChatMessageState.Failed }
        assertEquals(1, failed.size)
        val detail = failed.single().errorDetail
        assertEquals(GrokSubscriptionFailureReason.ClientVersionRejected.userMessage, detail)
        assertFalse("stored copy must not carry the upstream text: $detail", detail.orEmpty().contains("grok update"))
        assertFalse("stored copy must not carry the upstream text: $detail", detail.orEmpty().contains("1.0.13"))
    }

    private fun arrange(clientIdentifier: String) {
        val client = HttpClient(
            MockEngine {
                upstreamCalls += 1
                respond(
                    upstream426Body,
                    HttpStatusCode.UpgradeRequired,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        every { providerRepository.serviceFor(provider) } returns
            GrokService(client, json, TransportRegistry(json))
        coEvery { providerRepository.prepareGrokSubscription(provider.id) } returns
            GrokSubscriptionRuntime.PrepareResult.Success(
                GrokSubscriptionRuntime.Prepared(
                    accessToken = "access-token",
                    context = GrokSubscriptionRequestContext(
                        chatUrl = "https://cli-chat-proxy.grok.com/v1/chat/completions",
                        responsesUrl = "https://cli-chat-proxy.grok.com/v1/responses",
                        requiredHeaders = mapOf(
                            "x-grok-client-version" to "1.0.4",
                            "x-grok-client-identifier" to clientIdentifier,
                            "x-grok-client-surface" to "grok-build",
                            "x-xai-token-auth" to "xai-grok-cli",
                        ),
                    ),
                    didRefresh = false,
                ),
            )
    }

    private suspend fun send() {
        repository.sendMessage(
            conversation = conversation,
            text = "hi",
            provider = provider,
            modelID = "grok-4.6",
            existingMessages = emptyList(),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow<String?>(null),
            ),
        )
    }
}
