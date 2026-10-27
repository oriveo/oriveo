package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Reads the dark palette source of truth shared by every client, `shared/theme-contracts/dark-palettes.v1.json` (read only).
 * Tests never copy a second set of hex values; expected values always come from here.
 */
object DarkPaletteContract {

    val root: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/theme-contracts/dark-palettes.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("dark-palettes.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    val defaultId: String get() = root.getValue("defaultId").jsonPrimitive.content

    val order: List<String> get() = root.getValue("order").jsonArray.map { it.jsonPrimitive.content }

    fun palette(id: String): JsonObject = root.getValue("palettes").jsonObject.getValue(id).jsonObject

    val status: JsonObject get() = root.getValue("shared").jsonObject.getValue("status").jsonObject

    val derived: JsonObject get() = root.getValue("derived").jsonObject

    val resolveCases: List<JsonObject> get() = root.getValue("resolveCases").jsonArray.map { it.jsonObject }

    /** JSON color field -> Android field reader. */
    val fieldReaders: Map<String, (OriveoColors) -> Color> = linkedMapOf(
        "bg" to { c -> c.backgroundBase },
        "bgSubtle" to { c -> c.background },
        "bgInset" to { c -> c.surfaceInset },
        "surface" to { c -> c.surface },
        "surfaceRaised" to { c -> c.surfaceElevated },
        "text" to { c -> c.textPrimary },
        "textSecondary" to { c -> c.textSecondary },
        "textTertiary" to { c -> c.textTertiary },
        "primary" to { c -> c.primary },
        "primaryHover" to { c -> c.primaryPressed },
        "primaryActive" to { c -> c.primaryActive },
        "accent" to { c -> c.accent },
        "onPrimary" to { c -> c.onPrimary },
        "codeBg" to { c -> c.codeBlockBg },
        "codeHeaderBg" to { c -> c.codeBlockHeaderBg },
    )

    fun color(element: JsonElement): Color {
        val hex = element.jsonPrimitive.content.removePrefix("#")
        require(hex.length == 6) { "only #RRGGBB is accepted: $hex" }
        return Color(0xFF000000L or hex.toLong(16))
    }

    fun float(element: JsonElement): Float = element.jsonPrimitive.content.toFloat()

    /** The 7 palette instances, in JSON order. */
    fun instances(): List<Pair<String, OriveoColors>> = order.map { it to DarkPaletteId.fromId(it).colors }
}
