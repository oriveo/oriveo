package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayChatBuildExtras
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolCallFunction
import ai.oriveo.community.core.tools.ToolLoopToolChoice
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Anthropic allows at most 4 cache_control breakpoints per request. With 5 images in the current
 * turn plus an image in history, the request body of both production paths (direct Anthropic and
 * relay) must carry no more than 1 cache_control.
 */
class AnthropicCacheBreakpointTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val modelId = "claude-haiku-4-5"

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun image(id: String) = Attachment(
        id = id,
        kind = AttachmentKind.Image,
        fileName = "$id.png",
        mimeType = "image/png",
        base64Data = "iVBORw0KGgo$id",
    )

    private fun conversation(): List<ChatMessage> {
        val history = ProviderTestFixtures.userMessage("What is in this picture?", ProviderKind.Anthropic, modelId)
            .copy(attachments = listOf(image("h1")))
        val answer = ChatMessage(
            id = "a1",
            role = ChatRole.Assistant,
            text = "A cat.",
            providerKind = ProviderKind.Anthropic,
            providerName = "Anthropic",
            modelName = modelId,
            state = ChatMessageState.Delivered,
        )
        val current = ProviderTestFixtures.userMessage("Compare these five.", ProviderKind.Anthropic, modelId)
            .copy(attachments = (1..5).map { image("c$it") })
        return listOf(history, answer, current)
    }

    private fun countCacheControl(body: String): Int = Regex("\"cache_control\"").findAll(body).count()

    private fun imageBlocks(messages: JsonArray): Int = messages.sumOf { message ->
        (message.jsonObject["content"] as? JsonArray)?.count {
            it.jsonObject["type"]?.jsonPrimitive?.content == "image"
        } ?: 0
    }

    /** Sends once through the production direct path (AnthropicService.sendMessageStream) and returns the request body captured by MockEngine. */
    private suspend fun officialBody(messages: List<ChatMessage>, options: ChatRequestOptions = ChatRequestOptions()): String {
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                if (body == null) {
                    body = when (val content = request.body) {
                        is TextContent -> content.text
                        is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                        else -> error("unexpected request body ${content::class}")
                    }
                }
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            },
        ) { install(ContentNegotiation) { json(json) } }

        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = messages,
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = options,
            ).toList()
        }
        return assertNotNull("production path sent no request", body).let { body!! }
    }

    private fun relayBody(messages: List<ChatMessage>, options: ChatRequestOptions = ChatRequestOptions()): String =
        buildAnthropicBody(
            modelID = modelId,
            messages = messages,
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = options,
            buildExtras = RelayChatBuildExtras(keepImageAttachments = true),
        )

    /** wire-system.v1 system_history_and_dynamic_block: yields messages and options in the shape of transportInput ([D] is already appended to the end of the last user text). */
    private class DynamicCase(val messages: List<ChatMessage>, val options: ChatRequestOptions, val expected: JsonObject)

    private fun dynamicCase(): DynamicCase {
        val fixture = ContextContractFixture.load("wire-system.v1.json")
        val case = ContextContractFixture.cases(fixture, "cases").single { it.id() == "system_history_and_dynamic_block" }
        val plan = case.getValue("plan").jsonObject
        val turns = plan.getValue("messages").jsonArray.map { it.jsonObject }
        var dynamic: String? = null
        val messages = turns.mapIndexed { i, turn ->
            val blocks = turn.getValue("blocks").jsonArray.map { it.jsonObject }
            val texts = blocks.filter { it["kind"]?.jsonPrimitive?.content == "text" }.map { it.getValue("text").jsonPrimitive.content }
            val dyn = blocks.filter { it["kind"]?.jsonPrimitive?.content == "dynamic" }.map { it.getValue("text").jsonPrimitive.content }
            if (dyn.isNotEmpty()) dynamic = dyn.joinToString("\n\n")
            val text = (texts + dyn).joinToString("\n\n")
            if (turn["role"]?.jsonPrimitive?.content == "assistant") {
                ChatMessage(
                    id = "a$i", role = ChatRole.Assistant, text = text, providerKind = ProviderKind.Anthropic,
                    providerName = "Anthropic", modelName = modelId, state = ChatMessageState.Delivered,
                )
            } else {
                ProviderTestFixtures.userMessage(text, ProviderKind.Anthropic, modelId)
            }
        }
        val options = ChatRequestOptions(systemPrompt = plan.getValue("system").jsonPrimitive.content, dynamicText = dynamic)
        return DynamicCase(messages, options, case.getValue("expected").jsonObject.getValue("anthropic").jsonObject)
    }

    private fun lastUserContent(messages: JsonArray): JsonArray =
        messages.last { it.jsonObject["role"]?.jsonPrimitive?.content == "user" }.jsonObject.getValue("content").jsonArray

    private fun assertMatchesFixture(sent: String, case: DynamicCase) {
        val parsed = json.parseToJsonElement(sent).jsonObject
        assertEquals("system is byte-identical to the fixture", case.expected.getValue("system").toString(), parsed.getValue("system").toString())
        assertEquals(
            "content of the last user is byte-identical to the fixture ([D] is a separate final block, the breakpoint is on the block before it)",
            lastUserContent(case.expected.getValue("messages").jsonArray).toString(),
            lastUserContent(parsed.getValue("messages").jsonArray).toString(),
        )
        assertNull("no top-level cache_control any more", parsed["cache_control"])
        assertEquals("the whole request body has exactly 1 cache_control: $sent", 1, countCacheControl(sent))
    }

    @Test
    fun anthropic_official_dynamic_block_last_breakpoint_before_it() = runTest {
        val case = dynamicCase()
        assertMatchesFixture(officialBody(case.messages, case.options), case)
    }

    @Test
    fun anthropic_relay_dynamic_block_last_breakpoint_before_it() {
        val case = dynamicCase()
        assertMatchesFixture(relayBody(case.messages, case.options), case)
    }

    @Test
    fun anthropic_without_dynamic_breakpoint_on_last_block() = runTest {
        val case = dynamicCase()
        val options = case.options.copy(dynamicText = null)
        for ((route, sent) in listOf("official" to officialBody(case.messages, options), "relay" to relayBody(case.messages, options))) {
            val parsed = json.parseToJsonElement(sent).jsonObject
            assertNull("$route has no top-level cache_control", parsed["cache_control"])
            assertEquals("$route has exactly 1 cache_control: $sent", 1, countCacheControl(sent))
            val content = lastUserContent(parsed.getValue("messages").jsonArray)
            assertEquals("$route keeps the original text when there is no dynamicText", case.messages.last().text, content.single().jsonObject["text"]?.jsonPrimitive?.content)
            assertNotNull("$route breakpoint is on the last block", content.last().jsonObject["cache_control"])
        }
    }

    private val dynamic = "<oriveo-reminder>\nWrite only in Arabic.\n</oriveo-reminder>"

    private fun textOf(block: JsonElement): String? = block.jsonObject["text"]?.jsonPrimitive?.content

    @Test
    fun anthropic_image_only_dynamic_breakpoint_on_image() = runTest {
        // When the body is empty the current user text is [D] itself; it is still split off as the last block, and the breakpoint lands on the image block.
        val current = ProviderTestFixtures.userMessage(dynamic, ProviderKind.Anthropic, modelId)
            .copy(attachments = listOf(image("c1")))
        val options = ChatRequestOptions(dynamicText = dynamic)
        for ((route, sent) in listOf("official" to officialBody(listOf(current), options), "relay" to relayBody(listOf(current), options))) {
            assertEquals("$route has exactly 1 cache_control: $sent", 1, countCacheControl(sent))
            val content = lastUserContent(json.parseToJsonElement(sent).jsonObject.getValue("messages").jsonArray)
            assertEquals("$route has only the image + [D] blocks: $sent", listOf("image", "text"), content.map { it.jsonObject["type"]?.jsonPrimitive?.content })
            assertNotNull("$route breakpoint is on the image block", content[0].jsonObject["cache_control"])
            assertEquals("$route [D] is the last block", dynamic, textOf(content[1]))
            assertNull("$route [D] block carries no breakpoint", content[1].jsonObject["cache_control"])
        }
    }

    @Test
    fun anthropic_file_text_injected_before_dynamic() = runTest {
        // Extracted attachment file text is injected before [D]; [D] is always the final segment.
        val file = Attachment(
            id = "f1",
            kind = AttachmentKind.File,
            fileName = "notes.txt",
            mimeType = "text/plain",
            base64Data = java.util.Base64.getEncoder().encodeToString("FILE-BODY-42".toByteArray()),
        )
        val current = ProviderTestFixtures.userMessage("Summarize the file.\n\n$dynamic", ProviderKind.Anthropic, modelId)
            .copy(attachments = listOf(file))
        val options = ChatRequestOptions(dynamicText = dynamic)
        for ((route, sent) in listOf("official" to officialBody(listOf(current), options), "relay" to relayBody(listOf(current), options))) {
            assertEquals("$route has exactly 1 cache_control: $sent", 1, countCacheControl(sent))
            val content = lastUserContent(json.parseToJsonElement(sent).jsonObject.getValue("messages").jsonArray)
            assertEquals("$route [D] is the last block: $sent", dynamic, textOf(content.last()))
            val before = content.dropLast(1).mapNotNull(::textOf).joinToString("\n")
            assertTrue("$route file text is before [D]: $sent", before.contains("FILE-BODY-42") && before.contains("Summarize the file."))
            assertTrue("$route the part before [D] no longer contains [D]: $sent", !before.contains(dynamic))
            assertNotNull("$route breakpoint is on the block before [D]", content[content.size - 2].jsonObject["cache_control"])
        }
    }

    @Test
    fun `official anthropic puts a single block breakpoint on the last user`() = runTest {
        val sent = officialBody(conversation())
        val parsed = json.parseToJsonElement(sent).jsonObject
        val messages = parsed.getValue("messages").jsonArray
        assertEquals("The 1 history image and the 5 current-turn images must all be sent", 6, imageBlocks(messages))
        assertNull("direct path no longer sends a top-level cache_control", parsed["cache_control"])
        assertNotNull("breakpoint is on the last content block of the last user", lastUserContent(messages).last().jsonObject["cache_control"])
        assertEquals(1, countCacheControl(sent))
    }

    @Test
    fun `relay anthropic puts a single breakpoint on the last block of the last user`() {
        val body = buildAnthropicBody(
            modelID = modelId,
            messages = conversation(),
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(),
            // Without capability evidence the vision gate would drop the images; this test measures breakpoints on a request with images, so keep them.
            buildExtras = RelayChatBuildExtras(keepImageAttachments = true),
        )
        val parsed = json.parseToJsonElement(body).jsonObject
        val messages = parsed.getValue("messages").jsonArray
        assertEquals(6, imageBlocks(messages))
        assertTrue("At most 1 cache_control: $body", countCacheControl(body) <= 1)
        assertNull("The relay sends no top-level cache_control", parsed["cache_control"])
        val lastUser = messages.last { it.jsonObject["role"]?.jsonPrimitive?.content == "user" }.jsonObject
        val lastBlock = lastUser.getValue("content").jsonArray.last().jsonObject
        assertNotNull("The breakpoint sits on the last content block of the last user message", lastBlock["cache_control"])
        assertEquals(1, countCacheControl(body))
    }

    @Test
    fun `relay anthropic marks a text only last user turn`() {
        val messages = listOf(ProviderTestFixtures.userMessage("Hello", ProviderKind.Anthropic, modelId))
        val body = buildAnthropicBody(
            modelID = modelId,
            messages = messages,
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(),
        )
        val content = json.parseToJsonElement(body).jsonObject.getValue("messages").jsonArray.single()
            .jsonObject.getValue("content").jsonArray.single().jsonObject
        assertEquals("Hello", content["text"]?.jsonPrimitive?.content)
        assertNotNull(content["cache_control"])
        assertTrue(content["cache_control"] is JsonObject)
    }
}
