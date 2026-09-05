package ai.oriveo.community.ui.component.markdown


object StreamingSplitter {

    
    enum class TailKind {
        
        Paragraph,

        
        UnclosedCodeFence,

        
        UnclosedMathBlock,

        
        UnclosedTable,
    }

    data class SplitResult(
        val committed: String,
        val tail: String,
        val tailKind: TailKind = TailKind.Paragraph,
    )

    
    fun split(text: String, maxEnd: Int = Int.MAX_VALUE): SplitResult {
        
        if (text.length < 80 && !text.contains("\n\n") && !text.endsWith("```\n")) {
            return SplitResult("", text, classifyTail(text))
        }

        val lastSafe = findLastSafeSplit(text, maxEnd)
        return if (lastSafe > 0) {
            val tail = text.substring(lastSafe)
            SplitResult(
                committed = text.substring(0, lastSafe),
                tail = tail,
                tailKind = classifyTail(tail),
            )
        } else {
            SplitResult("", text, classifyTail(text))
        }
    }

    
    private fun findLastSafeSplit(text: String, maxEnd: Int = Int.MAX_VALUE): Int {
        var inCodeBlock = false
        var inMathBlock = false
        var inTable = false
        var lastSafeIdx = -1
        var i = 0
        var lineStart = 0
        
        fun acceptSafe(idx: Int) {
            if (idx <= maxEnd) lastSafeIdx = idx
        }

        while (i < text.length) {
            
            if (i == lineStart && text.startsWith("```", i)) {
                if (inCodeBlock) {
                    
                    val lineEnd = text.indexOf('\n', i)
                    val end = if (lineEnd < 0) text.length else lineEnd + 1
                    inCodeBlock = false
                    i = end
                    lineStart = i
                    if (!inMathBlock && !inTable) acceptSafe(i)
                    continue
                } else {
                    inCodeBlock = true
                    val lineEnd = text.indexOf('\n', i)
                    i = if (lineEnd < 0) text.length else lineEnd + 1
                    lineStart = i
                    continue
                }
            }

            
            if (inCodeBlock) {
                if (text[i] == '\n') lineStart = i + 1
                i++
                continue
            }

            
            
            
            if (!inMathBlock && i == lineStart && text.startsWith("$$", i)) {
                inMathBlock = true
                i += 2
                continue
            }
            if (inMathBlock) {
                if (text.startsWith("$$", i)) {
                    inMathBlock = false
                    i += 2
                    if (!inTable) {
                        val lineEnd = text.indexOf('\n', i)
                        val end = if (lineEnd < 0) text.length else lineEnd + 1
                        acceptSafe(end)
                    }
                    continue
                }
                if (text[i] == '\n') lineStart = i + 1
                i++
                continue
            }

            
            if (i == lineStart) {
                val nextNl = text.indexOf('\n', i).let { if (it < 0) text.length else it }
                val line = text.substring(i, nextNl)
                val isTableLine = line.startsWith("|") && line.indexOf('|', 1) > 0
                if (isTableLine) {
                    inTable = true
                    i = if (nextNl < text.length) nextNl + 1 else text.length
                    lineStart = i
                    continue
                } else if (inTable) {
                    
                    inTable = false
                    acceptSafe(i)
                }
            }

            
            if (!inTable && text.startsWith("\n\n", i)) {
                acceptSafe(i + 2)
                i += 2
                lineStart = i
                continue
            }

            
            if (!inTable && i == lineStart && isHeadingLineStart(text, i)) {
                if (lineStart > 0) {
                    acceptSafe(lineStart)
                }
            }

            if (text[i] == '\n') lineStart = i + 1
            i++
        }

        return lastSafeIdx
    }

    private fun isHeadingLineStart(text: String, idx: Int): Boolean {
        var p = idx
        var hashCount = 0
        while (p < text.length && p < idx + 7 && text[p] == '#') {
            hashCount++
            p++
        }
        return hashCount in 1..6 && p < text.length && text[p] == ' '
    }

