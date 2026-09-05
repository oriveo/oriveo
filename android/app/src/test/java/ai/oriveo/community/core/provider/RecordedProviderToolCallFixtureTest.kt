package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ToolCallDelta
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class RecordedProviderToolCallFixtureTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `all recorded provider streams preserve native call identity name and arguments`() {
        val directory = fixtureDirectory()
        val manifest = json.parseToJsonElement(
            String(Files.readAllBytes(directory.resolve("expected.json")), Charsets.UTF_8),
        ).jsonObject
        val fixtures = manifest["fixtures"] as JsonArray
        assertEquals(13, fixtures.size)

        fixtures.forEach { rawEntry ->
            val entry = rawEntry.jsonObject
            val provider = primitive(entry, "provider")!!
            val protocol = when (primitive(entry, "transport")) {
                "openai_chat" -> NativeToolProtocol.OpenAIChat
                "openai_responses" -> NativeToolProtocol.OpenAIResponses
                "anthropic_messages" -> NativeToolProtocol.AnthropicMessages
                "gemini_generate" -> NativeToolProtocol.GeminiGenerate
                else -> error("Unknown fixture transport for $provider")
            }
            val parser = NativeToolCallParser(protocol)
            val accumulated = mutableMapOf<Int, ToolCallDelta>()
            var currentEvent: String? = null
            Files.readAllLines(directory.resolve(primitive(entry, "file")!!)).forEach { line ->
                when {
                    line.startsWith("event:") -> currentEvent = line.substringAfter("event:").trim()
                    line.startsWith("data:") -> {
                        val payload = line.substringAfter("data:").trim()
                        if (payload.isNotBlank() && payload != "[DONE]") {
                            val root = json.parseToJsonElement(payload).jsonObject
                            NativeToolCallAccumulator.merge(accumulated, parser.parse(currentEvent, root))
                        }
                        currentEvent = null
                    }
                }
            }

            val expected = ((entry["expected"] as JsonObject)["tool_calls"] as JsonArray)
                .single().jsonObject
            val actual = NativeToolCallAccumulator.finalize(accumulated, "fixture").singleOrNull()
            assertNotNull("$provider produced no structured call", actual)
            actual!!
            assertEquals(provider, primitive(expected, "name"), actual.name)
            primitive(expected, "id")?.let { assertEquals(provider, it, actual.id) }
            assertEquals(
                provider,
                json.parseToJsonElement(primitive(expected, "arguments")!!),
                json.parseToJsonElement(actual.arguments),
            )
        }
    }

    private fun fixtureDirectory(): Path = generateSequence(Path.of(System.getProperty("user.dir"))) { it.parent }
        .map { it.resolve("shared/test-fixtures/provider-toolcall/recorded") }
        .firstOrNull { Files.exists(it.resolve("expected.json")) }
        ?: error("Recorded provider tool-call fixtures not found")

    private fun primitive(value: JsonObject, key: String): String? =
        (value[key] as? JsonPrimitive)?.contentOrNull
}
