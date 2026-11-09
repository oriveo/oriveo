package ai.oriveo.community.feature.chat.components

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source contract: the 16dp source icon slot in citation rows and search source rows has no fill,
 * matching iOS CitationRowView (bare 14pt tertiary icon).
 */
class CitationIconFillContractTest {
    @Test
    fun sharedSourceIconSlotHasNoFill() {
        val body = functionBody("CitationFavicon.kt", "internal fun CitationSourceIcon(")
        assertNoFilledIconSlot("CitationSourceIcon", body)
    }

    @Test
    fun citationRowsUseSharedSourceIcon() {
        for ((file, signature) in listOf(
            "CitationsBlock.kt" to "private fun CitationRow(",
            "ExternalSearchChat.kt" to "internal fun SearchSourcesBlock(",
        )) {
            val body = functionBody(file, signature)
            assertTrue("$signature must draw its icon through CitationSourceIcon", body.contains("CitationSourceIcon("))
            assertFalse("$signature must not draw a CircleShape fill behind the icon", body.contains("CircleShape"))
        }
    }

    private fun assertNoFilledIconSlot(name: String, body: String) {
        assertFalse(
            "$name must not wrap the source icon in a backgroundSecondary circle",
            body.contains("background(colors.backgroundSecondary, CircleShape)"),
        )
        assertFalse("$name must not draw a CircleShape fill behind the icon", body.contains("CircleShape"))
        assertTrue("$name keeps the 16dp icon slot", body.contains("Modifier.size(16.dp)"))
        assertTrue("$name draws the icon at 14dp", body.contains("modifier = Modifier.size(14.dp)"))
        assertTrue("$name tints the icon with textTertiary", body.contains("tint = colors.textTertiary"))
    }

    private fun functionBody(file: String, signature: String): String {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/$file").readText()
        val start = source.indexOf(signature)
        assertTrue("$signature must exist in $file", start >= 0)
        val next = Regex("""\n(@Composable|private fun |internal fun |fun )""").find(source, start + signature.length)
        return source.substring(start, next?.range?.first ?: source.length)
    }
}
