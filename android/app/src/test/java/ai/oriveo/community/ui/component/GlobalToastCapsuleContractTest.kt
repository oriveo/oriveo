package ai.oriveo.community.ui.component

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PriorityHigh
import androidx.compose.material.icons.rounded.Remove
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The global top toast uses the same capsule spec on every platform (iOS `ToastOverlay` is the reference).
 *
 * Glyphs and accent colors are asserted by calling the production mapping functions, not hand-made
 * samples; the shape and the migration scope can only be guarded from source.
 */
class GlobalToastCapsuleContractTest {

    private val mainRoot = File("src/main/java")
    private val hostSource = File(mainRoot, "ai/oriveo/community/ui/component/GlobalToastHost.kt").readText()

    @Test
    fun `capsule is fully rounded and uses neutral border, not accent`() {
        assertTrue(hostSource.contains("RoundedCornerShape(percent = 50)"))
        assertTrue(hostSource.contains(".border(1.dp, colors.border, GlobalToastShape)"))
        assertTrue(hostSource.contains("widthIn(max = 480.dp)"))
    }

    @Test
    fun `every style maps to the iOS glyph`() {
        val expected = mapOf(
            GlobalToastStyle.Success to Icons.Rounded.Check,
            GlobalToastStyle.Error to Icons.Rounded.Close,
            GlobalToastStyle.Warning to Icons.Rounded.PriorityHigh,
            GlobalToastStyle.Removed to Icons.Rounded.Remove,
            GlobalToastStyle.Neutral to Icons.Rounded.Notifications,
        )
        GlobalToastStyle.entries.forEach { style ->
            val glyph = style.toastGlyph()
            val want = expected[style]
            if (want != null) {
                assertEquals("$style glyph", want, glyph)
            } else {
                // Info uses a custom bare i and must not fall back to the ringed Material Info
                assertEquals(GlobalToastStyle.Info, style)
                assertEquals("Oriveo.ToastInfo", glyph.name)
            }
        }
    }

    @Test
    fun `every style maps to its semantic accent in both themes`() {
        listOf(LightOriveoColors, DarkOriveoColors).forEach { colors ->
            val expected = mapOf(
                GlobalToastStyle.Success to colors.success,
                GlobalToastStyle.Error to colors.danger,
                GlobalToastStyle.Warning to colors.warning,
                GlobalToastStyle.Info to colors.info,
                GlobalToastStyle.Removed to colors.textSecondary,
                GlobalToastStyle.Neutral to colors.textSecondary,
            )
            assertEquals(GlobalToastStyle.entries.toSet(), expected.keys)
            GlobalToastStyle.entries.forEach { style ->
                assertEquals("$style accent", expected.getValue(style), style.toastAccent(colors))
            }
        }
    }

    @Test
    fun `provider detail removal feedback goes through the global toast`() {
        val source = File(mainRoot, "ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt").readText()
        assertFalse(source.contains("RemovalBanner"))
        assertTrue(source.contains("GlobalToastStyle.Removed"))
        assertTrue(source.contains("R.string.provider_detail_removed_model"))
    }

    @Test
    fun `no system Toast anywhere in main sources`() {
        // Every window (the main window / every sheet / the full-screen blocking Dialog) hosts a toast, so a system Toast has no reason left to exist.
        val offenders = kotlinSources()
            .filter { (_, lines) -> lines.any { it.isCode() && it.contains("Toast.makeText(") } }
            .map { (path, _) -> path }
        assertTrue("migrate to GlobalSnackbarManager: $offenders", offenders.isEmpty())
    }

    @Test
    fun `shared sheet wrapper mounts the toast host inside the sheet window`() {
        val wrapper = File(mainRoot, WRAPPER_PATH).readText()
        assertTrue(wrapper.contains("fun OriveoModalBottomSheet("))
        assertTrue(wrapper.contains("SheetToastLayer { content() }"))
        val layer = wrapper.substringAfter("fun SheetToastLayer(")
        assertTrue("SheetToastLayer must mount GlobalToastHost", layer.contains("GlobalToastHost("))
    }

