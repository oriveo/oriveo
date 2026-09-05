package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QwenServiceTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val client = HttpClient(MockEngine { respond("", HttpStatusCode.OK) })

    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)
    private val service = QwenService(client, json, transportRegistry)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    // ═══════════════════════════════════════════
    // Model capabilities are identified from the metadata capability fields rather than by a
    // local filterModel step, so this section holds no tests.
    // ═══════════════════════════════════════════

    @Test
    fun `Qwen keeps endpoint but ignores legacy reasoning and web profiles without exact runtime`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "qwen_hybrid_future": {
                    "levels": ["deep"],
                    "params": {
                      "deep": { "enable_thinking": true, "thinking_budget": 7777 }
                    }
                  }
                },
                "webSearch": {
                  "qwen_web_future": {
                    "mergeParams": {
                      "parameters": {
                        "enable_search": true,
                        "search_options": { "forced_search": true }
                      }
                    }
                  }
                }
              },
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-plus",
                  "resolveMap": { "qwen-plus": "qwen-plus" },
                  "transport": {
                    "baseUrl": "https://dashscope-intl.aliyuncs.com",
                    "endpoints": {
                      "chat": "/compatible-mode/v1/chat/completions"
                    }
                  },
                  "models": {
                    "qwen-plus": {
                      "canonicalModelId": "qwen-plus",
                      "transport": "openai_chat",
                      "capabilities": ["text", "reasoning", "web"],
                      "profiles": {
                        "reasoning": "qwen_hybrid_future",
                        "webSearch": "qwen_web_future"
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        var requestUrl = ""
        var requestBody = ""
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    requestUrl = request.url.toString()
                    requestBody = requestBodyText(request.body)
                    respond(
                        content = ProviderTestFixtures.openAiStream(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                },
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "qwen-plus",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Qwen, "qwen-plus")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions", requestUrl)
        assertFalse(requestBody.contains(""""thinking_budget":7777"""))
        assertFalse(requestBody.contains(""""enable_search":true"""))
        assertFalse(requestBody.contains(""""forced_search":true"""))
        assertFalse(requestBody.contains(""""thinking_budget":16384"""))
        assertFalse(requestBody.contains(""""parameters":"""))
    }

    @Test
    fun `sendMessageStream does not inject Qwen reasoning or web fallback without profiles`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-plus",
                  "resolveMap": { "qwen-plus": "qwen-plus" },
                  "transport": {
                    "baseUrl": "https://dashscope-intl.aliyuncs.com",
                    "endpoints": { "chat": "/compatible-mode/v1/chat/completions" }
                  },
                  "models": {
                    "qwen-plus": { "canonicalModelId": "qwen-plus" }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        var requestBody = ""
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    requestBody = requestBodyText(request.body)
                    respond(
                        content = ProviderTestFixtures.openAiStream(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                },
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "qwen-plus",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Qwen, "qwen-plus")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains("enable_thinking"))
        assertFalse(requestBody.contains("thinking_budget"))
        assertFalse(requestBody.contains("enable_search"))
    }

    // ═══════════════════════════════════════════
    // C. Region Options
    // ═══════════════════════════════════════════

    @Test
    fun `regionOptions has 4 entries`() {
        val regions = ProviderKind.Qwen.regionOptions
        assertEquals(4, regions.size)
    }

    @Test
    fun `regionOptions first entry is Singapore with id sg`() {
        val first = ProviderKind.Qwen.regionOptions.first()
        assertEquals("sg", first.id)
        assertTrue(first.label.contains("Singapore"))
    }

    @Test
    fun `regionOptions entries have non-empty id, label, and baseURL`() {
        for (region in ProviderKind.Qwen.regionOptions) {
            assertTrue("id should not be empty for $region", region.id.isNotEmpty())
            assertTrue("label should not be empty for $region", region.label.isNotEmpty())
            assertTrue("baseURL should not be empty for $region", region.baseURL.isNotEmpty())
        }
    }

    @Test
    fun `regionOptions baseURLs are dashscope native origins without compatible-mode suffix`() {
        // The region base points at the native DashScope origin so that it agrees with the
        // native chat path; mixing the two is what produced a 404 right after picking a region.
        // The compatible sub-path lives only in the validation probePath, never in the base.
        for (region in ProviderKind.Qwen.regionOptions) {
            assertTrue(
                "baseURL '${region.baseURL}' should contain 'dashscope'",
                region.baseURL.contains("dashscope"),
            )
            assertFalse(
                "baseURL '${region.baseURL}' must not carry /compatible-mode/v1, which collides with the native path and yields a malformed 404",
                region.baseURL.contains("/compatible-mode"),
            )
        }
    }

    @Test
    fun `resolveRegionOption matches stored base URL without scheme`() {
        val resolved = ProviderKind.Qwen.resolveRegionOption(
            "dashscope-us.aliyuncs.com/compatible-mode/v1/",
        )

        assertNotNull(resolved)
        assertEquals("us", resolved?.id)
    }

    @Test
    fun `resolveChatUrl uses metadata compatible chat endpoint for all regions`() {
        injectQwenChatTransportMetadata()
        val method = QwenService::class.java.getDeclaredMethod("resolveChatUrl", String::class.java)
        method.isAccessible = true

        for (region in ProviderKind.Qwen.regionOptions) {
            val url = method.invoke(service, region.baseURL) as String
            assertTrue(
                "region '${region.id}' chat URL should end at the compatible endpoint: $url",
                url.endsWith("/compatible-mode/v1/chat/completions"),
            )
            assertFalse(
                "region '${region.id}' must not append the native generation path: $url",
                url.contains("/api/v1/services/aigc/text-generation/generation"),
            )
        }
    }

    @Test
    fun `resolveChatUrl normalizes legacy compatible-mode base without doubling prefix`() {
        // A baseURLText stored locally by an existing user may still be the historical
        // compatible base that carries /compatible-mode/v1.
        injectQwenChatTransportMetadata()
        val method = QwenService::class.java.getDeclaredMethod("resolveChatUrl", String::class.java)
        method.isAccessible = true
        val url = method.invoke(service, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1") as String
        assertEquals(
            "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
            url,
        )
    }

    @Test
    fun `resolveChatUrl keeps custom proxy as standard OpenAI compatible`() {
        injectQwenChatTransportMetadata()
        val method = QwenService::class.java.getDeclaredMethod("resolveChatUrl", String::class.java)
        method.isAccessible = true
        val url = method.invoke(service, "https://example-proxy.com/v1") as String
        assertEquals("https://example-proxy.com/v1/compatible-mode/v1/chat/completions", url)
    }

    // ═══════════════════════════════════════════
    // D. ProviderKind Properties
    // ═══════════════════════════════════════════

    @Test
    fun `Qwen displayName is Qwen`() {
        assertEquals("Qwen", ProviderKind.Qwen.displayName)
    }

    @Test
    fun `Qwen defaultBaseUrl is dashscope native origin`() {
        // The native origin, without /compatible-mode/v1, agrees with the native chat path and
        // is the fix for the 404 seen right after picking a region. Key validation is covered by
        // the metadata validation contract, whose probePath is /compatible-mode/v1/models.
        assertEquals(
            "dashscope-intl.aliyuncs.com",
            ProviderKind.Qwen.defaultBaseUrl,
        )
    }

    @Test
    fun `Qwen apiKeyPlaceholder is correct`() {
        assertEquals("sk-xxxxxxxxxxxxxxxx", ProviderKind.Qwen.apiKeyPlaceholder)
    }

    @Test
    fun `Qwen is in directProviders`() {
        assertTrue(
            "Qwen should be in directProviders",
            ProviderKind.Qwen in ProviderKind.directProviders,
        )
    }

    @Test
    fun `syncProvider falls back to metadata catalog and injects image models`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-plus",
                  "resolveMap": {
                    "qwen-plus": "qwen-plus",
                    "qwen-max": "qwen-max",
                    "qwen-image-2.0-pro": "qwen-image-2.0-pro",
                    "qwen-image-2.0": "qwen-image-2.0"
                  },
                  "models": {
                    "qwen-plus": {
                      "canonicalModelId": "qwen-plus",
                      "displayName": "Qwen Plus",
                      "contextLength": 131072,
                      "pricing": {
                        "promptPerMToken": 0.4,
                        "completionPerMToken": 1.2
                      },
                      "capabilities": ["text", "reasoning"],
                      "profiles": {
                        "reasoning": "qwen_hybrid"
                      },
                      "uiHints": {
                        "groupKey": "qwen-plus",
                        "groupName": "Qwen Plus",
                        "rank": 120,
                        "recommended": true
                      }
                    },
                    "qwen-max": {
                      "canonicalModelId": "qwen-max",
                      "displayName": "Qwen Max",
                      "contextLength": 262144,
                      "pricing": {
                        "promptPerMToken": 1.2,
                        "completionPerMToken": 6.0
                      },
                      "capabilities": ["text", "reasoning"],
                      "profiles": {
                        "reasoning": "qwen_hybrid"
                      },
                      "uiHints": {
                        "groupKey": "qwen-max",
                        "groupName": "Qwen Max",
                        "rank": 100,
                        "recommended": false
                      }
                    },
                    "qwen-image-2.0-pro": {
                      "canonicalModelId": "qwen-image-2.0-pro",
                      "displayName": "Qwen Image 2.0 Pro",
                      "pricing": {
                        "promptPerMToken": 0.0,
                        "completionPerMToken": 0.0
                      },
                      "capabilities": ["text", "imageGeneration"],
                      "profiles": {
                        "imageGen": "qwen_images"
                      },
                      "uiHints": {
                        "groupKey": "qwen-image",
                        "groupName": "Qwen Image",
                        "rank": 80,
                        "recommended": false
                      }
                    },
                    "qwen-image-2.0": {
                      "canonicalModelId": "qwen-image-2.0",
                      "displayName": "Qwen Image 2.0",
                      "pricing": {
                        "promptPerMToken": 0.0,
                        "completionPerMToken": 0.0
                      },
                      "capabilities": ["text", "imageGeneration"],
                      "profiles": {
                        "imageGen": "qwen_images"
                      },
                      "uiHints": {
                        "groupKey": "qwen-image",
                        "groupName": "Qwen Image",
                        "rank": 70,
                        "recommended": false
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val requests = mutableListOf<String>()
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    requests += request.url.encodedPath

                    when (request.url.encodedPath) {
                        "/compatible-mode/v1/chat/completions" -> respond(
                            content = """
                                {"choices":[{"message":{"content":"pong"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
                            """.trimIndent(),
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                        else -> respond(
                            content = "404 page not found",
                            status = HttpStatusCode.NotFound,
                            headers = headersOf(HttpHeaders.ContentType, "text/plain"),
                        )
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val result = service.syncProvider(
            apiKey = "sk-test",
            preferredModelID = null,
            baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        )

        // An official service issues no upstream probe of its own; the catalog is built by
        // ProviderRepository from the published metadata.
        assertEquals(emptyList<String>(), requests)
        assertTrue("service returns empty models after metadata authoritative refactor", result.models.isEmpty())
    }

    @Test
    fun `sendMessage routes qwen image models through DashScope image endpoint and downloads image`() = runTest {
        injectQwenImageMetadata()
        val requests = mutableListOf<String>()
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    requests += request.url.toString()

                    when (request.url.toString()) {
                        "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation" -> respond(
                            content = """
                                {
                                  "output": {
                                    "choices": [
                                      {
                                        "message": {
                                          "content": [
                                            { "image": "https://temp.qwen.test/generated.png" }
                                          ]
                                        }
                                      }
                                    ]
                                  }
                                }
                            """.trimIndent(),
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                        "https://temp.qwen.test/generated.png" -> respond(
                            content = ByteReadChannel(byteArrayOf(1, 2, 3)),
                            status = HttpStatusCode.OK,
                            headers = headersOf(HttpHeaders.ContentType, "image/png"),
                        )
                        else -> respond(
                            content = "404 page not found",
                            status = HttpStatusCode.NotFound,
                            headers = headersOf(HttpHeaders.ContentType, "text/plain"),
                        )
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val done = service.sendMessage(
            apiKey = "sk-test",
            modelID = "qwen-image-2.0",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a fox",
                    providerKind = ProviderKind.Qwen,
                    providerName = "Qwen",
                    modelName = "qwen-image-2.0",
                    state = ChatMessageState.Delivered,
                )
            ),
            baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertEquals(
            listOf(
                "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
                "https://temp.qwen.test/generated.png",
            ),
            requests,
        )
        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("AQID", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `sendMessage uses 1024 square size and preserves remote image url when download fails`() = runTest {
        injectQwenImageMetadata()
        var imageRequestBody: String? = null
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    when (request.url.toString()) {
                        "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation" -> {
                            imageRequestBody = requestBodyText(request.body)
                            respond(
                                content = """
                                    {
                                      "output": {
                                        "choices": [
                                          {
                                            "message": {
                                              "content": [
                                                { "image": "https://temp.qwen.test/generated.png" }
                                              ]
                                            }
                                          }
                                        ]
                                      }
                                    }
                                """.trimIndent(),
                                status = HttpStatusCode.OK,
                                headers = headersOf(HttpHeaders.ContentType, "application/json"),
                            )
                        }

                        "https://temp.qwen.test/generated.png" -> respond(
                            content = "not found",
                            status = HttpStatusCode.NotFound,
                            headers = headersOf(HttpHeaders.ContentType, "text/plain"),
                        )

                        else -> respond(
                            content = "404 page not found",
                            status = HttpStatusCode.NotFound,
                            headers = headersOf(HttpHeaders.ContentType, "text/plain"),
                        )
                    }
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val done = service.sendMessage(
            apiKey = "sk-test",
            modelID = "qwen-image-2.0",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a fox",
                    providerKind = ProviderKind.Qwen,
                    providerName = "Qwen",
                    modelName = "qwen-image-2.0",
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertTrue(imageRequestBody?.contains(""""size":"1024*1024"""") == true)
        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("https://temp.qwen.test/generated.png", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `compat stream parses reasoning then content with OpenAI choices delta`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen3.6-flash",
                  "resolveMap": { "qwen3.6-flash": "qwen3.6-flash" },
                  "transport": {
                    "baseUrl": "https://dashscope-intl.aliyuncs.com",
                    "endpoints": { "chat": "/compatible-mode/v1/chat/completions" }
                  },
                  "models": {
                    "qwen3.6-flash": { "canonicalModelId": "qwen3.6-flash" }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        // The real compatible endpoint stream as measured with curl: `data: ` carries a trailing
        // space and the payload is the OpenAI choices.delta shape. A reasoning model emits its
        // thinking through reasoning_content first with content null, and only then starts
        // emitting content deltas.
        val compatSSE = buildString {
            append("""data: {"choices":[{"delta":{"content":null,"reasoning_content":"let me ","role":"assistant"},"index":0}]}""")
            append("\n\n")
            append("""data: {"choices":[{"delta":{"content":null,"reasoning_content":"think"},"index":0}]}""")
            append("\n\n")
            append("""data: {"choices":[{"delta":{"content":"hello","role":"assistant"},"index":0}]}""")
            append("\n\n")
            append("""data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}""")
            append("\n\n")
            append("data: [DONE]\n\n")
        }

        var capturedUrl: String? = null
        val service = QwenService(
            client = HttpClient(
                MockEngine { request ->
                    capturedUrl = request.url.toString()
                    respond(
                        content = compatSSE,
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "qwen3.6-flash",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "say something short",
                    providerKind = ProviderKind.Qwen,
                    providerName = "Qwen",
                    modelName = "qwen3.6-flash",
                    state = ChatMessageState.Delivered,
                ),
            ),
            baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertTrue(
            "chat URL should be the compatible endpoint: $capturedUrl",
            capturedUrl?.endsWith("/compatible-mode/v1/chat/completions") == true,
        )
        val text = events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text }
        assertEquals("hello", text)
        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>().joinToString("") { it.text }
        assertEquals("let me think", reasoning)
        val done = events.filterIsInstance<StreamEvent.Done>().last()
        assertEquals("hello", done.result.text)
    }

    @Test
    fun `compat stream surfaces in-stream upstream error instead of empty response`() = runTest {
        // The old native path swallowed an event:error inside a 200 stream, so the user was left
        // with an "empty response" and no clue why. A top-level DashScope {"code","message"}
        // error has to keep its "model does not exist" meaning, while credentials, the user's
        // prompt and raw upstream fields must never reach the failure card.
        val errorSSE = buildString {
            append("""data: {"code":"InvalidParameter","message":"Model not exist: qwen-fake; sk-secret; prompt-private","data":"raw-data-private"}""")
            append("\n\n")
            append("data: [DONE]\n\n")
        }

        val service = QwenService(
            client = HttpClient(
                MockEngine {
                    respond(
                        content = errorSSE,
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val error = runCatching {
            service.sendMessageStream(
                apiKey = "sk-test",
                modelID = "qwen-fake",
                messages = listOf(
                    ChatMessage(
                        id = "msg-1",
                        role = ChatRole.User,
                        text = "hi",
                        providerKind = ProviderKind.Qwen,
                        providerName = "Qwen",
                        modelName = "qwen-fake",
                        state = ChatMessageState.Delivered,
                    ),
                ),
                baseUrl = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()

        assertTrue("should be classified as ModelUnavailable rather than a silent empty response", error is ProviderServiceError.ModelUnavailable)
        val detail = (error as? ProviderServiceError.ModelUnavailable)?.detail.orEmpty()
        assertTrue("a production stream error must carry a non-empty safe summary", detail.isNotBlank())
        assertEquals("The provider stream reported that the model is unavailable.", detail)
        assertFalse("the safe summary must not keep the upstream model id", detail.contains("qwen-fake"))
        assertFalse("the safe summary must not keep credentials", detail.contains("sk-secret"))
        assertFalse("the safe summary must not keep the user prompt", detail.contains("prompt-private"))
        assertFalse("the safe summary must not keep raw upstream fields", detail.contains("raw-data-private"))
    }

    private fun injectMetadata(rawJson: String) {
        MetadataTestFixtures.applyRaw(rawJson)
    }

    private fun injectQwenImageMetadata() {
        injectMetadata(
            """
            {
              "version": 1,
              "profiles": {
                "imageGen": {
                  "qwen_images": {
                    "route": "dashscope_multimodal",
                    "streaming": false,
                    "supportsContext": false,
                    "requestDefaults": { "size": "1024*1024", "n": 1, "prompt_extend": true }
                  }
                }
              },
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-image-2.0",
                  "resolveMap": { "qwen-image-2.0": "qwen-image-2.0" },
                  "transport": {
                    "baseUrl": "https://dashscope-intl.aliyuncs.com",
                    "endpoints": {
                      "chat": "/compatible-mode/v1/chat/completions",
                      "images": "/api/v1/services/aigc/multimodal-generation/generation"
                    }
                  },
                  "models": {
                    "qwen-image-2.0": {
                      "canonicalModelId": "qwen-image-2.0",
                      "transport": "qwen_image",
                      "profiles": { "imageGen": "qwen_images" },
                      "capabilities": ["text", "imageGeneration"]
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )
    }

    private fun injectQwenChatTransportMetadata() {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-plus",
                  "resolveMap": { "qwen-plus": "qwen-plus" },
                  "transport": {
                    "baseUrl": "https://dashscope-intl.aliyuncs.com",
                    "endpoints": { "chat": "/compatible-mode/v1/chat/completions" }
                  },
                  "models": {
                    "qwen-plus": { "canonicalModelId": "qwen-plus" }
                  }
                }
              }
            }
            """.trimIndent(),
        )
    }
}
