package ai.oriveo.community.core.provider

import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.MemoryPropose
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.relay.buildGeminiBody
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import ai.oriveo.community.core.provider.relay.buildResponsesBody
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertTrue
import org.junit.Test

/** Client-tool injection point of an ordinary chat request body: tools equal the matching entry of the memory-propose.v2 fixture projections. */
class ProposeMemoryRequestBodyTest {

    private val projections: JsonObject by lazy {
        ContextContractFixture.load("memory-propose.v2.json")["projections"]!!.jsonObject
    }

    private val base = """{"model":"m","stream":true}"""

    private val messages = listOf(
        ChatMessage(
            id = "u1",
            role = ChatRole.User,
            text = "Hi",
            providerKind = ProviderKind.Relay,
            providerName = "Relay",
            modelID = "m",
            modelName = "m",
            state = ChatMessageState.Delivered,
        ),
    )

    private fun officialOptions(withTools: Boolean = true) = ChatRequestOptions(
        clientTools = if (withTools) listOf(MemoryPropose.tool) else emptyList(),
    )

    private fun relayOptions(transport: RelayTransport, withTools: Boolean = true) = ChatRequestOptions(
        relayRequested = RelayRequestedConfig(transport = transport),
        activeModel = AIModel(id = "m", name = "m"),
        clientTools = if (withTools) listOf(MemoryPropose.tool) else emptyList(),
    )

    private fun official(kind: ProviderKind, transport: String, options: ChatRequestOptions = officialOptions()): JsonObject =
        Json.parseToJsonElement(applyCapabilityRuntimeCustomFragment(base, kind, "m", transport, options)).jsonObject

    private fun parse(body: String): JsonObject = Json.parseToJsonElement(body).jsonObject

    private fun expected(protocol: String): JsonElement = projections[protocol]!!

    private val geminiAuto: JsonElement =
        parse("""{"functionCallingConfig":{"mode":"AUTO"}}""")

    /** legRules 1: search_memory comes after propose_memory, byte for byte as in the memory-search.v1 projections. */
    private val searchProjections: JsonObject by lazy {
        ContextContractFixture.load("memory-search.v1.json")["projections"]!!.jsonObject
    }

    private fun bothTools(protocol: String): JsonElement =
        JsonArray(projections[protocol]!!.jsonArray + searchProjections[protocol]!!.jsonArray)

    @Test
    fun `search_memory follows propose_memory on every protocol`() {
        val options = ChatRequestOptions(
            clientTools = listOf(MemoryPropose.tool, ai.oriveo.community.core.context.MemorySearch.tool),
        )
        assertEquals(bothTools("openai_chat"), official(ProviderKind.OpenAI, "openai_chat", options)["tools"])
        assertEquals(bothTools("openai_responses"), official(ProviderKind.OpenAI, "openai_responses", options)["tools"])
        assertEquals(bothTools("anthropic_messages"), official(ProviderKind.Anthropic, "anthropic_messages", options)["tools"])
        val declarations = listOf(projections, searchProjections).flatMap {
            it["gemini_generate"]!!.jsonArray.single().jsonObject["functionDeclarations"]!!.jsonArray
        }
        assertEquals(
            JsonArray(listOf(JsonObject(mapOf("functionDeclarations" to JsonArray(declarations))))),
            official(ProviderKind.Gemini, "gemini_generate_content", options)["tools"],
        )
    }

    @Test
    fun `official OpenAI chat carries fixture tools and auto choice`() {
        val body = official(ProviderKind.OpenAI, "openai_chat")
        assertEquals(expected("openai_chat"), body["tools"])
        assertEquals(JsonPrimitive("auto"), body["tool_choice"])
    }

    @Test
    fun `official OpenAI responses carries fixture tools and auto choice`() {
        val body = official(ProviderKind.OpenAI, "openai_responses")
        assertEquals(expected("openai_responses"), body["tools"])
        assertEquals(JsonPrimitive("auto"), body["tool_choice"])
    }

    @Test
    fun `official Anthropic carries fixture tools and auto choice`() {
        val body = official(ProviderKind.Anthropic, "anthropic_messages")
        assertEquals(expected("anthropic_messages"), body["tools"])
        assertEquals(parse("""{"type":"auto"}"""), body["tool_choice"])
    }

    @Test
    fun `official Gemini carries fixture tools and AUTO calling mode`() {
        val body = official(ProviderKind.Gemini, "gemini_generate_content")
        assertEquals(expected("gemini_generate"), body["tools"])
        assertEquals(geminiAuto, body["toolConfig"])
    }

    @Test
    fun `relay OpenAI chat carries fixture tools`() {
        val body = parse(buildOpenAIChatBody("m", messages, true, ReasoningMode.Automatic, relayOptions(RelayTransport.OpenAIChatCompletions)))
        assertEquals(expected("openai_chat"), body["tools"])
        assertEquals(JsonPrimitive("auto"), body["tool_choice"])
    }

    @Test
    fun `relay responses appends fixture tools after built-in image generation`() {
        val body = parse(
            buildResponsesBody("m", messages, true, false, ReasoningMode.Automatic, false, relayOptions(RelayTransport.OpenAIResponses)),
        )
        val tools = body["tools"] as JsonArray
        assertEquals(parse("""{"type":"image_generation"}"""), tools.first())
        assertEquals(expected("openai_responses"), JsonArray(tools.drop(1)))
        assertEquals(JsonPrimitive("auto"), body["tool_choice"])
    }

    @Test
    fun `relay Anthropic carries fixture tools`() {
        val body = parse(buildAnthropicBody("m", messages, true, ReasoningMode.Automatic, relayOptions(RelayTransport.AnthropicMessages)))
        assertEquals(expected("anthropic_messages"), body["tools"])
        assertEquals(parse("""{"type":"auto"}"""), body["tool_choice"])
    }

    @Test
    fun `relay Gemini carries fixture tools`() {
        val body = parse(
            buildGeminiBody(messages, "m", false, ReasoningMode.Automatic, false, relayOptions(RelayTransport.GeminiGenerateContent)),
        )
        assertEquals(expected("gemini_generate"), body["tools"])
        assertEquals(geminiAuto, body["toolConfig"])
    }

    @Test
    fun `without client tools bodies are unchanged and have no tools key`() {
        val off = officialOptions(withTools = false)
        listOf(
            ProviderKind.OpenAI to "openai_chat",
            ProviderKind.Anthropic to "anthropic_messages",
            ProviderKind.Gemini to "gemini_generate_content",
        ).forEach { (kind, transport) ->
            assertEquals(base, applyCapabilityRuntimeCustomFragment(base, kind, "m", transport, off))
        }
        val relayChat = buildOpenAIChatBody("m", messages, true, ReasoningMode.Automatic, relayOptions(RelayTransport.OpenAIChatCompletions, false))
        assertFalse(parse(relayChat).containsKey("tools"))
        val relayAnthropic = buildAnthropicBody("m", messages, true, ReasoningMode.Automatic, relayOptions(RelayTransport.AnthropicMessages, false))
        assertFalse(parse(relayAnthropic).containsKey("tools"))
        val relayGemini = buildGeminiBody(messages, "m", false, ReasoningMode.Automatic, false, relayOptions(RelayTransport.GeminiGenerateContent, false))
        assertFalse(parse(relayGemini).containsKey("tools"))
    }
}
