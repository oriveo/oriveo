package ai.oriveo.community.feature.chat.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * A size limit message states the limit that is actually enforced.
 *
 * The dialog and the extractor message both used to hard-code "50 MB", while the picker stops at
 * 25 MB and a model override can lower the extractor limit: a user who followed the message and
 * shrank the file to under 50 MB still could not attach it.
 */
class AttachmentSizeLimitMessageTest {

    private val resDir: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            val candidate = File(dir, "app/src/main/res")
            if (File(candidate, "values/strings.xml").exists()) return@lazy candidate
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android res directory from ${System.getProperty("user.dir")}")
    }

    private fun stringsByLocale(name: String): Map<String, String> =
        resDir.listFiles { file -> file.isDirectory && File(file, "strings.xml").exists() }
            .orEmpty()
            .sortedBy { it.name }
            .mapNotNull { valuesDir ->
                val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                    .parse(File(valuesDir, "strings.xml"))
                    .getElementsByTagName("string")
                (0 until nodes.length)
                    .map { nodes.item(it) as Element }
                    .firstOrNull { it.getAttribute("name") == name }
                    ?.let { valuesDir.name to it.textContent.orEmpty() }
            }
            .toMap()

    private fun occurrences(text: String, token: String): Int = text.split(token).size - 1

    @Test
    fun `a 30 MB file is told the 25 MB picker limit not 50 MB`() {
        val thirtyMb = 30L * 1024L * 1024L
        assertTrue(AttachmentImportPolicy.isOversized(thirtyMb))

        val limit = AttachmentImportPolicy.sizeLimitMegabytes(AttachmentImportPolicy.MAX_ATTACHMENT_BYTES)
        val message = stringsByLocale("attachment_too_large_message").getValue("values").format(limit)

        assertTrue(message, message.contains("25 MB"))
        assertFalse(message, message.contains("50"))
    }

    @Test
    fun `a limit that is not a whole megabyte rounds down and never reaches zero`() {
        assertEquals(2, AttachmentImportPolicy.sizeLimitMegabytes(2_621_440L))
        assertEquals(9, AttachmentImportPolicy.sizeLimitMegabytes(10_000_000L))
        assertEquals(1, AttachmentImportPolicy.sizeLimitMegabytes(4_096L))
    }

    @Test
    fun `each locale keeps its own unit next to the number`() {
        // The unit is part of the copy: passing a preformatted "25 MB" would replace the French Mo and
        // the Russian МБ with MB.
        val tooLarge = stringsByLocale("file_extraction_error_too_large")
        val dialog = stringsByLocale("attachment_too_large_message")

        assertTrue(tooLarge.getValue("values-fr"), tooLarge.getValue("values-fr").contains("%2\$d\u00a0Mo"))
        assertTrue(tooLarge.getValue("values-ru"), tooLarge.getValue("values-ru").contains("%2\$d МБ"))
        assertTrue(tooLarge.getValue("values-ar"), tooLarge.getValue("values-ar").contains("%2\$d ميجابايت"))
        assertTrue(tooLarge.getValue("values-ko"), tooLarge.getValue("values-ko").contains("%2\$dMB"))
        assertTrue(dialog.getValue("values-fr"), dialog.getValue("values-fr").contains("%1\$d Mo"))
        assertTrue(dialog.getValue("values-ru"), dialog.getValue("values-ru").contains("%1\$d МБ"))
        assertTrue(dialog.getValue("values-ko"), dialog.getValue("values-ko").contains("%1\$dMB"))
    }

    @Test
    fun `every locale takes the picker limit as a placeholder`() {
        val messages = stringsByLocale("attachment_too_large_message")

        assertEquals(16, messages.size)
        messages.forEach { (locale, text) ->
            assertEquals("$locale: $text", 1, occurrences(text, "%1\$d"))
            assertFalse("$locale: $text", text.contains("50"))
        }
    }

    @Test
    fun `every locale takes the file name and the extractor limit as placeholders`() {
        val messages = stringsByLocale("file_extraction_error_too_large")

        assertEquals(16, messages.size)
        messages.forEach { (locale, text) ->
            assertEquals("$locale: $text", 1, occurrences(text, "%1\$s"))
            assertEquals("$locale: $text", 1, occurrences(text, "%2\$d"))
            assertFalse("$locale: $text", text.contains("50"))
        }
    }

    @Test
    fun `every locale names the file that pushed the attached text over the limit`() {
        val messages = stringsByLocale("file_extraction_send_blocked_text_budget")

        assertEquals(16, messages.size)
        messages.forEach { (locale, text) ->
            assertEquals("$locale: $text", 1, occurrences(text, "%1\$s"))
            assertFalse("$locale: $text", text.contains("{fileName}"))
        }
    }

    @Test
    fun `the password protected message does not single out pdf in any locale`() {
        val messages = stringsByLocale("file_extraction_error_encrypted_pdf")

        assertEquals(16, messages.size)
        messages.forEach { (locale, text) ->
            assertEquals("$locale: $text", 1, occurrences(text, "%1\$s"))
            assertFalse("$locale: $text", text.contains("PDF"))
        }
    }

    @Test
    fun `arabic messages isolate the file name so a latin name cannot reorder the sentence`() {
        // File names are mostly Latin letters, digits and dots; without isolation the bidi algorithm reorders them with the surrounding punctuation and digits.
        val isolated = Regex("""\\u2066%\d+\${'$'}s\\u2069""")
        val placeholder = Regex("""%\d+\${'$'}s""")
        val names = listOf(
            "file_extraction_error_scanned_pdf",
            "file_extraction_error_encrypted_pdf",
            "file_extraction_error_corrupted",
            "file_extraction_error_unsupported",
            "file_extraction_error_too_large",
            "file_extraction_error_generic",
            "file_extraction_truncated_notice",
            "file_extraction_send_blocked_text_budget",
        )

        for (name in names) {
            val text = stringsByLocale(name).getValue("values-ar")
            val total = placeholder.findAll(text).count()
            assertTrue("$name has no file name placeholder: $text", total > 0)
            assertEquals("$name: $text", total, isolated.findAll(text).count())
        }
    }
}
