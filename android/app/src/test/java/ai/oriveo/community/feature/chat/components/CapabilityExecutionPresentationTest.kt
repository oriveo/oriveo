package ai.oriveo.community.feature.chat.components

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Capability execution statuses must stay accessible and translated in every shipped locale. */
class CapabilityExecutionPresentationTest {

    private val keys = listOf(
        "capability_execution_status",
        "capability_execution_requested",
        "capability_execution_observed",
        "capability_execution_unconfirmed",
        "capability_execution_rejected",
        "capability_execution_recovered",
    )

    @Test
    fun `execution status strings have complete non-English locale parity`() {
        val resourceRoot = File("src/main/res")
        val default = strings(File(resourceRoot, "values/strings.xml"))
        val localized = resourceRoot.listFiles()
            ?.filter { it.name.startsWith("values-") }
            .orEmpty()
            
            .filter { File(it, "strings.xml").isFile }
            .map { it.name to strings(File(it, "strings.xml")) }

        assertTrue("all shipped non-default locales must be discovered", localized.size >= 15)
        localized.forEach { (locale, entries) ->
            keys.forEach { key ->
                val text = entries[key]
                assertTrue("$locale is missing $key", !text.isNullOrBlank())
                // The status template itself contains only formatting placeholders. Its content
                // is localized by the owner/status strings below, so punctuation may coincide.
                if (key != "capability_execution_status") {
                    assertFalse("$locale leaves $key as the default English placeholder", text == default[key])
                }
            }
        }
    }

    @Test
    fun `execution row exposes a TalkBack description for every rendered result`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        assertTrue(source.contains("CapabilityExecutionStatusText"))
        
        
        val statusText = source.substringAfter("private fun CapabilityExecutionStatusText")
        assertTrue("status text must build its TalkBack label from the status template", statusText.contains("R.string.capability_execution_status"))
        assertTrue("status text must expose the label via semantics contentDescription", statusText.contains("contentDescription ="))
        assertTrue(source.contains("capability_execution_requested"))
        assertTrue(source.contains("capability_execution_observed"))
        assertTrue(source.contains("capability_execution_unconfirmed"))
        assertTrue(source.contains("capability_execution_rejected"))
        assertTrue(source.contains("capability_execution_recovered"))
    }

    @Test
    fun `execution presentation mirrors iOS text hierarchy and wraps on narrow screens`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        val statusText = source.substringAfter("private fun CapabilityExecutionStatusText")
            .substringBefore("private fun AssistantFooterActionRow")

        assertFalse("execution facts must not render as colored pills", statusText.contains("StatusPill("))
        assertTrue("all facts must share one naturally wrapping Text", statusText.contains("Text("))
        assertTrue("the text must take the available message width", statusText.contains(".fillMaxWidth()"))
        assertTrue("facts must use the same deterministic order as iOS", statusText.contains(".sortedBy { it.owner }"))
        assertTrue("facts must share the iOS middle-dot separator", statusText.contains("joinToString(\" · \")"))
        assertTrue("facts are tertiary metadata, not warning emphasis", statusText.contains("color = colors.textTertiary"))

        val metadata = source.substringAfter("if (showMetadata &&")
            .substringBefore("/** P5 displays")
        assertTrue(
            "capability facts must follow provider/model metadata like iOS",
            metadata.indexOf("if (metadataText.isNotBlank())") < metadata.indexOf("CapabilityExecutionStatusText("),
        )
    }

    @Test
    fun `Chinese owner and state wording matches the iOS ground truth`() {
        val zhHans = strings(File("src/main/res/values-zh-rCN/strings.xml"))
        assertEquals("\u8054\u7f51", zhHans["capability_web"])
        assertEquals("\u63a8\u7406", zhHans["capability_reasoning"])
        assertEquals("\u53c2\u6570", zhHans["generation_parameters_section"])
        assertEquals("\u672a\u786e\u8ba4\u6267\u884c", zhHans["capability_execution_unconfirmed"])
    }

    private fun strings(file: File): Map<String, String> {
        val xml = file.readText()
        val pattern = Regex("""<string name=\"([^\"]+)\">(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
        return pattern.findAll(xml).associate { it.groupValues[1] to it.groupValues[2].trim() }
    }
}
