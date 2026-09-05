package ai.oriveo.community.feature.chat.components


private const val PREVIEW_MAX_CHARACTERS = 40


private const val PREVIEW_SCAN_WINDOW = 160


private const val PREVIEW_SOURCE_LIMIT = 1024


internal fun reasoningTail(text: String): String {
    if (text.isEmpty()) return ""
    val source = if (text.length > PREVIEW_SOURCE_LIMIT) text.takeLast(PREVIEW_SOURCE_LIMIT) else text

    
    var end = source.length
    while (end > 0 && source[end - 1].isWhitespace()) end--
    if (end == 0) return ""

    
    var start = end
    var scanned = 0
    var reachedLineStart = false
    while (start > 0) {
        if (source[start - 1] == '\n') {
            reachedLineStart = true
            break
        }
        if (scanned >= PREVIEW_SCAN_WINDOW) break
        start--
        scanned++
    }
    if (start == 0 && source.length == text.length) reachedLineStart = true

    
    val stripped = strippingMarkers(source, start, end, reachedLineStart)

    
    
    
    
    if (stripped.all { it.isPreviewMarkerOnly() }) return ""

    
    if (stripped.length > PREVIEW_MAX_CHARACTERS) {
        return "…" + stripped.takeLast(PREVIEW_MAX_CHARACTERS)
    }
    return if (reachedLineStart) stripped else "…$stripped"
}


private fun Char.isPreviewMarkerOnly(): Boolean = isWhitespace() || this in "*`~#>-+_|="


private fun strippingMarkers(source: String, start: Int, end: Int, isLineStart: Boolean): String {
    var index = if (isLineStart) start + blockMarkerPrefixLength(source, start, end) else start
    val output = StringBuilder(end - index)

    while (index < end) {
        val character = source[index]

        if (character == '*' || character == '`' || character == '~') {
            var run = 1
            while (index + run < end && source[index + run] == character) run++
            
            val isEscaped = index > start && source[index - 1] == '\\'
            val isEmphasisMarker = character != '~' || run >= 2
            val attachedLeft = index > start && !source[index - 1].isWhitespace()
            val attachedRight = index + run < end && !source[index + run].isWhitespace()
            val isNumericOperator = run == 1 &&
                index > start && source[index - 1].isDigit() &&
                index + run < end && source[index + run].isDigit()
            
            val isInlineMarker = if (character == '*' && run == 1) {
                (!attachedLeft && attachedRight) || (attachedLeft && attachedRight && !isNumericOperator)
            } else {
                attachedLeft || attachedRight
            }
            if (!isEscaped && isEmphasisMarker && isInlineMarker) {
                index += run
                continue
            }
            repeat(run) { output.append(character) }
            index += run
            continue
        }

        if (character == '[') {
            val link = linkSpan(source, index, end)
            if (link != null) {
                output.append(source, link.textStart, link.textEnd)
                index = link.spanEnd
                continue
            }
        }

        output.append(character)
        index++
    }

    return output.toString()
}


private fun blockMarkerPrefixLength(source: String, start: Int, end: Int): Int {
    fun skippingWhitespace(from: Int): Int {
        var index = from
        while (index < end && source[index].isWhitespace() && source[index] != '\n') index++
        return index - start
    }

    
    var hashes = 0
    while (start + hashes < end && hashes < 6 && source[start + hashes] == '#') hashes++
    if (hashes >= 1 && start + hashes < end && source[start + hashes].isWhitespace()) {
        return skippingWhitespace(start + hashes)
    }

    
    if (source[start] == '>' && start + 1 < end && source[start + 1].isWhitespace()) {
        return skippingWhitespace(start + 1)
    }

    
    val first = source[start]
    if ((first == '-' || first == '*' || first == '+') &&
        start + 1 < end && source[start + 1].isWhitespace()
    ) {
        return skippingWhitespace(start + 2)
    }

    
    var digits = 0
    while (start + digits < end && source[start + digits].isDigit()) digits++
    if (digits > 0 && start + digits + 1 < end &&
        source[start + digits] == '.' && source[start + digits + 1].isWhitespace()
    ) {
        return skippingWhitespace(start + digits + 2)
    }

    return 0
}


private data class LinkSpan(val textStart: Int, val textEnd: Int, val spanEnd: Int)

private fun linkSpan(source: String, openBracket: Int, end: Int): LinkSpan? {
    var index = openBracket + 1
    while (index < end && source[index] != ']') {
        if (source[index] == '\n') return null
        index++
    }
    if (index >= end) return null
    val textStart = openBracket + 1
    val textEnd = index
    if (index + 1 >= end || source[index + 1] != '(') return null
    var closing = index + 2
    while (closing < end && source[closing] != ')') {
        if (source[closing] == '\n') return null
        closing++
    }
    if (closing >= end) return null
    return LinkSpan(textStart, textEnd, closing + 1)
}
