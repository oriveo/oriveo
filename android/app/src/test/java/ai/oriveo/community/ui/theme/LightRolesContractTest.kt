package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
import java.nio.file.Files
import java.nio.file.Paths
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks [LightOriveoColors] to the shared light-role contract `light-roles.v1.json`.
 * Expected values come only from the contract; this file keeps the Android name -> field table.
 */
class LightRolesContractTest {

    private object LightRolesContract {
        /** The shared contract folder at the repo root, spelled by code points to keep this file ASCII. */
        private val RELATIVE_PATH = String(intArrayOf(0x5171, 0x4EAB), 0, 2) + "/theme-contracts/light-roles.v1.json"

        val root: JsonObject by lazy {
            val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
                .take(8)
                .map { it.resolve(RELATIVE_PATH) }
                .firstOrNull { Files.exists(it) }
                ?: error("light-roles.v1.json not found")
            Json.parseToJsonElement(path.toFile().readText()).jsonObject
        }

        val alphaTolerance: Float get() = root.getValue("alphaTolerance").jsonPrimitive.content.toFloat()

        val roles: Map<String, JsonObject>
            get() = root.getValue("roles").jsonObject.mapValues { it.value.jsonObject }

        /** Android tokens marked pending, token -> expected current `#RRGGBB`. */
        val androidPending: Map<String, String>
            get() = root["pending"]?.jsonArray.orEmpty()
                .map { it.jsonObject }
                .filter { it.getValue("end").jsonPrimitive.content == "android" }
                .associate { it.getValue("token").jsonPrimitive.content to it.getValue("current").jsonPrimitive.content }
    }

    /** Contract Android token name -> field of [OriveoColors]. */
    private val readers: Map<String, (OriveoColors) -> Color> = linkedMapOf(
        "primary" to { c -> c.primary },
        "primaryPressed" to { c -> c.primaryPressed },
        "primaryActive" to { c -> c.primaryActive },
        "primarySoft" to { c -> c.primarySoft },
        "primaryGlow" to { c -> c.primaryGlow },
        "primaryTextSafe" to { c -> c.primaryTextSafe },
        "primaryFillText" to { c -> c.primaryFillText },
        "onPrimary" to { c -> c.onPrimary },
        "backgroundBase" to { c -> c.backgroundBase },
        "background" to { c -> c.background },
        "backgroundSecondary" to { c -> c.backgroundSecondary },
        "surfaceInset" to { c -> c.surfaceInset },
        "surface" to { c -> c.surface },
        "surfaceElevated" to { c -> c.surfaceElevated },
        "surfaceChrome" to { c -> c.surfaceChrome },
        "textPrimary" to { c -> c.textPrimary },
        "textSecondary" to { c -> c.textSecondary },
        "textTertiary" to { c -> c.textTertiary },
        "textDisabledOnControl" to { c -> c.textDisabledOnControl },
        "neutralFill" to { c -> c.neutralFill },
        "border" to { c -> c.border },
        "borderStrong" to { c -> c.borderStrong },
        "hairline" to { c -> c.hairline },
        "borderSubtle" to { c -> c.borderSubtle },
        "switchThumb" to { c -> c.switchThumb },
        "overlay" to { c -> c.overlay },
        "shadow" to { c -> c.shadow },
        "success" to { c -> c.success },
        "successSoft" to { c -> c.successSoft },
        "successText" to { c -> c.successText },
        "onSuccess" to { c -> c.onSuccess },
        "danger" to { c -> c.danger },
        "error" to { c -> c.error },
        "dangerSoft" to { c -> c.dangerSoft },
        "errorSoft" to { c -> c.errorSoft },
        "dangerText" to { c -> c.dangerText },
        "onDanger" to { c -> c.onDanger },
        "warning" to { c -> c.warning },
        "warningSoft" to { c -> c.warningSoft },
        "warningText" to { c -> c.warningText },
        "onWarning" to { c -> c.onWarning },
        "info" to { c -> c.info },
        "infoSoft" to { c -> c.infoSoft },
        "infoText" to { c -> c.infoText },
        "onInfo" to { c -> c.onInfo },
        "primarySubtle" to { c -> c.primarySubtle },
        "focusRing" to { c -> c.focusRing },
        "composerBorder" to { c -> c.composerBorder },
        "surfaceOverlay" to { c -> c.surfaceOverlay },
        "accentSubtle" to { c -> c.accentSubtle },
    )

