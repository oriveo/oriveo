package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.extractors.OoxmlRelationships.targetOf
import java.time.LocalDate

/** XLSX extraction, attachment extraction spec section 6. */
internal object XlsxTextExtractor {
    private const val ROWS_PER_DEADLINE_CHECK = 1000
    private const val SECONDS_PER_DAY = 86_400L

    private val dateOnlyFormats = (14..17) + (27..31) + (34..36) + (50..54) + listOf(57, 58)
    private val timeOnlyFormats = (18..21) + listOf(32, 33) + (45..47) + listOf(55, 56)
    private const val DATE_TIME_FORMAT = 22

    private val numberPattern = Regex("""^-?\d+(\.\d+)?([eE][+-]?\d+)?$""")
    private val hexEscape = Regex("_x([0-9A-Fa-f]{4})_")
    private val quoted = Regex("\"[^\"]*\"")
    private val escaped = Regex("""[\\_*].""")
    private val bracketed = Regex("""\[([^\]]*)]""")
    private val keptBrackets = setOf("h", "hh", "m", "mm", "s", "ss")

    private enum class DateKind { Date, Time, DateTime }

    fun extract(zip: ZipPackage, deadline: ExtractionDeadline): String {
        val workbookPath = OoxmlRelationships.mainPart(zip, "xl/workbook.xml")
        val workbookBytes = zip.read(workbookPath) ?: throw ExtractionException(ExtractionErrorCode.CorruptedFile)
        val workbook = XmlParts.tree(workbookBytes)
        val rels = OoxmlRelationships.read(zip, workbookPath)
        fun part(suffix: String, fallback: String): ByteArray? =
            rels.targetOf(suffix)?.let { zip.read(it) } ?: zip.read(fallback)

        val date1904 = workbook.child("x:workbookPr")?.attr("date1904")?.let { it == "1" || it.equals("true", true) } == true
        val sharedStrings = part("/sharedStrings", "xl/sharedStrings.xml")?.let(::parseSharedStrings).orEmpty()
        val styles = part("/styles", "xl/styles.xml")?.let { parseStyles(XmlParts.tree(it)) } ?: emptyList()

        val out = BlockText()
        val sheets = workbook.child("x:sheets")?.children("x:sheet").orEmpty()
        for (sheet in sheets) {
            deadline.check()
            val state = sheet.attr("state")
            if (state == "veryHidden") continue
            val rel = rels.firstOrNull { it.id == sheet.attr("r:id") } ?: continue
            if (!rel.type.endsWith("/worksheet")) continue
            val hidden = if (state == "hidden") " (hidden)" else ""
            out.section("## Sheet: ${sheet.attr("name").orEmpty()}$hidden")
            val bytes = zip.read(rel.target) ?: continue
            val grid = readSheet(bytes, sharedStrings, styles, date1904, deadline)
            grid.render(out)
        }
        return out.render()
    }

    // region shared strings and styles

    private fun parseSharedStrings(bytes: ByteArray): List<String> {
        val strings = ArrayList<String>()
        XmlParts.stream(
            bytes,
            capture = { name, ancestors -> name == "x:si" && ancestors.size == 1 },
            onCaptured = { node, _ -> strings += richText(node) },
        )
        return strings
    }

    /** `<si>` / `<is>`: concatenate all `t` descendants in order, skip `rPh` and `phoneticPr`, then decode `_xHHHH_`. */
    private fun richText(node: XNode): String {
        val sb = StringBuilder()
        fun visit(element: XNode) {
            for (child in element.elements()) {
                when (child.name) {
                    "x:rPh", "x:phoneticPr" -> Unit
                    "x:t" -> sb.append(child.text())
                    else -> visit(child)
                }
            }
        }
        visit(node)
        return decodeHexEscapes(sb.toString())
    }

    /** Decode `_xHHHH_` left to right; decoded characters no longer take part in matching. */
    internal fun decodeHexEscapes(text: String): String =
        if ("_x" !in text) text else hexEscape.replace(text) { it.groupValues[1].toInt(16).toChar().toString() }

