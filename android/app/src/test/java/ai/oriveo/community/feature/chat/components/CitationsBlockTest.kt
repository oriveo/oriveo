package ai.oriveo.community.feature.chat.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CitationsBlockTest {
    @Test
    fun `only HTTPS URLs with a host can be opened`() {
        assertTrue(isOpenableCitationUrl("https://docs.example.com/page"))

        assertFalse(isOpenableCitationUrl("http://example.com"))
        assertFalse(isOpenableCitationUrl("javascript:alert(1)"))
        assertFalse(isOpenableCitationUrl("intent://example.com/#Intent;scheme=https;end"))
        assertFalse(isOpenableCitationUrl("file:///tmp/document"))
        assertFalse(isOpenableCitationUrl("https://user@example.com/private"))
        assertFalse(isOpenableCitationUrl("https:///missing-host"))
        assertFalse(isOpenableCitationUrl("example.com/page"))
    }

    @Test
    fun `web citations get a host favicon and library sources keep their symbol`() {
        assertEquals(
            "https://www.google.com/s2/favicons?domain=example.com&sz=64",
            citationFaviconUrl("https://www.Example.com/a?b=1", null),
        )
        assertEquals(
            "https://www.google.com/s2/favicons?domain=news.example.org&sz=64",
            citationFaviconUrl("https://news.example.org/x", "external_search"),
        )
        assertNull(citationFaviconUrl("https://www.notion.so/page", "notion"))
        assertNull(citationFaviconUrl("https://docs.google.com/document/d/1", "google"))
        assertNull(citationFaviconUrl("library-context://mcp/doc-1", "mcp"))
        assertNull(citationFaviconUrl("http://example.com", null))
    }
}
