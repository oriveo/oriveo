package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/** user_input content of the Interactions activated tier: an image whose data is unavailable gets a placeholder instead of being silently dropped. */
class GeminiInteractionsUserContentTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val client = HttpClient(MockEngine { respond("{}") })

    @After
    fun tearDown() = client.close()

    @Test
    fun `activated image without data writes image placeholder`() {
        val model = "gemini-3-flash"
        val message = ProviderTestFixtures.userMessage("hi", ProviderKind.Gemini, model).copy(
            attachments = listOf(
                Attachment(id = "img-1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png"),
            ),
        )
        val service = GeminiService(client, json, TransportRegistry(json))

        val (_, bodyText) = service.buildInteractionsRequest(
            apiKey = "key", modelID = model, messages = listOf(message), baseUrl = null, stream = true,
            runtime = JsonObject(mapOf("recipes" to JsonObject(emptyMap()))),
            route = buildJsonObject {
                put("protocol", "gemini_interactions")
                put("endpointClass", "interactions")
                put("requestMapper", "gemini_interactions_v1")
                put("path", "/v1beta/interactions")
            },
            webRecipe = null, reasoningRecipe = null, reasoningIntent = null,
            attachmentStage = GeminiService.InteractionsAttachmentStage.Activated,
        )

        val content = json.parseToJsonElement(bodyText).jsonObject["input"]!!.jsonArray
            .single().jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("text", "text"), content.map { it["type"]!!.jsonPrimitive.content })
        assertEquals(
            listOf("hi", AttachmentTransportProfile.TEXT_ONLY_IMAGE_PLACEHOLDER),
            content.map { it["text"]!!.jsonPrimitive.content },
        )
    }
}
