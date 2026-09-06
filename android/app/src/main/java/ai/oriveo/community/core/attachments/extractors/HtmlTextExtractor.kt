package ai.oriveo.community.core.attachments.extractors

import org.jsoup.Jsoup

object HtmlTextExtractor {
    fun extract(data: ByteArray): String {
        val html = String(data, Charsets.UTF_8)
        val doc = Jsoup.parse(html)

        doc.select("script, style, noscript").remove()
        return doc.body().text()
    }
}
