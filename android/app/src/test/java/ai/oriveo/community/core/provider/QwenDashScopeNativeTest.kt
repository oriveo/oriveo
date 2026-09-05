package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test

/**
 * Structural verification of the OpenAI-compatible request body QwenService builds.
 *
 * The native DashScope generation endpoint is retired: the newer qwen3.x models are only
 * reachable on the compatible endpoint, and the native one answers them with a url error.
 * This calls buildCompatibleChatBody directly to get the request JSON. It used to go through
 * reflection, which meant any signature change only surfaced at run time as a
 * NoSuchMethodException; calling it directly makes that drift a compile error. What is
 * verified:
 *   - top-level shape: {model, stream, messages:[...]}, no native input.messages wrapper
 *   - reasoning parameters: enable_thinking is written at the top level exactly as the
 *     official recipe says, and no budget is synthesised that the upstream never promised
 *   - web-search parameter: enable_search at the top level, not nested under parameters
 *
 * The fixture used to write the webSearch profile in the native DashScope shape,
 * `mergeParams.parameters.enable_search`, while the assertions demanded a top-level
 * `enable_search` and no `parameters` key at all. The two only agreed because a transitional
 * patch inside `QwenService.buildCompatibleChatBodyBase` flattened `parameters` on the way
 * out. Top level is the real shape: the `qwen.chat.web.v1` recipe's requestOp is
 * `set /enable_search`, and the compatible endpoint does not accept `parameters` either. The
 * fixture now matches that, so the test no longer leans on the flattening patch to prove
 * itself.
 */
class QwenDashScopeNativeTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)
    private val service = QwenService(
        client = HttpClient(MockEngine { respond("", HttpStatusCode.OK) }),
        json = json,
        transportRegistry = transportRegistry,
    )

    private fun buildBody(
        modelID: String = "qwen-plus",
        messages: List<ChatMessage> = listOf(userMessage("Hello Qwen")),
        reasoning: ReasoningMode = ReasoningMode.Automatic,
        webSearchEnabled: Boolean = false,
        reasoningProfile: String? = null,
        webProfile: String? = null,
        stream: Boolean = true,
    ): JsonObject {
        val resolved = resolveMetadata(modelID, reasoningProfile, webProfile)
        val bodyStr = service.buildCompatibleChatBody(
            modelID = modelID,
            messages = messages,
            stream = stream,
            reasoningMode = reasoning,
            webSearchEnabled = webSearchEnabled,
            webProfileName = webProfile,
            resolved = resolved,
            requestOptions = ChatRequestOptions(),
        )
        return Json.parseToJsonElement(bodyStr).jsonObject
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `request body uses OpenAI compatible top-level messages and stream`() {
        val body = buildBody()
        assertNotNull(body["model"])
        assertNotNull(body["messages"])
        assertEquals("true", body["stream"]?.toString())
        // There must no longer be a native DashScope input wrapper layer.
        assertFalse(
            "compatible body must not expose native input wrapper",
            body.containsKey("input"),
        )

        // The non-streaming sendMessage, used by the library tool leg, reuses the same builder.
        // stream really has to land at the top level; the compatible shape cannot be something
        // only the streaming path gets right.
        val nonStream = buildBody(stream = false)
        assertEquals("false", nonStream["stream"]?.toString())
        assertNotNull(nonStream["messages"])
        assertFalse(nonStream.containsKey("input"))
    }

    @Test
    fun `reasoning Fast does not synthesize an unsupported thinking budget`() {
        val body = buildBody(reasoning = ReasoningMode.Fast, reasoningProfile = "qwen_hybrid_test")
        assertFalse(body.containsKey("enable_thinking"))
        assertFalse(body.containsKey("thinking_budget"))
    }

    @Test
    fun `reasoning Max does not synthesize an unsupported thinking budget`() {
        val body = buildBody(reasoning = ReasoningMode.Max, reasoningProfile = "qwen_hybrid_test")
        assertFalse(body.containsKey("enable_thinking"))
        assertFalse(body.containsKey("thinking_budget"))
    }

    @Test
    fun `reasoning Balanced injects the official enable thinking switch`() {
        val body = buildBody(reasoning = ReasoningMode.Balanced, reasoningProfile = "qwen_hybrid_test")
        assertEquals("true", body["enable_thinking"]?.toString())
        assertFalse(body.containsKey("thinking_budget"))
    }

    @Test
    fun `reasoning Automatic does not inject enable_thinking`() {
        val body = buildBody(reasoning = ReasoningMode.Automatic)
        assertFalse(body.containsKey("enable_thinking"))
    }

    @Test
    fun `webSearch enabled with metadata injects top-level enable_search`() {
        val body = buildBody(webSearchEnabled = true, webProfile = "qwen_web_test")
        assertEquals("true", body["enable_search"]?.toString())
        assertFalse(
            "enable_search must be top-level, not under parameters",
            body.containsKey("parameters"),
        )
    }

    @Test
    fun `webSearch enabled without profile does not inject search params`() {
        val body = buildBody(webSearchEnabled = true, webProfile = null)
        assertFalse(body.containsKey("enable_search"))
        assertFalse(body.containsKey("parameters"))
    }

    @Test
    fun `webSearch disabled does not inject search params`() {
        val body = buildBody(webSearchEnabled = false)
        assertFalse(body.containsKey("enable_search"))
    }

    @Test
    fun `messages use OpenAI string content for plain text`() {
        val body = buildBody(messages = listOf(userMessage("hi there")))
        val firstMsg = (body["messages"] as? kotlinx.serialization.json.JsonArray)
            ?.firstOrNull()?.jsonObject
        assertNotNull(firstMsg)
        assertEquals("\"user\"", firstMsg?.get("role")?.toString())
        // For a plain text message, content is a string as the compatible endpoint expects,
        // not the native multi-part [{text}] array.
        assertEquals("\"hi there\"", firstMsg?.get("content")?.jsonPrimitive?.toString())
    }

    private fun userMessage(text: String): ChatMessage = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Qwen,
        providerName = "Qwen",
        modelID = "qwen-plus",
        modelName = "Qwen Plus",
        state = ChatMessageState.Delivered,
    )

    private fun resolveMetadata(
        modelID: String,
        reasoningProfile: String?,
        webProfile: String?,
    ): MetadataClient.ResolvedModelMetadata? {
        if (reasoningProfile == null && webProfile == null) return null
        val reasoningProfileRef = reasoningProfile?.let { """"reasoning":"$it"""" }
        val webProfileRef = webProfile?.let { """"webSearch":"$it"""" }
        val profileRefs = listOfNotNull(reasoningProfileRef, webProfileRef).joinToString(",")
        // A missing runtime entry means zero automatic configuration, so the only source of
        // injected parameters is the exact recipe under capabilityRuntime; there is no fallback
        // to the legacy profiles. The enable_thinking and enable_search asserted below therefore
        // come from qwen.chat.reasoning.v1 and qwen.chat.web.v1 in the production registry.
        // The reverse gate also applies: selectedIntent has to appear in availableIntents, and
        // Qwen currently declares only off and balanced.
        val controls = listOfNotNull(
            reasoningProfile?.let {
                MetadataTestFixtures.ControlSpec(
                    capability = "reasoning",
                    recipeRef = "qwen.chat.reasoning.v1",
                    availableIntents = listOf("off", "balanced"),
                )
            },
            webProfile?.let {
                MetadataTestFixtures.ControlSpec(capability = "web", recipeRef = "qwen.chat.web.v1")
            },
        )
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "capabilityRuntime": ${MetadataTestFixtures.capabilityRuntimeJson()},
              "profiles": {
                "reasoning": {
                  "qwen_hybrid_test": {
                    "levels": ["fast", "balanced", "deep", "max"],
                    "params": {
                      "fast": { "enable_thinking": true, "thinking_budget": 1024 },
                      "balanced": { "enable_thinking": true, "thinking_budget": 4096 },
                      "deep": { "enable_thinking": true, "thinking_budget": 16384 },
                      "max": { "enable_thinking": true, "thinking_budget": 38000 }
                    }
                  }
                },
                "webSearch": {
                  "qwen_web_test": {
                    "mergeParams": { "enable_search": true }
                  }
                }
              },
              "providers": {
                "qwen": {
                  "defaultModelId": "$modelID",
                  "resolveMap": { "$modelID": "$modelID" },
                  "models": {
                    "$modelID": {
                      "canonicalModelId": "$modelID",
                      "transport": "openai_chat",
                      "capabilities": ["web"],
                      "profiles": { $profileRefs },
                      "capabilityControls": ${MetadataTestFixtures.capabilityControlsJson(*controls.toTypedArray())}
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        return MetadataClient.resolveCatalogModel(modelID, ProviderKind.Qwen)
    }
}
