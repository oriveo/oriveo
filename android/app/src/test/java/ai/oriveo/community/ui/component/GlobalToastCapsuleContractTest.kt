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
    fun `system Toast only remains where the global host cannot be seen`() {
        // These entry points fire inside a ModalBottomSheet / dialog window (which covers the main window's
        // GlobalToastHost), or on the database-blocked screen (NavHost is short-circuited and the host is never
        // mounted). A system Toast is always on top, so it has to stay there.
        val allowed = setOf(
            "ai/oriveo/community/ui/component/ImageViewerSheet.kt",
            "ai/oriveo/community/ui/component/markdown/MarkdownMessageView.kt",
            "ai/oriveo/community/core/util/ExternalLaunch.kt",
            "ai/oriveo/community/feature/chat/components/ProviderDisclosureSheet.kt",
            "ai/oriveo/community/feature/providers/SubscriptionVerificationPage.kt",
            "ai/oriveo/community/feature/providers/detail/CustomRequestFieldsPage.kt",
            "ai/oriveo/community/feature/storage/StorageSettingsLauncher.kt",
        )
        val offenders = mainRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                file.readLines().any { line ->
                    val code = line.trim()
                    !code.startsWith("*") && !code.startsWith("//") && code.contains("Toast.makeText(")
                }
            }
            .map { it.relativeTo(mainRoot).invariantSeparatorsPath }
            .filterNot { it in allowed }
            .toList()
        assertTrue("migrate to GlobalSnackbarManager: $offenders", offenders.isEmpty())
    }
}
