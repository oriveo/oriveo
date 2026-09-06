package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.ui.component.streaming.StreamingInlineSpanScanner

data class ReasoningBlockSplit(
    val blocks: List<String>,
    val tail: String,
)

private fun isFenceLine(line: String): Boolean {
    val trimmed = line.trim()
    return trimmed.startsWith("```") || trimmed.startsWith("~~~")
}

class ReasoningBlockSplitter {
    private val blocks = mutableListOf<String>()
    private var blockStart = 0
    private var scanned = 0
    private var lineStart = 0
    private var insideFence = false
    private var lastText = ""

    fun advance(text: String): ReasoningBlockSplit {

        if (!text.startsWith(lastText)) reset()
        lastText = text

        var cursor = scanned
        while (cursor < text.length) {
            val nl = text.indexOf('\n', cursor)
            if (nl < 0) break

            val line = text.substring(lineStart, nl)
            if (isFenceLine(line)) {
                insideFence = !insideFence
            } else if (!insideFence && line.isBlank()) {

                val block = text.substring(blockStart, nl + 1)
                if (block.isNotBlank()) blocks.add(block)
                blockStart = nl + 1
            }

            lineStart = nl + 1
            cursor = nl + 1
        }
        scanned = cursor

        return ReasoningBlockSplit(blocks.toList(), text.substring(blockStart))
    }

    fun reset() {
        blocks.clear()
        blockStart = 0
        scanned = 0
        lineStart = 0
        insideFence = false
        lastText = ""
    }
}

private const val AMBIGUITY_WINDOW = 4

private fun isBlockMarkerCandidate(c: Char): Boolean = c in "#>-*_$|`~+ \t"

fun reasoningSafePrefix(tail: String): String {
    if (tail.isEmpty()) return ""

    val lastNL = tail.lastIndexOf('\n')
    val completed = if (lastNL >= 0) tail.substring(0, lastNL + 1) else ""
    var headEnd = completed.length
    if (completed.isNotEmpty()) {
        var offset = 0
        var mathOpen = false
        var cut = -1

        for (line in completed.splitToSequence('\n')) {

            if (offset >= completed.length) break
            val trimmed = line.trim()
            val isRegionRisk = if (mathOpen) {
                if (trimmed.endsWith("$$")) mathOpen = false
                true
            } else if (trimmed.startsWith("$$") && !(trimmed.length >= 4 && trimmed.endsWith("$$"))) {
                mathOpen = true
                true
            } else {
                trimmed.contains("|")
            }
            if (isRegionRisk && cut < 0) cut = offset
            if (!isRegionRisk && !mathOpen) cut = -1
            offset += line.length + 1
        }
        if (cut >= 0) headEnd = cut
    }
    if (headEnd < completed.length) return tail.substring(0, headEnd)

    val lastLine = if (lastNL >= 0) tail.substring(lastNL + 1) else tail
    if (lastLine.isEmpty()) return completed
    val trimmed = lastLine.trim()
    if (trimmed.isEmpty()) return completed
    if (trimmed.length < AMBIGUITY_WINDOW && trimmed.all(::isBlockMarkerCandidate)) return completed
    val first = trimmed[0]
    if (trimmed.length >= 2 && (first == '-' || first == '*' || first == '_') &&
        trimmed.all { it == first }
    ) {
        return completed
    }
    if (trimmed.contains("|") || trimmed.startsWith("$$")) return completed

    val safe = StreamingInlineSpanScanner.safeBoundary(lastLine)
    return completed + lastLine.substring(0, safe.coerceIn(0, lastLine.length))
}
