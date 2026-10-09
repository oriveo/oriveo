package ai.oriveo.community.ui.component

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-level performance and visual contract for the system bar fading edge modifier.
 *
 * The project has no compose-ui-test dependency, so real recomposition counts are out of reach.
 * Like the other rendering contract tests, this strips comments and asserts on the production
 * source structure.
 *
 * It locks two things:
 * 1. The modifier must not go back to `Modifier.composed {}`. `composed` builds a new modifier
 *    that captures a lambda and has no `equals`, so two recompositions with identical inputs never
 *    produce equal chains. A `LazyColumn(modifier = ...)` then can never skip recomposition and the
 *    node chain diff loses its reuse fast path.
 * 2. The visual recipe stays as is: `CompositingStrategy.Offscreen` plus a vertical `DstIn`
 *    gradient at each end, and the 20dp default fade length. Dropping the offscreen layer changes
 *    the look because the `DstIn` erase needs its own layer.
 */
class SystemBarFadingEdgeContractTest {

    private val modifierPath = "ui/component/SystemBarFadingEdge.kt"

    @Test
    fun `fading edge modifier is not built with Modifier composed`() {
        val code = codeWithoutComments(modifierPath)

        assertFalse(
            "$modifierPath must not use Modifier.composed{}: its chain is never equal across " +
                "recompositions, so the full-screen LazyColumn recomposes and remeasures every time. " +
                "Use a @Composable factory with remember instead.",
            code.contains("composed(") || code.contains("composed {") || code.contains("androidx.compose.ui.composed"),
        )
    }

    @Test
    fun `fading edge modifier chain is remembered by all of its inputs`() {
        val code = codeWithoutComments(modifierPath)

        assertTrue(
            "The factory must be @Composable so it can read LocalDensity and remember",
            code.contains("@Composable\nfun Modifier.oriveoSystemBarFadingEdges("),
        )
        // The remember key has to cover every input: the three pixel values stand for the three Dp
        // parameters times LocalDensity. Missing one leaves a stale fade band after an inset
        // collapse, a font size change or a custom fadeLength.
        val key = Regex("remember\\(([^)]*)\\)").find(code)?.groupValues?.get(1)
        assertTrue(
            "The modifier chain must be remembered, otherwise it is rebuilt on every recomposition like composed{}",
            key != null,
        )
        listOf("topInsetPx", "bottomInsetPx", "fadePx").forEach { input ->
            assertTrue(
                "remember key is missing $input, so the fade band would keep its old value when it changes. Current key: ($key)",
                key!!.contains(input),
            )
        }
        assertTrue(
            "Pixel values must be derived from LocalDensity so a density change reaches the remember key",
            code.contains("val density = LocalDensity.current"),
        )
        assertTrue(
            "The cached chain must be appended after the caller's receiver, in the original order",
            code.contains("return this.then(fadingEdges)"),
        )
    }

    @Test
    fun `fading edge keeps its offscreen DstIn recipe unchanged`() {
        val code = codeWithoutComments(modifierPath)

        assertTrue(
            "The DstIn erase needs its own layer; removing Offscreen changes the look",
            code.contains("compositingStrategy = CompositingStrategy.Offscreen"),
        )
        assertEquals("One DstIn erase band at the top and one at the bottom", 2, code.split("BlendMode.DstIn").size - 1)
        assertEquals("One vertical gradient per end", 2, code.split("Brush.verticalGradient(").size - 1)
        assertTrue("Default fade length stays 20dp", source(modifierPath).contains("OriveoSystemBarFadeLength: Dp = 20.dp"))
    }

    @Test
    fun `home and providers still drive the fading edge from banner aware insets`() {
        listOf(
            "feature/home/HomeScreen.kt",
            "feature/providers/ProvidersScreen.kt",
        ).forEach { path ->
            val code = codeWithoutComments(path)
            assertTrue("$path must still attach the fading edge", code.contains("oriveoSystemBarFadingEdges("))
            assertTrue(
                "$path must take the top inset from the banner-aware rootTabTopInset(), not bare statusBars",
                code.contains("val statusBarInset = rootTabTopInset()"),
            )
            assertTrue(
                "$path must still take the bottom inset from the navigation bar height",
                code.contains("WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()"),
            )
        }
    }

    private fun source(relativePath: String): String =
        File("src/main/java/ai/oriveo/community/$relativePath").readText()

    /** Source with comments stripped; the explanatory comments here mention `Modifier.composed{}` themselves. */
    private fun codeWithoutComments(relativePath: String): String =
        source(relativePath)
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lineSequence()
            .joinToString("\n") { it.substringBefore("//") }
}
