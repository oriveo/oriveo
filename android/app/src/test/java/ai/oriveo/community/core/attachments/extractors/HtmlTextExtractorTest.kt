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

    @Test
    fun adjacentCollapsedSpacesAcrossTextNodesMerge() {
        val html = "<p>a <b> b</b>  <i> c</i></p>"
        assertEquals("a b c", HtmlTextExtractor.extract(html.toByteArray()))
    }

    @Test
    fun emptyListItemsAreDropped() {
        val html = "<ul><li>One</li><li> </li><li><img src=x></li><li><ul><li>Nested</li></ul></li></ul>"
        assertEquals("- One\n  - Nested", HtmlTextExtractor.extract(html.toByteArray()))
    }

    @Test
    fun captionPrecedesTableAndEmptySpanRowsAreDropped() {
        val html = "<table><caption>Cap</caption><tr><td colspan=2>Wide</td></tr><tr><td> </td><td></td></tr>" +
            "<tr><td>a</td><td>b</td></tr></table>"
        assertEquals("Cap\n\nWide\na\tb", HtmlTextExtractor.extract(html.toByteArray()))
    }

    @Test
    fun unknownMetaCharsetCountsAsUndeclared() {
        val html = "<meta charset=\"x-unknown\"><p>caf\u00e9</p>".toByteArray(Charsets.UTF_8)
        assertNull(HtmlTextExtractor.declaredCharset(html))
        assertEquals("caf\u00e9", HtmlTextExtractor.extract(html))
    }

    @Test
    fun legacyEntitiesWithoutSemicolonDecode() {
        assertEquals("\u00a9 & \u00e9", HtmlTextExtractor.extract("<p>&copy &amp &eacute</p>".toByteArray()))
    }

    @Test
    fun metaCharsetAcceptsCandidateTargetNames() {
        val head = { label: String -> "<meta charset=\"$label\"><p>x</p>".toByteArray() }
        assertEquals("gb18030", HtmlTextExtractor.declaredCharset(head("GB18030")))
        assertEquals("windows-1252", HtmlTextExtractor.declaredCharset(head("windows-1252")))
        assertEquals("windows-1251", HtmlTextExtractor.declaredCharset(head("windows-1251")))
        val cyrillic = "<meta charset=\"windows-1251\"><p>".toByteArray() + byteArrayOf(0xCF.toByte(), 0xF0.toByte()) + "</p>".toByteArray()
        assertEquals("\u041F\u0440", HtmlTextExtractor.extract(cyrillic))
    }

    @Test
    fun brInsideListItemBecomesSpace() {
        assertEquals("- a b\n- c", HtmlTextExtractor.extract("<ul><li>a<br>b</li><li>c</li></ul>".toByteArray()))
    }

    @Test
    fun nestedTableFlattenKeepsEmptyCellsAndRows() {
        val html = "<table><tr><th>H</th><th>K</th></tr><tr><td><table><tr><td>a</td><td></td><td>c</td></tr>" +
            "<tr><td></td><td></td></tr><tr><td>d</td><td>e</td><td>f</td></tr></table></td><td>x</td></tr></table>"
        assertEquals(
            "| H | K |\n| --- | --- |\n| a; ; c / ;  / d; e; f | x |",
            HtmlTextExtractor.extract(html.toByteArray()),
        )
    }
}
