package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Reconciles the production local engine tables row by row against the shared localEngineProfiles. */
class LocalEngineProfileContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `production tables match localEngineProfiles row by row`() {
        val profiles = contract()["localEngineProfiles"]!!.jsonObject
        val failures = mutableListOf<String>()
        var rows = 0
        profiles.forEach { (engine, transports) ->
            transports.jsonObject.forEach { (transport, spec) ->
                val where = "$engine/$transport"
                val profile = LocalEngineGenerationProfiles.profile(engine, RelayTransport.entries.first { it.value == transport })
                if (profile == null) { failures += "$where: no production profile"; return@forEach }
                val expected = spec.jsonObject["parameters"]!!.jsonArray.map { it.jsonObject }
                if (profile.template != spec.jsonObject["template"]!!.jsonPrimitive.content) failures += "$where: template=${profile.template}"
                if (profile.transport != transport) failures += "$where: transport=${profile.transport}"
                val actualIds = profile.parameters.map { it.id }
                val expectedIds = expected.map { it["id"]!!.jsonPrimitive.content }
                if (actualIds != expectedIds) failures += "$where: ids=$actualIds, want $expectedIds"
                expected.forEach { row ->
                    val id = row["id"]!!.jsonPrimitive.content
                    val actual = profile.parameters.firstOrNull { it.id == id } ?: return@forEach
                    rows++
                    fun check(field: String, got: Any?, want: Any?) { if (got != want) failures += "$where/$id: $field=$got, want $want" }
                    check("wire", profile.wire[id], row["wire"]!!.jsonPrimitive.content)
                    check("valueSchema", actual.valueSchema, row["valueSchema"]!!.jsonPrimitive.content)
                    check("group", actual.group, row["group"]!!.jsonPrimitive.content)
                    check("support", actual.support, "accepted_unverified")
                    check("source", actual.source, "user_declared")
                    val range = row["range"] as? JsonObject
                    check("min", actual.range?.min, range?.get("min")?.jsonPrimitive?.doubleOrNull)
                    check("max", actual.range?.max, range?.get("max")?.jsonPrimitive?.doubleOrNull)
                    check("minExclusive", actual.range?.minExclusive, range?.get("minExclusive")?.jsonPrimitive?.doubleOrNull)
                    check("maxExclusive", actual.range?.maxExclusive, range?.get("maxExclusive")?.jsonPrimitive?.doubleOrNull)
                    check("default", actual.defaultDescription?.let(::normalized), row["default"]?.let(::normalized))
                    check("enumValues", actual.enumValues, (row["enumValues"] as? JsonArray)?.toList().orEmpty())
                }
            }
        }
        assertEquals(108, rows)
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    // Integers and doubles compare equal on the wire; the default only needs to match in value.
    private fun normalized(element: JsonElement): Any? =
        (element as? JsonPrimitive)?.let { it.doubleOrNull ?: it.content } ?: element

    private fun contract(): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.json") }
            .firstOrNull(Files::exists) ?: error("generation_parameter_contract.v1.json not found")
        return json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }
}
