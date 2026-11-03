package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Runs every case of the shared model_id_normalization.v1 fixture. */
class ModelIdNormalizationContractTest {
    private val fixture: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/model_id_normalization.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("model_id_normalization.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    @Test
    fun `every shared case normalizes to expect`() {
        assertEquals("model_id_normalization.v1", fixture.getValue("contractId").jsonPrimitive.content)
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("fixture has cases", cases.isNotEmpty())
        for (case in cases) {
            val id = case.getValue("caseId").jsonPrimitive.content
            assertEquals(
                id,
                case.getValue("expect").jsonPrimitive.content,
                ModelIdNormalization.normalize(case.getValue("input").jsonPrimitive.content),
            )
        }
    }
}