    @Test
    fun `every bottom sheet goes through the wrapper`() {
        // Using Material3 ModalBottomSheet directly bypasses the toast host in the sheet window, and feedback gets covered.
        val offenders = kotlinSources()
            .filterNot { (path, _) -> path == WRAPPER_PATH }
            .filter { (_, lines) ->
                lines.any { line ->
                    line.isCode() && (
                        line.trim() == "import androidx.compose.material3.ModalBottomSheet" ||
                            Regex("""(?<![\w.`])ModalBottomSheet\(""").containsMatchIn(line)
                        )
                }
            }
            .map { (path, _) -> path }
        assertTrue("use OriveoModalBottomSheet: $offenders", offenders.isEmpty())
    }

    @Test
    fun `root host stays at the bottom and full-screen dialog wrapper mounts a host`() {
        val navHost = File(mainRoot, "ai/oriveo/community/core/navigation/OriveoNavHost.kt").readText()
        assertTrue("root host must stay at the bottom of the stack", navHost.contains("isRoot = true"))
        val wrapper = File(mainRoot, DIALOG_WRAPPER_PATH).readText()
        assertTrue(wrapper.contains("fun OriveoFullScreenDialog("))
        assertTrue(wrapper.contains("DialogToastLayer { content() }"))
        val layer = wrapper.substringAfter("fun DialogToastLayer(")
        assertTrue("DialogToastLayer must mount GlobalToastHost", layer.contains("GlobalToastHost("))
        // Full-screen windows known to raise feedback: the onboarding replay in Settings (legal links) and the blocking screen (failure to open settings)
        listOf(
            "ai/oriveo/community/feature/settings/SettingsScreen.kt",
            "ai/oriveo/community/feature/storage/DatabaseBlockedDialog.kt",
        ).forEach { path ->
            assertTrue("$path must use OriveoFullScreenDialog", File(mainRoot, path).readText().contains("OriveoFullScreenDialog("))
        }
    }

    @Test
    fun `every raw Dialog goes through the full-screen wrapper unless it provably never toasts`() {
        // A raw Dialog is its own window and covers the main window's host; only a window proven never to raise a toast may be allowlisted.
        val offenders = kotlinSources()
            .filterNot { (path, _) -> path == DIALOG_WRAPPER_PATH || path in RAW_DIALOG_WHITELIST }
            .filter { (_, lines) -> lines.any { it.isCode() && Regex("""(?<![\w.`])Dialog\(""").containsMatchIn(it) } }
            .map { (path, _) -> path }
        assertTrue("use OriveoFullScreenDialog: $offenders", offenders.isEmpty())
        RAW_DIALOG_WHITELIST.keys.forEach { path ->
            val source = File(mainRoot, path).readText()
            assertFalse("$path is whitelisted as never toasting", source.contains("GlobalSnackbarManager"))
            assertFalse("$path is whitelisted as never toasting", source.contains("launchExternalActivityOrNotify"))
            assertFalse("$path is whitelisted as never toasting", source.contains("openOriveoWebPage"))
        }
    }

    private fun kotlinSources(): List<Pair<String, List<String>>> = mainRoot.walkTopDown()
        .filter { it.isFile && it.extension == "kt" }
        .map { it.relativeTo(mainRoot).invariantSeparatorsPath to it.readLines() }
        .toList()

    private fun String.isCode(): Boolean {
        val code = trim()
        return !code.startsWith("*") && !code.startsWith("//") && !code.startsWith("/*")
    }

    private companion object {
        const val WRAPPER_PATH = "ai/oriveo/community/ui/component/OriveoModalBottomSheet.kt"
        const val DIALOG_WRAPPER_PATH = "ai/oriveo/community/ui/component/OriveoFullScreenDialog.kt"

        /** Files allowed to use Dialog directly, mapped to the reason. Before adding one, prove the window has no toast trigger. */
        val RAW_DIALOG_WHITELIST = emptyMap<String, String>()
    }
}
