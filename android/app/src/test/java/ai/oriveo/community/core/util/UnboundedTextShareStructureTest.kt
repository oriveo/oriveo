package ai.oriveo.community.core.util

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnboundedTextShareStructureTest {

    @Test
    fun `unbounded chat note and conversation payloads do not use EXTRA_TEXT`() {
        val sourcePaths = listOf(
            "src/main/java/ai/oriveo/community/feature/chat/ChatExportCoordinator.kt",
            "src/main/java/ai/oriveo/community/feature/notes/NoteDetailViewModel.kt",
            "src/main/java/ai/oriveo/community/feature/home/HomeViewModel.kt",
        )

        sourcePaths.forEach { path ->
            val source = File(path).readText()
            assertFalse("$path must not send unbounded content through EXTRA_TEXT", source.contains("Intent.EXTRA_TEXT"))
            assertTrue("$path must route sharing through TextShareLauncher", source.contains("TextShareLauncher"))
        }
    }

    @Test
    fun `file share implementation sends a content URI stream`() {
        val source = File("src/main/java/ai/oriveo/community/core/util/TextShareLauncher.kt").readText()

        assertTrue(source.contains("FileProvider.getUriForFile"))
        assertTrue(source.contains("Intent.EXTRA_STREAM"))
        assertTrue(source.contains("Intent.FLAG_GRANT_READ_URI_PERMISSION"))
    }
}
