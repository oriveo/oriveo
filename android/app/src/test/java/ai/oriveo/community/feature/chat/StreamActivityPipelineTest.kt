package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the lifetime of an activity: set when the start signal is observed, cleared by the next
 * body delta, and cleared when the stream finishes or fails.
 *
 * Real SSE bytes go into the production [AnthropicService] and through the real [ChatRepository]
 * into the outputs; no [StreamEvent] is built by hand along the way. To see the intermediate
 * states, a read-only probe wraps the service: before each event is handed to the repository it
 * records the activity currently on the outputs, which is the state after the previous event.
 */
class StreamActivityPipelineTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>(relaxed = true)
    private val attachmentStore = mockk<AttachmentStore>(relaxed = true)

    private val repository = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = attachmentStore,
    )

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private val searchStart = ProviderTestFixtures.anthropicEvent(
        "content_block_start",
        """{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01","name":"web_search","input":{}}}""",
    )
    private val searchResult = ProviderTestFixtures.anthropicEvent(
        "content_block_start",
        """{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_01","content":[{"type":"web_search_result","url":"https://example.com/a","title":"A"}]}}""",
    )

    private fun text(index: Int, value: String) = ProviderTestFixtures.anthropicEvent(
        "content_block_delta",
        """{"type":"content_block_delta","index":$index,"delta":{"type":"text_delta","text":"$value"}}""",
    )

    private fun thinking(index: Int, value: String) = ProviderTestFixtures.anthropicEvent(
        "content_block_delta",
        """{"type":"content_block_delta","index":$index,"delta":{"type":"thinking_delta","thinking":"$value"}}""",
    )

    private val messageStart = ProviderTestFixtures.anthropicEvent(
        "message_start",
        """{"type":"message_start","message":{"usage":{"input_tokens":2}}}""",
    )
    private val messageDelta = ProviderTestFixtures.anthropicEvent(
        "message_delta",
        """{"type":"message_delta","usage":{"output_tokens":1}}""",
    )

    @Test
    fun `activity is set by the search start and cleared by the next body delta`() = runTest {
        val probe = send(
            messageStart,
            text(0, "Let me look that up."),
            searchStart,
            searchResult,
            text(3, "Sunny."),
            messageDelta,
        )

        // Self-check: the probe really saw the activity event the production parser emitted, so
        // the assertions below are not vacuous.
        assertEquals(1, probe.seen.count { it.event is StreamEvent.Activity })

        assertNull("no activity during the leading body text", probe.activityBefore { it is StreamEvent.Activity })
        // The search result event does not clear it: between the results coming back and the
        // model speaking, the user is still waiting.
        assertEquals(StreamActivity.WebSearch, probe.activityBefore { it is StreamEvent.Citations })
        assertEquals(
            "the activity stays until the next body text arrives",
            StreamActivity.WebSearch,
            probe.activityBefore { it is StreamEvent.Delta && it.text == "Sunny." },
        )
        assertNull("the next body delta must clear the activity", probe.activityBefore { it is StreamEvent.Done })
        assertNull(probe.outputs.streamingActivity.value)
    }

    @Test
    fun `non-empty reasoning clears the activity`() = runTest {
        val probe = send(
            messageStart,
            text(0, "Let me look that up."),
            searchStart,
            thinking(2, "The results say"),
            messageDelta,
        )

        assertEquals(
            StreamActivity.WebSearch,
            probe.activityBefore { it is StreamEvent.Reasoning },
        )
        assertNull("a non-empty reasoning delta must clear the activity", probe.activityBefore { it is StreamEvent.Done })
    }

    @Test
    fun `stream end clears an activity that no content ever followed`() = runTest {
        val probe = send(
            messageStart,
            text(0, "Let me look that up."),
            searchStart,
            messageDelta,
        )

        assertEquals(
            "the activity is still there before the stream ends, since no later content cleared it",
            StreamActivity.WebSearch,
            probe.activityBefore { it is StreamEvent.Done },
        )
        assertNull("the end of the stream must clear the activity", probe.outputs.streamingActivity.value)
    }

    @Test
    fun `stream failure clears the activity`() = runTest {
        val probe = send(
            messageStart,
            text(0, "Let me look that up."),
            searchStart,
            ProviderTestFixtures.anthropicEvent(
                "error",
                """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""",
            ),
        )

        assertEquals(1, probe.seen.count { it.event is StreamEvent.Activity })
        assertTrue("the failure path should never reach Done", probe.seen.none { it.event is StreamEvent.Done })
        assertNull("a failed stream must clear the activity", probe.outputs.streamingActivity.value)
    }

    // ── fixtures ────────────────────────────────────────────────────────────────

    private data class Seen(val event: StreamEvent, val activityBefore: StreamActivity?)

    private class Probe(val outputs: ConversationStreamingOutputs) {
        val seen = mutableListOf<Seen>()

        /** The activity on the outputs just before the first matching event is handed to the repository. */
        fun activityBefore(match: (StreamEvent) -> Boolean): StreamActivity? =
            seen.first { match(it.event) }.activityBefore
    }

    private suspend fun send(vararg frames: String): Probe {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-3",
                resolveMap = mapOf("claude-3" to "claude-3"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "claude-3")),
            ),
        )
        val provider = Provider(
            id = "p-anthropic",
            kind = ProviderKind.Anthropic,
            status = ProviderConnectionState.Connected,
            models = emptyList(),
            catalogModels = emptyList(),
            apiKey = "sk-test",
            apiKeyPreview = "sk-...est",
        )
        val probe = Probe(
            ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow<String?>(null),
            ),
        )
        val production = AnthropicService(
            HttpClient(
                MockEngine {
                    respond(
                        content = ProviderTestFixtures.anthropicStream(*frames),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                },
            ),
            json,
            TransportRegistry(json),
        )
        every { providerRepository.serviceFor(provider) } returns object : ProviderService by production {
            override fun sendMessageStream(
                apiKey: String,
                modelID: String,
                messages: List<ChatMessage>,
                baseUrl: String?,
                supportsImageGen: Boolean,
                reasoningMode: ReasoningMode,
                webSearchEnabled: Boolean,
                requestOptions: ChatRequestOptions,
            ): Flow<StreamEvent> = production.sendMessageStream(
                apiKey, modelID, messages, baseUrl, supportsImageGen, reasoningMode, webSearchEnabled, requestOptions,
            ).onEach { probe.seen += Seen(it, probe.outputs.streamingActivity.value) }
        }

        repository.sendMessage(
            conversation = Conversation(
                id = "conv-activity",
                title = "Search",
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = "claude-3",
            ),
            text = "weather?",
            provider = provider,
            modelID = "claude-3",
            existingMessages = emptyList(),
            outputs = probe.outputs,
        )
        return probe
    }
}
