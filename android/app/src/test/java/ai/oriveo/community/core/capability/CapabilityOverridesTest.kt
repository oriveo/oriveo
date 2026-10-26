package ai.oriveo.community.core.capability

import ai.oriveo.community.core.model.RelayCapabilityOverrides
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Delta-override normalization matches the shared fixture `shared/test-fixtures/capability/overrides.v1.json` case by case. */
class CapabilityOverridesTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `normalize matches every shared fixture case`() {
        val fixture = loadFixture()
        assertEquals(1, fixture["version"]!!.jsonPrimitive.content.toInt())
        val cases = fixture["cases"]!!.jsonArray
        // Do not hard-code the case count: when another platform adds cases to the shared fixture, this test should run the new cases instead of failing on the count.
        assertTrue(cases.isNotEmpty())

        val failures = cases.mapNotNull { element ->
            val case = element.jsonObject
            val id = case["id"]!!.jsonPrimitive.content
            // Legacy input goes through the production serializer to restore RelayCapabilityOverrides (the source is added to testedKeys).
            val legacy = case["legacy"]?.takeIf { it !is JsonNull }
                ?.let { json.decodeFromJsonElement(RelayCapabilityOverrides.serializer(), it) }
            val result = CapabilityOverrides.normalize(
                connection = case["connection"]!!.jsonPrimitive.content,
                legacy = legacy,
                stored = case["stored"]?.takeIf { it !is JsonNull },
                serverVerdict = case["serverVerdict"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content },
                now = case["now"]!!.jsonPrimitive.content,
            )
            val expect = case["expect"]!!.jsonObject
            val expected = Triple(
                expect["capabilityOverrides"]!!.jsonObject,
                (expect["legacyKept"] as JsonArray).map { it.jsonPrimitive.content },
                expect["effective"]!!.jsonObject,
            )
            val actual = Triple(
                encodeOverrides(result.capabilityOverrides),
                result.legacyKept,
                JsonObject(result.effective.mapValues { (_, op) -> op?.let { JsonPrimitive(it.value) } ?: JsonNull }),
            )
            if (expected == actual) null else "$id: expected $expected, actual $actual"
        }
        assertEquals(emptyList<String>(), failures)
    }

    private fun encodeOverrides(overrides: Map<String, CapabilityOverrideEntry>): JsonObject =
        JsonObject(
            overrides.mapValues { (_, entry) ->
                JsonObject(
                    mapOf<String, JsonElement>(
                        "op" to JsonPrimitive(entry.op.value),
                        "setAt" to JsonPrimitive(entry.setAt),
                        "baseVerdict" to JsonPrimitive(entry.baseVerdict),
                    ),
                )
            },
        )

    private fun loadFixture(): JsonObject {
        val relativePath = "shared/test-fixtures/capability/overrides.v1.json"
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }
}
