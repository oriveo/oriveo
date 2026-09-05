package ai.oriveo.community.core.model

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.elementNames
import kotlinx.serialization.json.Json

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths
/**
 * Cross-platform contract for outbound sanitization (`shared/test-fixtures/relay/portable-config.v1.json`).
 *
 * Two things: 1. `RelayRequestedConfig`'s complete field surface must match the fixture's
 * `allFields` exactly -- a new field that hasn't declared its outbound allowlist status shows
 * up as red here; 2. every case round-trips through the production
 * [credentialFreePortableCopy], and none of the device-local-only fields may appear in the result.
 */
class RelayPortableConfigContractTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    @Serializable
    private data class PortableContract(
        val version: Int,
        val allFields: List<String>,
        val portableFields: List<String>,
        val localOnlyFields: List<LocalOnlyField>,
        val cases: List<Case>,
    )

    @Serializable
    private data class LocalOnlyField(val field: String, val reason: String)

    @Serializable
    private data class Case(
        val caseId: String,
        val input: JsonObject,
        val expect: JsonObject,
    )

    private fun contract(): PortableContract {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/portable-config.v1.json")
            if (Files.exists(candidate)) {
                return json.decodeFromString(
                    PortableContract.serializer(),
                    String(Files.readAllBytes(candidate), Charsets.UTF_8),
                )
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("portable-config.v1.json not found")
    }

    @OptIn(ExperimentalSerializationApi::class)
    @Test
    fun `every RelayRequestedConfig field is registered as portable or local-only`() {
        val contract = contract()
        assertEquals(1, contract.version)
        val declared = RelayRequestedConfig.serializer().descriptor.elementNames.toSortedSet()
        assertEquals(contract.allFields.toSortedSet(), declared)
        assertEquals(contract.portableFields.toSortedSet(), PORTABLE_RELAY_REQUESTED_FIELDS.toSortedSet())
        assertEquals(
            contract.allFields.filterNot { it in contract.portableFields }.toSortedSet(),
            contract.localOnlyFields.map { it.field }.toSortedSet(),
        )
    }

    @Test
    fun `each case round-trips through the production sanitizer`() {
        val contract = contract()
        for (case in contract.cases) {
            val requested = json.decodeFromString(RelayRequestedConfig.serializer(), case.input.toString())
            val portable = json.encodeToJsonElement(requested.credentialFreePortableCopy()) as JsonObject

            for ((key, expected) in case.expect) {
                assertEquals("${case.caseId}: $key", expected, portable[key])
            }
            for (entry in contract.localOnlyFields) {
                assertNull("${case.caseId}: ${entry.field} must never leave the device", portable[entry.field])
            }
            val unexpected = portable.keys - contract.portableFields.toSet()
            assertTrue("${case.caseId}: unregistered outbound fields $unexpected", unexpected.isEmpty())
            // Fixture secrets are always written as literals containing "secret"; none may survive into the outbound copy.
            assertTrue(
                "${case.caseId}: sanitized copy still carries a credential literal",
                !portable.toString().contains("secret"),
            )
        }
    }
}
