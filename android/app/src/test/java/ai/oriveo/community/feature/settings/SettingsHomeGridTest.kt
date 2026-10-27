package ai.oriveo.community.feature.settings

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceEngineSelection
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Settings home grid: the expected layouts come from the cases shared by every client in
 * `shared/theme-contracts/settings-home.v1.json`, asserted one by one by name, never copied into the test.
 */
class SettingsHomeGridTest {

    private val root: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/theme-contracts/settings-home.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("settings-home.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private fun cases(key: String): List<JsonObject> = root.getValue(key).jsonArray.map { it.jsonObject }

    private fun case(key: String, name: String): JsonObject =
        cases(key).firstOrNull { it.getValue("name").jsonPrimitive.content == name }
            ?: error("$key has no case named $name")

    private fun assertGridCase(name: String) {
        val case = case("gridCases", name)
        val count = case.getValue("count").jsonPrimitive.int
        val expected = case.getValue("columns").jsonPrimitive.int to case.getValue("rows").jsonPrimitive.int
        assertEquals(name, expected, settingsGridShape(count))
    }

    @Test
    fun `every shared case name is covered here`() {
        assertEquals(
            setOf(
                "grid_four_items_two_by_two",
                "grid_three_items_one_by_three",
                "grid_two_items_one_by_two",
                "grid_one_item_full_row",
                "grid_zero_items_hidden",
            ),
            cases("gridCases").map { it.getValue("name").jsonPrimitive.content }.toSet(),
        )
    }

    @Test
    fun `grid_four_items_two_by_two`() = assertGridCase("grid_four_items_two_by_two")

    @Test
    fun `grid_three_items_one_by_three`() = assertGridCase("grid_three_items_one_by_three")

    @Test
    fun `grid_two_items_one_by_two`() = assertGridCase("grid_two_items_one_by_two")

    @Test
    fun `grid_one_item_full_row`() = assertGridCase("grid_one_item_full_row")

    @Test
    fun `grid_zero_items_hidden`() = assertGridCase("grid_zero_items_hidden")

    @Test
    fun `grid line color follows the shared alpha formula`() {
        val alpha = root.getValue("gridLineAlpha").jsonObject
        val base = alpha.getValue("base").jsonPrimitive.content.toFloat()
        val perGlowK = alpha.getValue("perGlowK").jsonPrimitive.content.toFloat()
        val primary = Color(0xFF8B5CF6)
        listOf(0.4f, 1f).forEach { glowK ->
            val dark = settingsGridLineColor(isDark = true, primary = primary, glowK = glowK)
            assertEquals(base + perGlowK * glowK, dark.alpha, 0.01f)
            assertEquals(primary.copy(alpha = dark.alpha), dark)
        }
        assertEquals(Color.Black.copy(alpha = 0.10f), settingsGridLineColor(isDark = false, primary = primary, glowK = 1f))
    }

    @Test
    fun `voice tile shows the same engine label as the voice page`() {
        // The same production function as the engine row of the voice page: System -> the "System" resource, cloud -> the provider display name
        assertEquals(UiText.Resource(R.string.voice_engine_system), voiceEngineLabel(VoiceEngineSelection.System))
        assertEquals(
            UiText.Dynamic(ProviderKind.OpenAI.displayName),
            voiceEngineLabel(VoiceEngineSelection.Cloud(ProviderKind.OpenAI, connectionId = "c1", model = "tts-1")),
        )
    }
}
