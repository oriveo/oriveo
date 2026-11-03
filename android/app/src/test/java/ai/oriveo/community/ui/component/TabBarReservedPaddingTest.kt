package ai.oriveo.community.ui.component

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Long pages under the floating tab bar must reserve the bar's real height (screen bottom to
 * capsule top, navigation bar included) plus 16dp, so the last row stays fully visible above it.
 */
class TabBarReservedPaddingTest {

    private fun source(path: String): String = File(path).readText()

    @Test
    fun tab_pages_reserve_bar_height_plus_16() {
        val pages = listOf(
            "src/main/java/ai/oriveo/community/feature/providers/ProvidersScreen.kt",
            "src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt",
        )
        for (page in pages) {
            assertTrue(
                "$page must pad its bottom with liquidGlassTabBarReservedHeight() + 16.dp",
                source(page).contains("liquidGlassTabBarReservedHeight() + 16.dp"),
            )
        }
    }

    @Test
    fun no_hardcoded_tab_bar_overlay() {
        val offenders = File("src/main").walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.readText().contains("tabBarOverlay") }
            .map { it.path }
            .toList()
        assertTrue("Hardcoded tabBarOverlay is still referenced in: $offenders", offenders.isEmpty())
    }
}
