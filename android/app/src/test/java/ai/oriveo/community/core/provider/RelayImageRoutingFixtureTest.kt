package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.RelayTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Pins the relay image routing rules to the shared fixture.
 *
 * The rules themselves live in `shared/test-fixtures/relay/routing-fixtures.json`. Every
 * client implements them as its own pure functions, and the fixture locks the expected
 * output case by case so the implementations cannot drift apart. The fixture states the
 * same requirement: each client's tests must assert that its pure functions produce the
 * fixture's output for every case.
 *
 * This file is the Android side of that bargain. To change a rule, change the fixture
 * first, then the implementations.
 */
class RelayImageRoutingFixtureTest {

    private val fixture: JsonObject by lazy {
        val file = locateFixture()
        assertTrue(
            "shared fixture not found, path resolution failed: ${file.absolutePath}",
            file.exists(),
        )
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    /** Walk up from the module directory to find the repo root, rather than relying on gradle's working-directory convention. */
    private fun locateFixture(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/relay/routing-fixtures.json")
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        return File("shared/test-fixtures/relay/routing-fixtures.json")
    }

    private fun cases(section: String) = fixture[section]!!.jsonObject["cases"]!!.jsonArray
        .map { it.jsonObject }
        // Cases pinned to another client (such as the relay-manual- prefix compatibility
        // data) are not ours to check.
        .filter { case ->
            val platform = case["platform"]?.jsonPrimitive?.content
            platform == null || platform == "android"
        }

    private fun transportOf(raw: String): RelayTransport = when (raw) {
        "openai_responses" -> RelayTransport.OpenAIResponses
        "openai_chat_completions" -> RelayTransport.OpenAIChatCompletions
        "anthropic_messages" -> RelayTransport.AnthropicMessages
        "gemini_generate_content" -> RelayTransport.GeminiGenerateContent
        "auto" -> RelayTransport.Auto
        else -> error("fixture carries an unknown transport: $raw")
    }

    /** The fixture spells routes in camelCase, while Android's ImageRoute.raw carries the catalog's snake_case, hence this mapping. */
    private fun expectedRouteOf(raw: String): RelayRuntimeSupport.ImageRoute = when (raw) {
        "inlineResponsesTool" -> RelayRuntimeSupport.ImageRoute.InlineResponsesTool
        "imagesEndpoint" -> RelayRuntimeSupport.ImageRoute.ImagesEndpoint
        "geminiModality" -> RelayRuntimeSupport.ImageRoute.GeminiModality
        "unsupported" -> RelayRuntimeSupport.ImageRoute.Unsupported
        else -> error("fixture carries an unknown imageRoute: $raw")
    }

    /** The fixture uses the client-neutral `imageGen`; the Android enum case is ModelCapability.ImageGen. */
    private fun capabilitiesOf(raw: List<String>): List<ModelCapability> = raw.mapNotNull { name ->
        when (name) {
            "imageGen", "imageGeneration" -> ModelCapability.ImageGen
            "text" -> ModelCapability.Text
            else -> null
        }
    }

    @Test
    fun `all four fixture sections are readable and non-empty`() {
        assertTrue(cases("imageRoute").isNotEmpty())
        assertTrue(cases("shouldForceStream").isNotEmpty())
        assertTrue(cases("isDedicatedImageModel").isNotEmpty())
        assertTrue(cases("pickChatDriverModelID").isNotEmpty())
    }

    @Test
    fun `imageRoute agrees with the shared fixture`() {
        for (case in cases("imageRoute")) {
            val id = case["id"]!!.jsonPrimitive.content
            val transport = transportOf(case["transport"]!!.jsonPrimitive.content)
            val expected = expectedRouteOf(case["expected"]!!.jsonPrimitive.content)
            assertEquals(id, expected, RelayRuntimeSupport.imageRoute(transport, runtimeConfig = null))
        }
    }

    @Test
    fun `isDedicatedImageModel agrees with the shared fixture`() {
        for (case in cases("isDedicatedImageModel")) {
            val id = case["id"]!!.jsonPrimitive.content
            val modelID = case["modelID"]!!.jsonPrimitive.content
            val expected = case["expected"]!!.jsonPrimitive.boolean
            assertEquals(id, expected, RelayRuntimeSupport.isDedicatedImageModel(modelID))
        }
    }

    @Test
    fun `shouldForceStream agrees with the shared fixture`() {
        for (case in cases("shouldForceStream")) {
            val id = case["id"]!!.jsonPrimitive.content
            val transport = transportOf(case["transport"]!!.jsonPrimitive.content)
            val capabilities = capabilitiesOf(
                case["capabilities"]!!.jsonArray.map { it.jsonPrimitive.content },
            )
            val expected = case["expected"]!!.jsonPrimitive.boolean
            assertEquals(
                id,
                expected,
                RelayRuntimeSupport.shouldForceStream(transport, capabilities, runtimeConfig = null),
            )
        }
    }

    @Test
    fun `pickChatDriverModelID agrees with the shared fixture`() {
        for (case in cases("pickChatDriverModelID")) {
            val id = case["id"]!!.jsonPrimitive.content
            val models = case["models"]!!.jsonArray.map { element ->
                val obj = element.jsonObject
                AIModel(
                    id = obj["id"]!!.jsonPrimitive.content,
                    name = obj["id"]!!.jsonPrimitive.content,
                    capabilities = capabilitiesOf(
                        obj["capabilities"]!!.jsonArray.map { it.jsonPrimitive.content },
                    ),
                    isAvailable = obj["available"]!!.jsonPrimitive.boolean,
                    isDefault = obj["isDefault"]!!.jsonPrimitive.boolean,
                )
            }
            val result = RelayRuntimeSupport.pickChatDriverModelID(
                currentModelID = case["currentModelID"]!!.jsonPrimitive.content,
                models = models,
                defaultModelID = models.firstOrNull { it.isDefault }?.id,
            )

            val expectedSuccess = case["expectedSuccess"]?.jsonPrimitive?.content
            if (expectedSuccess != null) {
                assertEquals(id, RelayRuntimeSupport.PickChatDriverResult.Success(expectedSuccess), result)
            } else {
                assertEquals(
                    id,
                    RelayRuntimeSupport.PickChatDriverResult.MissingChatDriverModel,
                    result,
                )
            }
        }
    }
}