    private class Styles(val cellFormats: List<Int?>, val customFormats: Map<Int, String>)

    private fun parseStyles(root: XNode): List<DateKind?> {
        val custom = root.child("x:numFmts")?.children("x:numFmt").orEmpty().mapNotNull { fmt ->
            val id = fmt.attr("numFmtId")?.toIntOrNull() ?: return@mapNotNull null
            id to fmt.attr("formatCode").orEmpty()
        }.toMap()
        val styles = Styles(
            root.child("x:cellXfs")?.children("x:xf").orEmpty().map { it.attr("numFmtId")?.toIntOrNull() },
            custom,
        )
        return styles.cellFormats.map { id -> id?.let { dateKind(it, styles.customFormats) } }
    }

    private fun dateKind(numFmtId: Int, custom: Map<Int, String>): DateKind? {
        when (numFmtId) {
            in dateOnlyFormats -> return DateKind.Date
            in timeOnlyFormats -> return DateKind.Time
            DATE_TIME_FORMAT -> return DateKind.DateTime
        }
        val code = custom[numFmtId] ?: return null
        return customDateKind(code)
    }

    private fun customDateKind(code: String): DateKind? {
        var section = code.substringBefore(';')
        section = quoted.replace(section, "")
        section = escaped.replace(section, "")
        section = bracketed.replace(section) { match ->
            val inner = match.groupValues[1]
            if (inner.lowercase() in keptBrackets) inner else ""
        }
        val lower = section.lowercase()
        val hasDate = lower.any { it == 'y' || it == 'd' || it == '年' || it == '月' || it == '日' }
        val hasTime = lower.any { it == 'h' || it == 's' || it == '时' || it == '時' || it == '分' || it == '秒' }
        return when {
            hasDate && hasTime -> DateKind.DateTime
            hasDate -> DateKind.Date
            hasTime -> DateKind.Time
            'm' in lower -> DateKind.Date
            else -> null
        }
    }

    // endregion

    // region worksheets

    private fun readSheet(
        bytes: ByteArray,
        sharedStrings: List<String>,
        dateKinds: List<DateKind?>,
        date1904: Boolean,
        deadline: ExtractionDeadline,
    ): SheetGrid {
        val grid = SheetGrid()
        var rowNumber = 0
        var rowsSeen = 0
        XmlParts.stream(
            bytes,
            capture = { name, ancestors -> name == "x:row" && ancestors.lastOrNull() == "x:sheetData" },
            onCaptured = { row, _ ->
                if (rowsSeen++ % ROWS_PER_DEADLINE_CHECK == 0) deadline.check()
                rowNumber = row.attr("r")?.toIntOrNull() ?: (rowNumber + 1)
                var column = 0
                for (cell in row.children("x:c")) {
                    column = cell.attr("r")?.let(::columnOf) ?: (column + 1)
                    val value = cellValue(cell, sharedStrings, dateKinds, date1904)
                    if (value.isNotEmpty()) grid.put(rowNumber, column, value)
                }
            },
        )
        return grid
    }

    /** The letter part of `C5` is computed as a base-26 column number (A = 1); returns null if there are no letters. */
    private fun columnOf(ref: String): Int? {
        var column = 0
        for (c in ref) {
            val upper = c.uppercaseChar()
            if (upper !in 'A'..'Z') break
            column = column * 26 + (upper - 'A' + 1)
        }
        return column.takeIf { it > 0 }
    }

    private fun cellValue(cell: XNode, sharedStrings: List<String>, dateKinds: List<DateKind?>, date1904: Boolean): String {
        val type = cell.attr("t")
        if (type == "inlineStr") return cell.child("x:is")?.let(::richText).orEmpty()
        val v = cell.child("x:v")?.text() ?: return ""
        return when (type) {
            "s" -> v.trim().toIntOrNull()?.let { sharedStrings.getOrNull(it) }.orEmpty()
            "str", "e", "d" -> v
            "b" -> if (v.trim() == "1") "TRUE" else "FALSE"
            else -> {
                val kind = cell.attr("s")?.toIntOrNull()?.let { dateKinds.getOrNull(it) }
                kind?.let { formatDate(v, it, date1904) } ?: normalizeNumber(v)
            }
        }
    }

