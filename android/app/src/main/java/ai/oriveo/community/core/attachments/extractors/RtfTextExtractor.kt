package ai.oriveo.community.core.attachments.extractors


object RtfTextExtractor {

    private val controlWord = Regex("\\\\[a-zA-Z]+-?\\d*\\s?")
    private val hexEscape = Regex("\\\\'([0-9a-fA-F]{2})")
    private val braces = Regex("[{}]")

    fun extract(data: ByteArray): String {
        var s = String(data, Charsets.ISO_8859_1)
        
        s = hexEscape.replace(s) { m ->
            val byte = m.groupValues[1].toInt(16)
            byte.toChar().toString()
        }
        
        s = controlWord.replace(s, "")
        
        s = braces.replace(s, "")
        
        s = s.replace(Regex("\\s+"), " ").trim()
        return s
    }
}