    private fun classifyTail(tail: String): TailKind {
        if (hasOpenCodeFence(tail)) return TailKind.UnclosedCodeFence
        if (hasOpenMathBlock(tail)) return TailKind.UnclosedMathBlock
        if (looksLikePartialTable(tail)) return TailKind.UnclosedTable
        return TailKind.Paragraph
    }

    
    fun hasOpenCodeFence(text: String): Boolean {
        var count = 0
        var i = 0
        var lineStart = 0
        while (i < text.length) {
            if (i == lineStart && text.startsWith("```", i)) {
                count++
                i += 3
                continue
            }
            if (text[i] == '\n') lineStart = i + 1
            i++
        }
        return count % 2 != 0
    }

    
    fun hasOpenMathBlock(text: String): Boolean {
        var count = 0
        var i = 0
        while (i < text.length - 1) {
            if (text.startsWith("$$", i)) {
                count++
                i += 2
            } else {
                i++
            }
        }
        return count % 2 != 0
    }

    
    private fun looksLikePartialTable(text: String): Boolean {
        val lines = text.split('\n')
        var tableLineCount = 0
        var hasSeparator = false
        var dataLinesAfterSeparator = 0
        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.startsWith("|") && trimmed.indexOf('|', 1) > 0) {
                tableLineCount++
                
                val isSeparator = trimmed.removePrefix("|").removeSuffix("|")
                    .split("|").all { col ->
                        val c = col.trim()
                        c.isNotEmpty() && c.all { it == '-' || it == ':' }
                    }
                if (isSeparator) {
                    hasSeparator = true
                } else if (hasSeparator) {
                    dataLinesAfterSeparator++
                }
            }
        }
        if (tableLineCount == 0) return false
        
        return !hasSeparator || dataLinesAfterSeparator == 0
    }

    
    data class TrailingTable(
        
        val beforeTable: String,
        
        val tableText: String,
    )

    
    fun splitTrailingTable(tail: String): TrailingTable? {
        val lines = tail.split('\n')
        var sepIdx = -1
        for (idx in 1 until lines.size) {
            if (isSeparatorRow(lines[idx]) && isPipeRow(lines[idx - 1])) {
                sepIdx = idx
                break
            }
        }
        if (sepIdx < 0) return null
        
        
        
        for (idx in (sepIdx + 1) until lines.size) {
            val trimmed = lines[idx].trim()
            if (trimmed.isEmpty()) {
                if (idx < lines.size - 1) return null
            } else if (!trimmed.contains("|")) {
                return null
            }
        }
        val headerIdx = sepIdx - 1
        return TrailingTable(
            beforeTable = lines.subList(0, headerIdx).joinToString("\n"),
            tableText = lines.subList(headerIdx, lines.size).joinToString("\n"),
        )
    }

    
    private fun isPipeRow(line: String): Boolean {
        val trimmed = line.trim()
        return trimmed.startsWith("|") && trimmed.indexOf('|', 1) > 0
    }

    
    internal fun isSeparatorRow(line: String): Boolean {
        val trimmed = line.trim()
        if (!trimmed.startsWith("|")) return false
        return trimmed.removePrefix("|").removeSuffix("|")
            .split("|").all { col ->
                val c = col.trim()
                c.isNotEmpty() && c.all { it == '-' || it == ':' }
            }
    }

    
    fun extractLanguage(text: String): String {
        val fenceIdx = text.indexOf("```")
        if (fenceIdx < 0) return ""
        val afterFence = text.substring(fenceIdx + 3)
        val lineEnd = afterFence.indexOf('\n')
        return if (lineEnd >= 0) afterFence.substring(0, lineEnd).trim() else afterFence.trim()
    }

    
    fun extractCodeAfterFence(text: String): String {
        val fenceIdx = text.indexOf("```")
        if (fenceIdx < 0) return text
        val afterFence = text.substring(fenceIdx + 3)
        val lineEnd = afterFence.indexOf('\n')
        return if (lineEnd >= 0) afterFence.substring(lineEnd + 1) else ""
    }
}
