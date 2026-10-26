package ai.oriveo.community.core.provider

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reconciles the Android compile-time protocol implementation table with the shared wire_families.v1.json. */
class ProtocolImplementationsTest {
    private val root = Json.parseToJsonElement(workspaceFile("shared/model-contracts/wire_families.v1.json").readText()).jsonObject

    @Test
    fun `android table equals families whose implementedBy lists android`() {
        val expected = root.getValue("families").jsonArray.map { it.jsonObject }
            .filter { family -> family.getValue("implementedBy").jsonArray.any { it.jsonPrimitive.content == "android" } }
            .map { it.getValue("id").jsonPrimitive.content }
        assertEquals(expected.size, expected.toSet().size)
        assertEquals(expected.toSet(), CapabilityEvidenceFacade.ProtocolImplementations.android)
    }

    @Test
    fun `every android family is a declared family`() {
        val families = root.getValue("families").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }.toSet()
        for (id in CapabilityEvidenceFacade.ProtocolImplementations.android) {
            assertTrue(id, id in families)
            assertTrue(id, CapabilityEvidenceFacade.endImplementsWireFamily(id))
        }
        assertFalse(CapabilityEvidenceFacade.endImplementsWireFamily("gemini.file_data"))
        assertFalse(CapabilityEvidenceFacade.endImplementsWireFamily(null))
    }

    /** Looks up the relative path under the repository root, walking up from the current working directory (after MetadataClientRevisionTest.workspaceFile). */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }
}
