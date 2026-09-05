package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.content.TextContent
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MiniMaxServiceTest {

    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `thinking tag parser extracts MiniMax reasoning`() {
        var parser = ThinkingTagParser()
        assertEquals(
            listOf(
                ThinkingTagParser.Segment.Text("A"),
                ThinkingTagParser.Segment.Reasoning("r"),
                ThinkingTagParser.Segment.Text("B"),
            ),
            parser.parse("A<think>r</think>B"),
        )

        parser = ThinkingTagParser()
        assertEquals(
            listOf(
                ThinkingTagParser.Segment.Reasoning("a"),
                ThinkingTagParser.Segment.Text("x"),
                ThinkingTagParser.Segment.Reasoning("b"),
                ThinkingTagParser.Segment.Text("y"),
            ),
            parser.parse("<think>a</think>x<think>b</think>y"),
        )

        parser = ThinkingTagParser()
        assertEquals(emptyList<ThinkingTagParser.Segment>(), parser.parse("<th"))
        assertEquals(
            listOf(ThinkingTagParser.Segment.Reasoning("a")),
            parser.parse("ink>a</thi"),
        )
        assertEquals(
            listOf(ThinkingTagParser.Segment.Text("b")),
            parser.parse("nk>b"),
        )

        parser = ThinkingTagParser()
        assertEquals(
            listOf(
                ThinkingTagParser.Segment.Text("A"),
                ThinkingTagParser.Segment.Reasoning("unfinished"),
            ),
            parser.parse("A<think>unfinished"),
        )
        assertEquals(emptyList<ThinkingTagParser.Segment>(), parser.parse("", final = true))
    }

    @Test
    fun `thinking tag parser keeps code fence literals`() {
        val parser = ThinkingTagParser()
        val content = "```xml\n<think>literal</think>\n```\nOK"

        assertEquals(
            listOf(ThinkingTagParser.Segment.Text(content)),
            parser.parse(content),
        )
    }

    @Test
    fun `sendMessageStream converts MiniMax think tags to reasoning events`() = runTest {
        val payload = """
            data: {"choices":[{"delta":{"content":"A<th"}}]}

            data: {"choices":[{"delta":{"content":"ink>reason</thi"}}]}

            data: {"choices":[{"delta":{"content":"nk>B<think>more"}}]}

            data: {"usage":{"prompt_tokens":7,"completion_tokens":11}}

            data: [DONE]
        """.trimIndent()
        var requestBody = ""
        val client = HttpClient(
            MockEngine { request ->
                requestBody = (request.body as TextContent).text
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MiniMaxService(client, json)

        val events = service.sendMessageStream(
            apiKey = "sk-api-test",
            modelID = "MiniMax-M2",
            messages = listOf(userMessage("Hi")),
            baseUrl = "https://api.minimax.io/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        val deltas = events.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.Delta>()
            .joinToString("") { it.text }
        val reasoning = events.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.Reasoning>()
            .joinToString("") { it.text }
        val done = events.last() as ai.oriveo.community.core.model.StreamEvent.Done

        assertEquals("AB", deltas)
        assertEquals("reasonmore", reasoning)
        assertEquals("AB", done.result.text)
        assertEquals("reasonmore", done.result.reasoningText)
        assertTrue(json.parseToJsonElement(requestBody).jsonObject["reasoning_split"]!!.jsonPrimitive.content.toBoolean())
    }

    @Test
    fun `sendMessage also forces reasoning split on MiniMax chat`() = runTest {
        var requestBody = ""
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as TextContent).text
            respond(
                content = """{"choices":[{"message":{"content":"answer"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        })
        MiniMaxService(client, json).sendMessage(
            apiKey = "sk-api-test",
            modelID = "MiniMax-M2",
            messages = listOf(userMessage("Hi")),
            baseUrl = "https://api.minimax.io/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )
        assertTrue(json.parseToJsonElement(requestBody).jsonObject["reasoning_split"]!!.jsonPrimitive.content.toBoolean())
    }

    @Test
    fun `exact server web recipe routes MiniMax through Anthropic stream and replays opaque blocks`() = runTest {
        injectMiniMaxWebMetadata()
        val paths = mutableListOf<String>()
        val bodies = mutableListOf<kotlinx.serialization.json.JsonObject>()
        val headers = mutableListOf<io.ktor.http.Headers>()
        var turn = 0
        val client = HttpClient(MockEngine { request ->
            paths += request.url.encodedPath
            headers += request.headers
            bodies += json.parseToJsonElement((request.body as TextContent).text).jsonObject
            turn += 1
            respond(
                content = if (turn == 1) """
                    event: message_start
                    data: {"type":"message_start","message":{"usage":{"input_tokens":7}}}

                    event: content_block_start
                    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":"sig"}}

                    event: content_block_delta
                    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"trace"}}

                    event: content_block_start
                    data: {"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"web_1","name":"web_search","input":{}}}

                    event: content_block_delta
                    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"news\"}"}}

                    event: content_block_start
                    data: {"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"web_1","content":[{"type":"web_search_result","title":"Example","url":"https://example.com","content":"snippet"}]}}

                    event: content_block_start
                    data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}

                    event: content_block_delta
                    data: {"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"answer"}}

                    event: message_delta
                    data: {"type":"message_delta","usage":{"output_tokens":9}}

                    event: message_stop
                    data: {"type":"message_stop"}

                """.trimIndent() else """
                    event: message_start
                    data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

                    event: content_block_start
                    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"continued"}}

                    event: message_delta
                    data: {"type":"message_delta","usage":{"output_tokens":1}}

                    event: message_stop
                    data: {"type":"message_stop"}

                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        val service = MiniMaxService(client, json)
        val first = service.sendMessageStream(
            "key", "MiniMax-M3", listOf(userMessage("news")), "https://api.minimax.io/v1",
            false, ReasoningMode.Automatic, true, ChatRequestOptions(),
        ).toList()
        val state = first.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.RecipeContinuation>().single().state
        assertEquals("answer", first.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.Delta>().joinToString("") { it.text })
        assertEquals("trace", first.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.Reasoning>().joinToString("") { it.text })
        assertEquals("snippet", first.filterIsInstance<ai.oriveo.community.core.model.StreamEvent.Citations>().single().citations.single().snippet)

        service.sendMessageStream(
            "key", "MiniMax-M3", listOf(userMessage("continue")), "https://api.minimax.io/v1",
            false, ReasoningMode.Automatic, true,
            ChatRequestOptions(localContinuationState = state, localContinuationExplicit = true),
        ).toList()

        assertEquals(listOf("/anthropic/v1/messages", "/anthropic/v1/messages"), paths)
        assertEquals("key", headers.first()["x-api-key"])
        assertEquals("2023-06-01", headers.first()["anthropic-version"])
        assertFalse("Anthropic route must not leak OpenAI field", "reasoning_split" in bodies.first())
        assertEquals("web_search_20250305", bodies.first()["tools"]!!.jsonArray.single().jsonObject["type"]!!.jsonPrimitive.content)
        val replay = bodies.last()["messages"]!!.jsonArray.first { it.jsonObject["role"]?.jsonPrimitive?.content == "assistant" }.jsonObject
        assertEquals("thinking", replay["content"]!!.jsonArray.first().jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("server_tool_use", replay["content"]!!.jsonArray[1].jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("web_search_tool_result", replay["content"]!!.jsonArray[2].jsonObject["type"]!!.jsonPrimitive.content)
    }

    @Test
    fun `web route fails closed for disabled web and non exact model`() = runTest {
        injectMiniMaxWebMetadata()
        val paths = mutableListOf<String>()
        val bodies = mutableListOf<kotlinx.serialization.json.JsonObject>()
        val client = HttpClient(MockEngine { request ->
            paths += request.url.encodedPath
            bodies += json.parseToJsonElement((request.body as TextContent).text).jsonObject
            respond(
                content = """data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        val service = MiniMaxService(client, json)
        service.sendMessageStream("key", "MiniMax-M3", listOf(userMessage("hello")), "https://api.minimax.io/v1", false, ReasoningMode.Automatic, false, ChatRequestOptions()).toList()
        service.sendMessageStream("key", "MiniMax-M2", listOf(userMessage("hello")), "https://api.minimax.io/v1", false, ReasoningMode.Automatic, true, ChatRequestOptions()).toList()
        assertEquals(listOf("/v1/chat/completions", "/v1/chat/completions"), paths)
        assertTrue(bodies.all { it["reasoning_split"]!!.jsonPrimitive.content.toBoolean() })
        assertTrue(bodies.all { "tools" !in it })
    }

    @Test
    fun `syncProvider falls back to metadata catalog when models endpoint is unavailable`() = runTest {
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "miniMax": {
                  "defaultModelId": "MiniMax-M2.5",
                  "resolveMap": {
                    "MiniMax-M2.5": "MiniMax-M2.5",
                    "MiniMax-M2.7": "MiniMax-M2.7"
                  },
                  "models": {
                    "MiniMax-M2.5": {
                      "canonicalModelId": "MiniMax-M2.5",
                      "displayName": "MiniMax-M2.5",
                      "contextLength": 1000000,
                      "pricing": {
                        "promptPerMToken": 1.1,
                        "completionPerMToken": 8.0
                      },
                      "capabilities": ["text", "reasoning"],
                      "profiles": {
                        "reasoning": "mm_chat"
                      },
                      "uiHints": {
                        "groupKey": "m2.5",
                        "groupName": "MiniMax-M2.5",
                        "rank": 120,
                        "recommended": true
                      }
                    },
                    "MiniMax-M2.7": {
                      "canonicalModelId": "MiniMax-M2.7",
                      "displayName": "MiniMax-M2.7",
                      "contextLength": 1000000,
                      "pricing": {
                        "promptPerMToken": 1.8,
                        "completionPerMToken": 12.0
                      },
                      "capabilities": ["text", "reasoning"],
                      "profiles": {
                        "reasoning": "mm_chat"
                      },
                      "uiHints": {
                        "groupKey": "m2.7",
                        "groupName": "MiniMax-M2.7",
                        "rank": 130,
                        "recommended": true
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
        )

        val service = MiniMaxService(client, json)
        val result = service.syncProvider(
            apiKey = "sk-api-test",
            preferredModelID = null,
            baseUrl = "https://api.minimax.io/v1",
        )

        // A vendor's own service does not send an upstream validation call; the model list is built by ProviderRepository from the catalog metadata.
        assertEquals(emptyList<String>(), requests)
        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `sendMessage routes MiniMax image models to image_generation endpoint`() = runTest {
        // Image generation dispatch is route-driven, so inject an imageGen profile (route=minimax_image_generation plus requestDefaults)
        injectMetadata(
            """
            {
              "version": 1,
              "profiles": {
                "imageGen": {
                  "mm_images": {
                    "route": "minimax_image_generation",
                    "streaming": false,
                    "supportsContext": false,
                    "requestDefaults": { "response_format": "base64", "n": 1 }
                  }
                }
              },
              "providers": {
                "miniMax": {
                  "defaultModelId": "image-01",
                  "resolveMap": { "image-01": "image-01" },
                  "models": {
                    "image-01": {
                      "canonicalModelId": "image-01",
                      "profiles": { "imageGen": "mm_images" },
                      "capabilities": ["imageGeneration"]
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
                    "/v1/image_generation" -> respond(
                        content = """{"data":{"image_base64":["aGVsbG8="]}}""",
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
        )

        val service = MiniMaxService(client, json)
        val done = service.sendMessage(
            apiKey = "sk-api-test",
            modelID = "image-01",
            messages = listOf(
                ChatMessage(
                    id = "msg-1",
                    role = ChatRole.User,
                    text = "draw a cat",
                    providerKind = ProviderKind.MiniMax,
                    providerName = "MiniMax",
                    modelName = "image-01",
                    state = ChatMessageState.Delivered,
                )
            ),
            baseUrl = "https://api.minimax.io/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        )

        assertEquals(listOf("/v1/image_generation"), requests)
        assertEquals("", done.result.text)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("aGVsbG8=", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `resolveRegionOption matches cn endpoint with trailing slash`() {
        val resolved = ProviderKind.MiniMax.resolveRegionOption("https://api.minimaxi.com/v1/")

        assertEquals("cn", resolved?.id)
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

    private fun injectMiniMaxWebMetadata() = injectMetadata("""
        {
          "version":1,
          "providers":{"miniMax":{"resolveMap":{"MiniMax-M3":"MiniMax-M3","MiniMax-M2":"MiniMax-M2"},"models":{
            "MiniMax-M3":{"canonicalModelId":"MiniMax-M3","transport":"openai_chat","capabilities":["text","web"],"capabilityControls":{"web":{"state":"auto_available","recipeRef":"minimax.messages.web.v1"}}},
            "MiniMax-M2":{"canonicalModelId":"MiniMax-M2","transport":"openai_chat","capabilities":["text"],"capabilityControls":{"web":{"state":"unknown","reasonCode":"model_capability_absent"}}}
          }}},
          "capabilityRuntime":{"schemaVersion":2,"revision":"minimax-web-test","generatedAt":"2026-08-23T00:00:00Z","controlDefinitions":{},
            "sourceIndex":{"minimax.server_tools":{"kind":"official_doc","url":"https://platform.minimax.io/docs/guides/server-tools","reviewedAt":"2026-08-23"}},
            "recipes":{"minimax.messages.web.v1":{"id":"minimax.messages.web.v1","providerKind":"miniMax","transport":{"protocol":"openai_chat"},"capability":"web","executionKind":"endpoint_route","requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"web_search_20250305","name":"web_search"}}],"route":{"sourceProtocol":"openai_chat","protocol":"anthropic_messages","endpointClass":"messages","path":"/anthropic/v1/messages","method":"POST","authMode":"x_api_key","authHeader":"x-api-key","headers":{"Content-Type":"application/json","anthropic-version":"2023-06-01"},"requestMapper":"minimax_anthropic_messages_v1"},"responseParserKind":"minimax_anthropic_web_v1","continuationKind":"replay_blocks","fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["minimax.server_tools"]}}
          }
        }
    """.trimIndent())

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.MiniMax,
        providerName = "MiniMax",
        modelName = "MiniMax-M2",
        state = ChatMessageState.Delivered,
    )
}
