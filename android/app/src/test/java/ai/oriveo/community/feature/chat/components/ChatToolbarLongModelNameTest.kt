package ai.oriveo.community.feature.chat.components

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatToolbarLongModelNameTest {

    @Test
    fun `toolbar model title uses two lines`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/ChatToolbar.kt").readText()
        val titleSource = source.requiredSlice(
            from = "text = modelName",
            to = "if (providerName.isNotEmpty())",
        )

        assertTrue(titleSource.contains("maxLines = 2"))
    }
}

private fun String.requiredSlice(from: String, to: String): String {
    val startIndex = indexOf(from)
    require(startIndex >= 0) { "Missing start boundary: $from" }
    val endIndex = indexOf(to, startIndex + from.length)
    require(endIndex >= 0) { "Missing end boundary: $to" }
    return substring(startIndex, endIndex)
}
