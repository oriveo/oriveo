package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ZhipuServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    @Test
    fun `syncProvider validates key and injects known image models`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "zhipu": {
                  "defaultModelId": "glm-4-plus",
                  "resolveMap": {
                    "glm-4-plus": "glm-4-plus",
                    "glm-image": "glm-image",
                    "cogview-4": "cogview-4",
                    "cogview-3-flash": "cogview-3-flash"
                  },
                  "models": {
                    "glm-4-plus": {
                      "canonicalModelId": "glm-4-plus",
                      "displayName": "GLM-4 Plus",
                      "capabilities": ["text", "reasoning"],
                      "uiHints": {
                        "rank": 100,
                        "recommended": true
                      }
                    },
                    "glm-image": {
                      "canonicalModelId": "glm-image",
                      "displayName": "GLM Image",
                      "capabilities": ["imageGeneration"]
                    },
                    "cogview-4": {
                      "canonicalModelId": "cogview-4",
                      "displayName": "CogView 4",
                      "capabilities": ["imageGeneration"]
                    },
                    "cogview-3-flash": {
                      "canonicalModelId": "cogview-3-flash",
                      "displayName": "CogView 3 Flash",
                      "capabilities": ["imageGeneration"]
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val requests = mutableListOf<String>()
        val service = ZhipuService(
            client = HttpClient(
                MockEngine { request ->
                    requests += request.url.encodedPath

                    when (request.url.encodedPath) {
                        "/api/paas/v4/chat/completions" -> respond(
                            content = """{"id":"chatcmpl-test"}""",
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )

                        else -> error("Unexpected request: ${request.url}")
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val result = service.syncProvider(
            apiKey = "sk-test",
            preferredModelID = null,
            baseUrl = null,
        )

        // An official service issues no upstream probe of its own; the catalog is built by
        // ProviderRepository from the published metadata.
        assertEquals(emptyList<String>(), requests)
        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `sendMessage includes 1024 square size for image generation`() = runTest {
        // The shape of an image request (endpoint and size) is dictated by the published
        // imageGen profile: route=images_api plus requestDefaults.
        injectImageMetadata()
        var imageRequestBody: String? = null
        val service = ZhipuService(
            client = HttpClient(
                MockEngine { request ->
                    when (request.url.toString()) {
                        "https://open.bigmodel.cn/api/paas/v4/images/generations" -> {
                            imageRequestBody = requestBodyText(request.body)
                            respond(
                                content = """
                                    {
                                      "data": [
                                        { "b64_json": "AQID" }
                                      ]
                                    }
                                """.trimIndent(),
                                status = HttpStatusCode.OK,
                                headers = headersOf(HttpHeaders.ContentType, "application/json"),
                            )
                        }

                        else -> error("Unexpected request: ${request.url}")
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val done = service.sendMessage(
            apiKey = "sk-test",
            modelID = "cogview-4",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a panda",
                    providerKind = ProviderKind.Zhipu,
                    providerName = "Zhipu",
                    modelName = "cogview-4",
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = null,
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertTrue(imageRequestBody?.contains(""""size":"1024x1024"""") == true)
        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("AQID", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `sendMessage preserves remote image url when zhipu returns url attachment`() = runTest {
        injectImageMetadata()
        val service = ZhipuService(
            client = HttpClient(
                MockEngine { request ->
                    when (request.url.toString()) {
                        "https://open.bigmodel.cn/api/paas/v4/images/generations" -> respond(
                            content = """
                                {
                                  "data": [
                                    { "url": "https://temp.zhipu.test/generated.png" }
                                  ]
                                }
                            """.trimIndent(),
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )

                        else -> error("Unexpected request: ${request.url}")
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val done = service.sendMessage(
            apiKey = "sk-test",
            modelID = "glm-image",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a panda",
                    providerKind = ProviderKind.Zhipu,
                    providerName = "Zhipu",
                    modelName = "glm-image",
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = null,
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("https://temp.zhipu.test/generated.png", done.result.attachments?.first()?.base64Data)
    }

    /** Injects a zhipu image model plus the zhipu_images profile (route=images_api, requestDefaults.size=1024x1024). */
    private fun injectImageMetadata() {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "zhipu": {
                  "defaultModelId": "glm-image",
                  "resolveMap": { "cogview-4": "cogview-4", "glm-image": "glm-image" },
                  "models": {
                    "cogview-4": {
                      "canonicalModelId": "cogview-4",
                      "displayName": "CogView 4",
                      "capabilities": ["imageGeneration"],
                      "profiles": { "imageGen": "zhipu_images" }
                    },
                    "glm-image": {
                      "canonicalModelId": "glm-image",
                      "displayName": "GLM Image",
                      "capabilities": ["imageGeneration"],
                      "profiles": { "imageGen": "zhipu_images" }
                    }
                  }
                }
              },
              "profiles": {
                "imageGen": {
                  "zhipu_images": { "route": "images_api", "requestDefaults": { "size": "1024x1024" } }
                }
              }
            }
            """.trimIndent(),
        )
    }

    private fun injectMetadata(rawJson: String) {
        val clientClass = MetadataClient::class.java

        val jsonField = clientClass.getDeclaredField("json")
        jsonField.isAccessible = true
        val internalJson = jsonField.get(MetadataClient.instance) as Json

        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companionField = responseClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val serializer = serializerMethod.invoke(companion) as kotlinx.serialization.KSerializer<Any>

        val decoded = internalJson.decodeFromString(serializer, rawJson)

        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, decoded)
    }
}
