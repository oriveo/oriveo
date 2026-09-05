package ai.oriveo.community.core.provider.openai

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The six hard constraints on the Codex subscription outbound body, and the "user intent AND
 * upstream declaration" rule.
 *
 * What gets asserted here is **the object the production builder actually produces**, not a
 * hand-written JSON: a test that assembles its own `tools:[{"type":"web_search"}]` and then asserts
 * it is present has only proved that the assertion compiles.
 */
class OpenAISubscriptionOutboundTest {

    private val json = Json { ignoreUnknownKeys = true }

    /** The shape `MessageBuilder.buildOpenAIResponsesInput` produces: element text without the enclosing brackets. */
    private val input = """{"role":"user","content":"any news today"}"""

    private fun body(
        webSearchRequested: Boolean = false,
        webSearchDeclared: Boolean = false,
        reasoningMode: String? = null,
        declaredLevels: List<String> = emptyList(),
        systemPrompt: String? = null,
    ): JsonObject = json.parseToJsonElement(
        OpenAISubscriptionOutbound.buildResponsesBody(
            modelID = "gpt-5.6-sol",
            inputElementsJson = input,
            systemPrompt = systemPrompt,
            webSearchRequested = webSearchRequested,
            webSearchDeclared = webSearchDeclared,
            reasoningMode = reasoningMode,
            declaredReasoningLevels = declaredLevels,
        ),
    ).jsonObject

    @Test
    fun `all six hard constraints hold`() {
        val body = body(systemPrompt = "You are an assistant")
        assertEquals("gpt-5.6-sol", body["model"]?.jsonPrimitive?.contentOrNull)
        // store must be false: Codex rejects store:true, and this is not a tunable option.
        assertEquals(false, body["store"]?.jsonPrimitive?.booleanOrNull)
        assertEquals(true, body["stream"]?.jsonPrimitive?.booleanOrNull)
        // Encrypted reasoning has to be requested explicitly through include, otherwise the next turn
        // cannot continue from it.
        assertEquals(
            listOf("reasoning.encrypted_content"),
            (body["include"] as JsonArray).map { it.jsonPrimitive.content },
        )
        // The system prompt travels in instructions only, never left inside input.
        assertEquals("You are an assistant", body["instructions"]?.jsonPrimitive?.contentOrNull)
        val inputArray = body["input"]!!.jsonArray
        assertEquals(1, inputArray.size)
        assertEquals("user", inputArray[0].jsonObject["role"]?.jsonPrimitive?.contentOrNull)
    }

    @Test
    fun `the web_search tool is attached only when the user enabled it and upstream declared support`() {
        val tools = body(webSearchRequested = true, webSearchDeclared = true)["tools"]!!.jsonArray
        assertEquals(1, tools.size)
        assertEquals("web_search", tools[0].jsonObject["type"]?.jsonPrimitive?.contentOrNull)
    }

    @Test
    fun `with no upstream declaration the tool is not attached even if the user enabled it`() {
        // The most expensive one: forcing a tool upstream does not recognise gets the whole request
        // rejected, so the user sees "it will not send" rather than "web search did not take effect".
        assertNull(body(webSearchRequested = true, webSearchDeclared = false)["tools"])
    }

    @Test
    fun `with the user switch off the tool is not attached even when upstream supports it`() {
        assertNull(body(webSearchRequested = false, webSearchDeclared = true)["tools"])
    }

    @Test
    fun `the level sent is always one upstream declared`() {
        val reasoning = body(
            reasoningMode = "deep", declaredLevels = listOf("low", "medium", "high"),
        )["reasoning"]!!.jsonObject
        assertEquals("high", reasoning["effort"]?.jsonPrimitive?.contentOrNull)
        assertEquals("auto", reasoning["summary"]?.jsonPrimitive?.contentOrNull)
    }

    @Test
    fun `a level that maps to nothing upstream declared is never injected`() {
        // Upstream offers only high, and none of the fast candidates low/minimal/medium match, so
        // send nothing rather than forcing a value upstream does not know. That was the shape of the
        // grok reasoning_effort incident.
        assertNull(body(reasoningMode = "fast", declaredLevels = listOf("high"))["reasoning"])
    }

    @Test
    fun `with no declared level table nothing is injected`() {
        assertNull(body(reasoningMode = "deep", declaredLevels = emptyList())["reasoning"])
    }

    @Test
    fun `automatic never injects and leaves it to the upstream default_reasoning_level`() {
        assertNull(
            body(reasoningMode = "automatic", declaredLevels = listOf("low", "medium", "high"))["reasoning"],
        )
    }

    @Test
    fun `a blank system prompt produces no instructions field`() {
        assertNull(body(systemPrompt = "   ")["instructions"])
    }

    @Test
    fun `an unparseable input sends an empty conversation rather than splicing invalid JSON into the body`() {
        // Splicing invalid JSON in would only earn a 400 that says nothing about the real cause.
        val raw = OpenAISubscriptionOutbound.buildResponsesBody(
            modelID = "gpt-5.6-sol",
            inputElementsJson = """{"role":"user""",
            systemPrompt = null,
            webSearchRequested = false,
            webSearchDeclared = false,
            reasoningMode = null,
            declaredReasoningLevels = emptyList(),
        )
        val parsed = json.parseToJsonElement(raw).jsonObject
        assertTrue(parsed["input"]!!.jsonArray.isEmpty())
    }
}
