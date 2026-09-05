package ai.oriveo.community.core.attachments.extractors

import org.junit.Assert.*
import org.junit.Test

class HtmlTextExtractorTest {

    @Test
    fun basic() {
        val html = "<html><body><h1>Title</h1><p>Hello <b>world</b></p></body></html>"
        val r = HtmlTextExtractor.extract(html.toByteArray())
        assertTrue(r.contains("Title"))
        assertTrue(r.contains("Hello world"))
    }

    @Test
    fun scriptStyleStripped() {
        val html = """<html><head><script>alert('x')</script><style>body{color:red}</style></head>
                     <body><p>Visible</p></body></html>"""
        val r = HtmlTextExtractor.extract(html.toByteArray())
        assertTrue(r.contains("Visible"))
        assertFalse(r.contains("alert"))
        assertFalse(r.contains("color:red"))
    }
}
