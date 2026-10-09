package ai.oriveo.community.core.provider

import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.content.TextContent
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** On the official Chat Completions path max_output_tokens is renamed to max_completion_tokens by profile.wire; only the real request body captured by MockEngine is asserted. */
class OfficialChatMaxCompletionTokensTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `official openai chat completions body writes max_completion_tokens`() = runTest {
        MetadataTestFixtures.applyRaw(metadata("openAI", "openai.chat.generation.v1").toString())
        val body = capture { client ->
            OpenAIService(client = client, json = json, transportRegistry = TransportRegistry(json)).sendMessageStream(
                apiKey = "test-key", modelID = MODEL, messages = listOf(ProviderTestFixtures.userMessage("hi", ProviderKind.OpenAI, MODEL)),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = options(),
            )
        }
        assertEquals("2048", body["max_completion_tokens"]!!.jsonPrimitive.content)
        assertFalse("max_tokens" in body)
    }

    @Test
    fun `official openai compatible chat completions body writes max_completion_tokens`() = runTest {
        MetadataTestFixtures.applyRaw(metadata("deepseek", "deepseek.chat.generation.v1").toString())
        val body = capture { client ->
            DeepSeekService(client, json).sendMessageStream(
                apiKey = "test-key", modelID = MODEL, messages = listOf(ProviderTestFixtures.userMessage("hi", ProviderKind.DeepSeek, MODEL)),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = options(),
            )
        }
        assertEquals("2048", body["max_completion_tokens"]!!.jsonPrimitive.content)
        assertFalse("max_tokens" in body)
    }

    private fun options() = ChatRequestOptions(
        maxTokens = 4096,
        generationParameters = GenerationParameterOverrides(mapOf(
            "max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(2048)),
        )),
    )

    private suspend fun capture(send: (HttpClient) -> Flow<*>): JsonObject {
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        runCatching { send(client).toList() }
        return json.parseToJsonElement(requireNotNull(requestBody) { "no request was built" }).jsonObject
    }

    private fun metadata(providerKey: String, generationRecipe: String): JsonObject {
        val registry = json.parseToJsonElement(repoText(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        )).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:fixture"),
            "generatedAt" to JsonPrimitive("2026-10-08T00:00:00Z"),
        ))
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("profiles", buildJsonObject { put("generation", buildJsonObject {
                put("version", 1)
                put("parameters", buildJsonObject {
                    put("max_output_tokens", buildJsonObject { put("valueSchema", "integer") })
                })
                put("templates", buildJsonObject {
                    put("openai_chat_completions", buildJsonObject {
                        put("transport", "openai_chat")
                        put("wire", buildJsonObject { put("max_output_tokens", "max_tokens") })
                    })
                })
            }) })
            put("providers", buildJsonObject {
                put(providerKey, buildJsonObject {
                    put("resolveMap", buildJsonObject { put(MODEL, MODEL) })
                    put("models", buildJsonObject {
                        put(MODEL, buildJsonObject {
                            put("transport", "openai_chat")
                            put("profiles", buildJsonObject { put("generation", buildJsonObject {
                                put("template", "openai_chat_completions")
                                put("parameters", JsonArray(listOf(buildJsonObject {
                                    put("id", "max_output_tokens"); put("support", "supported"); put("wire", "max_completion_tokens")
                                })))
                            }) })
                            put("capabilityControls", buildJsonObject {
                                put("generation", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", generationRecipe)
                                })
                            })
                        })
                    })
                })
            })
        }
    }

    private fun repoText(relative: String): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relative) }
            .firstOrNull(Files::exists)
            ?: error("$relative not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private companion object {
        const val MODEL = "fixture-chat-completions"
    }
}
