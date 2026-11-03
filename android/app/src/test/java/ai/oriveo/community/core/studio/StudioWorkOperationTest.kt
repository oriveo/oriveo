package ai.oriveo.community.core.studio

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Composer operation resolution follows studio_data_model.v1 operationTable row by row. */
class StudioWorkOperationTest {

    private val dataModel: JsonObject by lazy {
        val shared = String(charArrayOf(0x5171.toChar(), 0x4eab.toChar()))
        val dir: Path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$shared/studio-contracts") }
            .firstOrNull { Files.exists(it.resolve("studio_data_model.v1.json")) }
            ?: error("studio_data_model.v1.json not found")
        Json.parseToJsonElement(dir.resolve("studio_data_model.v1.json").toFile().readText()).jsonObject
    }

    @Test
    fun operationTable_matchFixture() {
        val table = dataModel.getValue("operationTable").jsonArray
        assertTrue("operationTable must not be empty", table.isNotEmpty())
        table.forEach { element ->
            val case = element.jsonObject
            val context = case.getValue("context").jsonObject
            val got = StudioWorkOperation.resolve(
                inWorkDetail = context.getValue("inWorkDetail").jsonPrimitive.boolean,
                images = context.getValue("images").jsonArray.map { it.jsonPrimitive.content },
                modelOps = case.getValue("modelOps").jsonArray.map { it.jsonPrimitive.content },
            )
            val expect = case.getValue("expect").jsonObject
            val want = StudioWorkOperation(
                operation = expect["operation"].stringOrNull(),
                base = expect["base"].stringOrNull(),
                importFirst = expect.getValue("importFirst").jsonPrimitive.boolean,
                blocked = expect["blocked"].stringOrNull(),
            )
            assertEquals(case.getValue("caseId").jsonPrimitive.content, want, got)
        }
    }

    private fun JsonElement?.stringOrNull(): String? =
        if (this == null || this is JsonNull) null else (this as JsonPrimitive).content
}