    private fun androidTokens(role: JsonObject): List<String> =
        role["android"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content }

    private fun rgbHex(color: Color): String {
        fun channel(v: Float) = (v * 255f).roundToInt().coerceIn(0, 255)
        return "#%02X%02X%02X".format(channel(color.red), channel(color.green), channel(color.blue))
    }

    @Test
    fun everyContractTokenIsMapped() {
        val missing = (LightRolesContract.roles.values.flatMap(::androidTokens) + LightRolesContract.androidPending.keys)
            .filterNot { it in readers }
        assertTrue("Contract Android tokens without a reader: $missing", missing.isEmpty())
    }

    @Test
    fun lightTokensMatchContract() {
        val tolerance = LightRolesContract.alphaTolerance
        val mismatches = mutableListOf<String>()
        var checked = 0
        for ((roleId, role) in LightRolesContract.roles) {
            val expectedHex = role.getValue("color").jsonPrimitive.content.uppercase()
            val expectedAlpha = role["alpha"]?.jsonPrimitive?.content?.toFloat() ?: 1f
            for (token in androidTokens(role)) {
                val reader = readers[token] ?: continue
                val actual = reader(LightOriveoColors)
                checked++
                val actualHex = rgbHex(actual)
                if (actualHex != expectedHex) {
                    mismatches += "$roleId/$token rgb $actualHex != $expectedHex"
                }
                if (abs(actual.alpha - expectedAlpha) > tolerance) {
                    mismatches += "$roleId/$token alpha ${actual.alpha} != $expectedAlpha"
                }
            }
        }
        assertTrue("No contract token was checked", checked > 0)
        assertEquals("Light tokens differ from the contract:\n" + mismatches.joinToString("\n"), 0, mismatches.size)
    }

    @Test
    fun pendingTokensStillAtCurrent() {
        val tolerance = LightRolesContract.alphaTolerance
        val mismatches = mutableListOf<String>()
        for ((token, current) in LightRolesContract.androidPending) {
            val reader = readers[token]
            if (reader == null) {
                mismatches += "$token has no reader"
                continue
            }
            val actual = reader(LightOriveoColors)
            val actualHex = rgbHex(actual)
            if (actualHex != current.uppercase()) mismatches += "$token rgb $actualHex != ${current.uppercase()}"
            if (abs(actual.alpha - 1f) > tolerance) mismatches += "$token alpha ${actual.alpha} != 1"
        }
        assertEquals(
            "Pending Android tokens must still be at `current`; remove the pending entry when its unit lands:\n" +
                mismatches.joinToString("\n"),
            0,
            mismatches.size,
        )
    }

    @Test
    fun mappedTokensAreAllInContract() {
        val known = LightRolesContract.roles.values.flatMap(::androidTokens).toSet() +
            LightRolesContract.androidPending.keys
        val stray = readers.keys.filterNot { it in known }
        assertTrue("Readers without a contract Android token: $stray", stray.isEmpty())
    }

    @Test
    fun darkStatusTextEqualsStatusColor() {
        val mismatches = mutableListOf<String>()
        for ((id, c) in DarkPaletteContract.instances()) {
            if (c.successText != c.success) mismatches += "$id.successText ${c.successText} != ${c.success}"
            if (c.dangerText != c.danger) mismatches += "$id.dangerText ${c.dangerText} != ${c.danger}"
            if (c.infoText != c.info) mismatches += "$id.infoText ${c.infoText} != ${c.info}"
        }
        assertEquals("Dark status text differs from status color:\n" + mismatches.joinToString("\n"), 0, mismatches.size)
    }
}
