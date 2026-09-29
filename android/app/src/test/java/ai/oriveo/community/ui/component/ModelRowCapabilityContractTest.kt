package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.ModelCapability
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Cross-platform model-row capability badges: reads `shared/model-contracts/model_row_capability_badges.v1.json`,
 * the same fixture iOS and Web read. The picker row and the provider detail row must share one limit constant.
 */
class ModelRowCapabilityContractTest {
    @Serializable
    private data class Case(val name: String, val input: List<String>, val expected: List<String>)

    @Serializable
    private data class Fixture(val contractVersion: Int, val maxVisible: Int, val cases: List<Case>)

    private val fixture: Fixture by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/model-contracts/model_row_capability_badges.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("model_row_capability_badges.v1.json not found")
        Json { ignoreUnknownKeys = true }.decodeFromString(Fixture.serializer(), path.toFile().readText())
    }

    private fun capability(raw: String): ModelCapability =
        ModelCapability.entries.firstOrNull { it.raw == raw } ?: error("unknown capability $raw")

    @Test
    fun `row limit matches the shared contract`() {
        assertEquals(1, fixture.contractVersion)
        assertEquals(fixture.maxVisible, MODEL_ROW_MAX_CAPABILITIES)
    }

    @Test
    fun `truncation matches every shared case`() {
        assertTrue(fixture.cases.isNotEmpty())
        fixture.cases.forEach { case ->
            assertEquals(
                case.name,
                case.expected.map(::capability),
                limitModelRowCapabilities(case.input.map(::capability), fixture.maxVisible),
            )
        }
    }

    @Test
    fun `picker row and provider detail row share the same limit and strip`() {
        val picker = source("feature/modelpicker/ModelPickerSheet.kt")
            .substringAfter("private fun ModelPickerRow(")
            .substringBefore("fun buildProviderSections(")
        val detail = source("feature/providers/detail/ProviderDetailEnabledModels.kt")
            .substringAfter("private fun EnabledModelMetadataRow(")
        for (row in listOf(picker, detail)) {
            assertTrue(row.contains(".governedMetadataCapabilities(provider, model)"))
            assertTrue(row.contains("maxCapabilities = MODEL_ROW_MAX_CAPABILITIES,"))
        }
        // The picker must not add a second set of "Web search / Reasoning / Tools" pills.
        assertTrue(!picker.contains("modelPickerCapabilityBadges("))
    }

    private fun source(relative: String): String =
        File("src/main/java/ai/oriveo/community/$relative").readText()
}
