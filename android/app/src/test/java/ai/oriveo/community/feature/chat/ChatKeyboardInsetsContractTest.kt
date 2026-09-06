package ai.oriveo.community.feature.chat

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatKeyboardInsetsContractTest {
    @Test
    fun `main activity uses adjustResize so Compose receives IME insets`() {
        val manifest = File("src/main/AndroidManifest.xml")
        val document = DocumentBuilderFactory
            .newInstance()
            .apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(manifest)
        val activities = document.getElementsByTagName("activity")
        val androidNamespace = "http://schemas.android.com/apk/res/android"

        val mainActivity = (0 until activities.length)
            .asSequence()
            .map { activities.item(it) }
            .first { activity ->
                activity.attributes
                    .getNamedItemNS(androidNamespace, "name")
                    ?.nodeValue == ".MainActivity"
            }
        val softInputMode = mainActivity.attributes
            .getNamedItemNS(androidNamespace, "windowSoftInputMode")
            ?.nodeValue

        assertEquals("adjustResize", softInputMode)
    }

    @Test
    fun `chat screen has a single IME padding owner`() {
        val source = listOf(
            "src/main/java/ai/oriveo/community/feature/chat/ChatScreen.kt",
            "src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt",
        ).joinToString("\n") { File(it).readText() }

        val imeOwnerCalls = Regex("""windowInsetsPadding\(\s*WindowInsets\.ime""")
            .findAll(source)
            .count()

        assertEquals(1, imeOwnerCalls)
    }
}
