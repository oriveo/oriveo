package ai.oriveo.community.core.provider

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
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SiliconFlowServiceTest {

    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    /**
     * Reasoning parameters may only come from the published capability recipe; the client is
     * never allowed to supply a default budget of its own. An earlier version hard-coded
     * 32768 here, which is exactly the bug this pins shut.
     *
     * Since a missing runtime entry now means zero automatic configuration, that recipe is
     * the exact entry under capabilityRuntime, with no fallback to the legacy
     * `profiles.reasoning` block. The fixture therefore injects the production registry and
     * the expected values are read off the deep tier of `siliconflow.chat.reasoning.v1`
     * (enable_thinking plus a 16384 budget). That recipe declares no max tier, and asking for
     * Max would be rejected by the guard that refuses tiers the recipe does not declare, so
     * the tier has to be chosen from the ladder the recipe actually publishes.
     */
    @Test
    fun `sendMessageStream uses SiliconFlow reasoning params from the server capability recipe`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "capabilityRuntime": ${MetadataTestFixtures.capabilityRuntimeJson()},
              "providers": {
                "siliconFlow": {
                  "defaultModelId": "deepseek-ai/DeepSeek-V3.1",
                  "resolveMap": { "deepseek-ai/DeepSeek-V3.1": "deepseek-ai/DeepSeek-V3.1" },
                  "models": {
                    "deepseek-ai/DeepSeek-V3.1": {
                      "canonicalModelId": "deepseek-ai/DeepSeek-V3.1",
                      "transport": "openai_chat",
                      "capabilityControls": ${MetadataTestFixtures.capabilityControlsJson(
                        MetadataTestFixtures.ControlSpec(
                            capability = "reasoning",
                            recipeRef = "siliconflow.chat.reasoning.v1",
                            availableIntents = listOf("low", "balanced", "deep"),
                        ),
                    )}
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestBody = ""
        var requestURL = ""
        val service = SiliconFlowService(
            client = HttpClient(
                MockEngine { request ->
                    requestURL = request.url.toString()
                    requestBody = requestBodyText(request.body)
                    respond(
                        content = ProviderTestFixtures.openAiStream(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            ),
            json = json,
        )

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "deepseek-ai/DeepSeek-V3.1",
            messages = listOf(
                ProviderTestFixtures.userMessage("Hi", ProviderKind.SiliconFlow, "deepseek-ai/DeepSeek-V3.1"),
            ),
            baseUrl = "https://api.siliconflow.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertTrue(requestBody.contains(""""thinking_budget":16384"""))
        assertTrue(requestBody.contains(""""enable_thinking":true"""))
        assertTrue(!requestBody.contains("32768"))
        assertEquals("https://api.siliconflow.com/v1/chat/completions", requestURL)
    }

    @Test
    fun `syncProvider validates key and builds metadata models with image capability`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "siliconFlow": {
                  "defaultModelId": "deepseek-ai/DeepSeek-V3.1",
                  "resolveMap": {
                    "Qwen/Qwen3-32B": "Qwen/Qwen3-32B",
                    "deepseek-ai/DeepSeek-V3.1": "deepseek-ai/DeepSeek-V3.1",
                    "Kwai-Kolors/Kolors": "Kwai-Kolors/Kolors"
                  },
                  "models": {
                    "Qwen/Qwen3-32B": {
                      "canonicalModelId": "Qwen/Qwen3-32B",
                      "displayName": "Qwen 3 32B",
                      "capabilities": ["text"],
                      "uiHints": {
                        "rank": 100,
                        "groupKey": "qwen",
                        "groupName": "Qwen"
                      }
                    },
                    "deepseek-ai/DeepSeek-V3.1": {
                      "canonicalModelId": "deepseek-ai/DeepSeek-V3.1",
                      "displayName": "DeepSeek V3.1",
                      "capabilities": ["text"],
                      "uiHints": {
                        "rank": 200,
                        "groupKey": "deepseek-ai",
                        "groupName": "DeepSeek"
                      }
                    },
                    "Kwai-Kolors/Kolors": {
                      "canonicalModelId": "Kwai-Kolors/Kolors",
                      "displayName": "Kwai Kolors",
                      "capabilities": ["imageGeneration"],
                      "profiles": {
                        "imageGen": "sf_images"
                      },
                      "uiHints": {
                        "rank": 150,
                        "groupKey": "kwai-kolors",
                        "groupName": "Kwai Kolors"
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val requests = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requests += request.url.encodedPath
                when (request.url.encodedPath) {
                    "/v1/chat/completions" -> respond(
                        content = """{"id":"chatcmpl-test"}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                    else -> error("Unexpected request: ${request.url}")
                }
            }
        )

        val service = SiliconFlowService(client = client, json = json)
        val result = service.syncProvider(apiKey = "sk-test", preferredModelID = null, baseUrl = null)

        // An official service issues no upstream probe of its own; the catalog is built by
        // ProviderRepository from the published metadata.
        assertEquals(emptyList<String>(), requests)
        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `syncProvider returns empty models and relies on metadata for default ordering`() = runTest {
        // Ordering, the default model and the vendor label are all decided by MetadataClient
        // plus ProviderCatalogResolver; the service only has to walk the validate path.
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "siliconFlow": {
                  "defaultModelId": "model-high-rank-older",
                  "resolveMap": {
                    "model-high-rank-older": "model-high-rank-older"
                  },
                  "models": {
                    "model-high-rank-older": {
                      "canonicalModelId": "model-high-rank-older",
                      "displayName": "Older High Rank",
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val client = HttpClient(
            MockEngine { request ->
                when (request.url.encodedPath) {
                    "/v1/chat/completions" -> respond(
                        content = """{"id":"chatcmpl-test"}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                    else -> error("Unexpected request: ${request.url}")
                }
            }
        )

        val service = SiliconFlowService(client = client, json = json)
        val result = service.syncProvider(apiKey = "sk-test", preferredModelID = null, baseUrl = null)

        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `sendMessage includes 1024 square size and preserves remote url when image download fails`() = runTest {
        // The shape of an image request (endpoint and size) is dictated by the published
        // imageGen profile: route=images_api plus requestDefaults. For a url-shaped response
        // the shared base path keeps the original url and leaves downloading to ChatRepository
        // rather than pre-fetching inside the service.
        injectImageMetadata()
        var imageRequestBody: String? = null
        val client = HttpClient(
            MockEngine { request ->
                when (request.url.toString()) {
                    "https://api.siliconflow.com/v1/images/generations" -> {
                        imageRequestBody = requestBodyText(request.body)
                        respond(
                            content = """
                                {
                                  "data": [
                                    { "url": "https://temp.siliconflow.test/image.png" }
                                  ]
                                }
                            """.trimIndent(),
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    }

                    "https://temp.siliconflow.test/image.png" -> respond(
                        content = "not found",
                        status = HttpStatusCode.NotFound,
                        headers = headersOf(HttpHeaders.ContentType, "text/plain"),
                    )

                    else -> error("Unexpected request: ${request.url}")
                }
            }
        )

        val service = SiliconFlowService(client = client, json = json)
        val done = service.sendMessage(
            apiKey = "sk-test",
            modelID = "Kwai-Kolors/Kolors",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a wave",
                    providerKind = ProviderKind.SiliconFlow,
                    providerName = "SiliconFlow",
                    modelName = "Kwai-Kolors/Kolors",
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = "https://api.siliconflow.com/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertTrue(imageRequestBody?.contains(""""size":"1024x1024"""") == true)
        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("https://temp.siliconflow.test/image.png", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `international balance endpoint uses USD`() = runTest {
        var requestURL = ""
        val client = HttpClient(
            MockEngine { request ->
                requestURL = request.url.toString()
                respond(
                    content = """{"data":{"balance":"0.5","chargeBalance":"8","totalBalance":"8.5"}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val service = SiliconFlowService(client = client, json = json)

        val balance = service.fetchBalance(
            apiKey = "sk-intl",
            baseURL = "https://api.siliconflow.com/v1",
        )

        assertEquals("https://api.siliconflow.com/v1/user/info", requestURL)
        assertEquals("USD", balance.currency)
    }

    /** Injects a siliconFlow image model plus the sf_images profile (route=images_api, requestDefaults.size=1024x1024). */
    private fun injectImageMetadata() {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "siliconFlow": {
                  "defaultModelId": "Kwai-Kolors/Kolors",
                  "resolveMap": { "Kwai-Kolors/Kolors": "Kwai-Kolors/Kolors" },
                  "models": {
                    "Kwai-Kolors/Kolors": {
                      "canonicalModelId": "Kwai-Kolors/Kolors",
                      "displayName": "Kolors",
                      "capabilities": ["imageGeneration"],
                      "profiles": { "imageGen": "sf_images" }
                    }
                  }
                }
              },
              "profiles": {
                "imageGen": {
                  "sf_images": { "route": "images_api", "requestDefaults": { "size": "1024x1024" } }
                }
              }
            }
            """.trimIndent(),
        )
    }

    private fun injectMetadata(rawJson: String) {
        MetadataTestFixtures.applyRaw(rawJson)
    }
}