    private fun formatDate(raw: String, kind: DateKind, date1904: Boolean): String? {
        val serial = raw.trim().toDoubleOrNull() ?: return null
        if (serial.isNaN() || serial.isInfinite() || serial < 0) return null
        var days = Math.floor(serial).toLong()
        var seconds = Math.round((serial - days) * SECONDS_PER_DAY)
        if (seconds == SECONDS_PER_DAY) {
            days += 1
            seconds = 0
        }
        val date = when {
            date1904 -> LocalDate.of(1904, 1, 1).plusDays(days).toString()
            days == 60L -> "1900-02-29"
            days < 60L -> LocalDate.of(1899, 12, 31).plusDays(days).toString()
            else -> LocalDate.of(1899, 12, 30).plusDays(days).toString()
        }
        val time = "%02d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60)
        return when (kind) {
            DateKind.Date -> date
            DateKind.Time -> time
            DateKind.DateTime -> "$date $time"
        }
    }

    /** Number normalization: pure string arithmetic; with more than 15 significant digits, round half away from zero in decimal to 15 digits. */
    internal fun normalizeNumber(raw: String): String {
        if (!numberPattern.matches(raw)) return raw
        val negative = raw.startsWith("-")
        val unsigned = raw.removePrefix("-")
        val exponentAt = unsigned.indexOfFirst { it == 'e' || it == 'E' }
        val mantissa = if (exponentAt >= 0) unsigned.substring(0, exponentAt) else unsigned
        val exponent = if (exponentAt >= 0) unsigned.substring(exponentAt) else ""
        val integer = mantissa.substringBefore('.')
        val fraction = mantissa.substringAfter('.', "")
        val digits = StringBuilder(integer + fraction)
        val lead = digits.indexOfFirst { it != '0' }
        if (lead < 0 || digits.length - lead <= 15) return raw

        var pointAt = integer.length
        val keepEnd = lead + 15
        val roundUp = digits[keepEnd] >= '5'
        for (index in keepEnd until digits.length) digits[index] = '0'
        if (roundUp) {
            var index = keepEnd - 1
            while (index >= 0) {
                if (digits[index] == '9') {
                    digits[index] = '0'
                    index--
                } else {
                    digits[index] = digits[index] + 1
                    break
                }
            }
            if (index < 0) {
                digits.insert(0, '1')
                pointAt++
            }
        }
        val integerPart = digits.substring(0, pointAt)
        val fractionPart = digits.substring(pointAt).trimEnd('0')
        val body = if (fractionPart.isEmpty()) integerPart else "$integerPart.$fractionPart"
        return (if (negative) "-" else "") + body + exponent
    }

    /** Non-empty cells; the used range and consecutive blank rows are collapsed to one row, and beyond 50 columns a note is given by the full width (section 6 / section 3.3). */
    private class SheetGrid {
        private val rows = java.util.TreeMap<Int, java.util.TreeMap<Int, String>>()
        private var minColumn = Int.MAX_VALUE
        private var maxColumn = 0

        fun put(row: Int, column: Int, value: String) {
            rows.getOrPut(row) { java.util.TreeMap() }[column] = value
            minColumn = minOf(minColumn, column)
            maxColumn = maxOf(maxColumn, column)
        }

        fun render(out: BlockText) {
            if (rows.isEmpty()) return
            val width = maxColumn - minColumn + 1
            val kept = minOf(width, StructuredText.MAX_TABLE_COLUMNS)
            val table = ArrayList<List<String>>()
            var previous: Int? = null
            for ((rowNumber, cells) in rows) {
                if (previous != null && rowNumber > previous + 1) table += List(kept) { "" }
                table += List(kept) { offset -> cells[minColumn + offset]?.let(::cell).orEmpty() }
                previous = rowNumber
            }
            out.table(table, width)
        }

        private fun cell(value: String): String = StructuredText.cellText(listOf(value.trim()))
    }

    // endregion
}
