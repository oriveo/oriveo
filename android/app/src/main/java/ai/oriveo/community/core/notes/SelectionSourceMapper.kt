package ai.oriveo.community.core.notes


object SelectionSourceMapper {
    private const val MIN_SIG_LENGTH = 8

    private data class SourceBlock(val raw: String, val sig: String)
    private data class TableParts(val header: String, val separator: String, val bodyRows: List<String>)

    
    fun extractSelectionMarkdown(sourceMarkdown: String, renderedSelection: String): String? {
        val selSig = contentSignature(renderedSelection)
        if (selSig.length < MIN_SIG_LENGTH) return null

        val blocks = splitSourceBlocks(sourceMarkdown)
        if (blocks.isEmpty()) return null

        val matched = locateCovered(blocks.mapIndexed { i, b -> b.sig to i }, selSig) ?: return null

        
        if (matched.first == matched.second) {
            refineSingleBlock(blocks[matched.first].raw, selSig)?.let { return it }
        }

        
        val extracted = blocks.subList(matched.first, matched.second + 1)
            .joinToString("\n\n") { it.raw }
            .trim()
        if (extracted.isEmpty() || !hasStructure(extracted)) return null
        return extracted
    }

    
    private fun contentSignature(text: String): String {
        val sb = StringBuilder(text.length)
        for (ch in text.lowercase()) {
            if (ch.isLetterOrDigit()) sb.append(ch)
        }
        return sb.toString()
    }

    
    private fun splitSourceBlocks(md: String): List<SourceBlock> {
        val blocks = mutableListOf<SourceBlock>()
        val cur = mutableListOf<String>()
        var hasCur = false
        var inFence = false
        var fenceMarker = ""

        fun flush() {
            if (!hasCur) return
            val raw = cur.joinToString("\n")
            if (raw.trim().isNotEmpty()) blocks.add(SourceBlock(raw, contentSignature(raw)))
            cur.clear()
            hasCur = false
        }

        for (line in md.split("\n")) {
            val fence = leadingFence(line)
            if (inFence) {
                cur.add(line); hasCur = true
                if (fence != null && line.trim().startsWith(fenceMarker)) inFence = false
                continue
            }
            if (fence != null) {
                cur.add(line); hasCur = true
                inFence = true
                fenceMarker = fence
                continue
            }
            if (line.trim().isEmpty()) { flush(); continue }
            cur.add(line); hasCur = true
        }
        flush()
        return blocks
    }

    private fun leadingFence(line: String): String? {
        val t = line.trimStart(' ', '\t')
        return when {
            t.startsWith("```") -> "```"
            t.startsWith("~~~") -> "~~~"
            else -> null
        }
    }

    
    private fun hasStructure(md: String): Boolean {
        val patterns = listOf(
            Regex("(^|\\n)[^\\n]*\\|[^\\n]*\\|"),
            Regex("(^|\\n)\\s*(```|~~~)"),
            Regex("(^|\\n)\\s*([-*+]|\\d+\\.)\\s+"),
            Regex("(^|\\n)\\s*#{1,6}\\s+"),
            Regex("\\$\\$[\\s\\S]+?\\$\\$"),
            Regex("(^|[^$])\\$[^$\\n]+?\\$(?!\\$)"),
        )
        return patterns.any { it.containsMatchIn(md) }
    }

    private fun isSeparatorRow(line: String): Boolean {
        val t = line.trim()
        return t.contains("|") && t.contains("-") && Regex("^\\|?[\\s:|-]+\\|?$").matches(t)
    }

    
    private fun findTableParts(blockRaw: String): TableParts? {
        val lines = blockRaw.split("\n").filter { it.trim().isNotEmpty() }
        var i = 1
        while (i < lines.size) {
            if (isSeparatorRow(lines[i]) && lines[i - 1].contains("|")) {
                val header = lines[i - 1]
                val bodyRows = mutableListOf<String>()
                var j = i + 1
                while (j < lines.size && lines[j].contains("|")) { bodyRows.add(lines[j]); j++ }
                return if (bodyRows.isEmpty()) null else TableParts(header, lines[i], bodyRows)
            }
            i++
        }
        return null
    }

    
    private fun locateCovered(units: List<Pair<String, Int>>, selSig: String): Pair<Int, Int>? {
        val concat = StringBuilder()
        val owner = mutableListOf<Int>()
        for ((sig, own) in units) {
            for (ch in sig) { concat.append(ch); owner.add(own) }
        }
        val idx = concat.indexOf(selSig)
        if (idx < 0) return null
        var mn = Int.MAX_VALUE
        var mx = -1
        for (k in idx until (idx + selSig.length)) {
            if (owner[k] >= 0) {
                mn = minOf(mn, owner[k])
                mx = maxOf(mx, owner[k])
            }
        }
        return if (mx >= 0) mn to mx else null
    }

    
    private fun extractTableRowSelection(blockRaw: String, selSig: String): String? {
        val parts = findTableParts(blockRaw) ?: return null
        val units = mutableListOf(contentSignature(parts.header) to -1)
        parts.bodyRows.forEachIndexed { idx, row -> units.add(contentSignature(row) to idx) }
        val covered = locateCovered(units, selSig) ?: return null
        val selectedRows = parts.bodyRows.subList(covered.first, covered.second + 1)
        return (listOf(parts.header, parts.separator) + selectedRows).joinToString("\n")
    }

    
    private fun extractLineSelection(blockRaw: String, selSig: String): String? {
        val lines = blockRaw.split("\n")
        val covered = locateCovered(lines.mapIndexed { i, l -> contentSignature(l) to i }, selSig) ?: return null
        val selected = lines.subList(covered.first, covered.second + 1).joinToString("\n").trim()
        return if (selected.isNotEmpty() && hasStructure(selected)) selected else null
    }

    
    private fun refineSingleBlock(blockRaw: String, selSig: String): String? {
        if (Regex("(?m)^\\s*(```|~~~)").containsMatchIn(blockRaw)) {
            
            return blockRaw.trim()
        }
        return extractTableRowSelection(blockRaw, selSig) ?: extractLineSelection(blockRaw, selSig)
    }
}
