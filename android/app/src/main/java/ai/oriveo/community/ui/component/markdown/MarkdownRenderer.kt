package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.sp
import ai.oriveo.community.core.security.isSafeExternalUrl

/**
 * Renders Markdown into an [AnnotatedString].
 *
 * Covers the inline syntax: bold, italic, strikethrough, inline code, links and heading
 * styles. Code blocks and tables are split out by the layer above and rendered by their
 * own components.
 */
object MarkdownRenderer {

    private val plainColors = MarkdownColors(
        text = Color.Unspecified, textSecondary = Color.Unspecified, link = Color.Unspecified,
        inlineCodeText = Color.Unspecified, inlineCodeBg = Color.Unspecified,
        codeBlockBg = Color.Unspecified, codeBlockSurface = Color.Unspecified,
        codeBlockBorder = Color.Unspecified, codeBlockFg = Color.Unspecified,
        codeBlockSecondary = Color.Unspecified, syntaxKeyword = Color.Unspecified,
        syntaxString = Color.Unspecified, syntaxComment = Color.Unspecified,
        syntaxNumber = Color.Unspecified, syntaxType = Color.Unspecified,
        syntaxVariable = Color.Unspecified, quoteBorder = Color.Unspecified,
        quoteText = Color.Unspecified, tableBorder = Color.Unspecified,
        tableHeaderBg = Color.Unspecified, tableCellBg = Color.Unspecified,
        tableAltRowBg = Color.Unspecified,
    )

    /** The same inline parser used by production rendering, projected to copied plain text. */
    fun plainText(text: String): String = render(text, plainColors).text

    /**
     * Renders one run of Markdown text, with any code fence already removed.
     *
     * This is the single implementation used both while a message is streaming and once
     * it is complete, which is what makes the two states agree by construction. An
     * unclosed inline marker is always rendered literally; while streaming, the chunker's
     * safe boundary guarantees an unclosed span never reaches the screen in the first
     * place, so there is no need to style it optimistically and correct it later.
     *
     * @param text the Markdown source to render.
     * @param colors the palette to draw inline code and links with.
     * @return the styled text, with links carrying a [LinkAnnotation.Url].
     */
    fun render(
        text: String,
        colors: MarkdownColors,
    ): AnnotatedString = buildAnnotatedString {
        var i = 0
        val len = text.length

        while (i < len) {
            when {
                // Bold + Italic ***
                text.startsWith("***", i) -> {
                    val end = indexOfInLine(text, "***", i + 3)
                    if (end > i) {
                        pushStyle(SpanStyle(fontWeight = FontWeight.Bold, fontStyle = FontStyle.Italic))
                        append(text.substring(i + 3, end))
                        pop()
                        i = end + 3
                    } else {
                        append(text[i])
                        i++
                    }
                }

                // Bold **
                text.startsWith("**", i) -> {
                    val end = indexOfInLine(text, "**", i + 2)
                    if (end > i) {
                        pushStyle(SpanStyle(fontWeight = FontWeight.Bold))
                        append(text.substring(i + 2, end))
                        pop()
                        i = end + 2
                    } else {
                        append(text[i])
                        i++
                    }
                }

                // Italic *
                text.startsWith("*", i) && !text.startsWith("**", i) -> {
                    val end = indexOfInLine(text, "*", i + 1)
                    if (end > i && !text.startsWith("**", end)) {
                        pushStyle(SpanStyle(fontStyle = FontStyle.Italic))
                        append(text.substring(i + 1, end))
                        pop()
                        i = end + 1
                    } else {
                        append(text[i])
                        i++
                    }
                }

                // Strikethrough ~~
                text.startsWith("~~", i) -> {
                    val end = indexOfInLine(text, "~~", i + 2)
                    if (end > i) {
                        pushStyle(SpanStyle(textDecoration = TextDecoration.LineThrough))
                        append(text.substring(i + 2, end))
                        pop()
                        i = end + 2
                    } else {
                        append(text[i])
                        i++
                    }
                }

                // Inline code `
                text[i] == '`' && !text.startsWith("``", i) -> {
                    val end = indexOfInLine(text, "`", i + 1)
                    if (end > i) {
                        pushStyle(
                            SpanStyle(
                                fontFamily = FontFamily.Monospace,
                                fontSize = 14.sp,
                                color = colors.inlineCodeText,
                                background = colors.inlineCodeBg,
                            ),
                        )
                        append(" ${text.substring(i + 1, end)} ")
                        pop()
                        i = end + 1
                    } else {
                        append(text[i])
                        i++
                    }
                }

                // Link [text](url), emitted as a LinkAnnotation.Url so that Text handles
                // both the click and the link styling natively. The older approach paired
                // pushStringAnnotation("URL") with ClickableText, whose pointerInput was
                // keyed on the onClick lambda: every recomposition restarted gesture
                // detection and cancelled a tap that was already in progress.
                text[i] == '[' -> {
                    val closeBracket = indexOfInLine(text, "]", i + 1)
                    if (closeBracket > i && closeBracket + 1 < len && text[closeBracket + 1] == '(') {
                        val closeParen = indexOfInLine(text, ")", closeBracket + 2)
                        if (closeParen > closeBracket) {
                            val linkText = text.substring(i + 1, closeBracket)
                            val url = text.substring(closeBracket + 2, closeParen)
                            if (isSafeExternalUrl(url)) {
                                pushLink(
                                    LinkAnnotation.Url(
                                        url = url,
                                        styles = TextLinkStyles(
                                            style = SpanStyle(
                                                color = colors.link,
                                                textDecoration = TextDecoration.Underline,
                                            ),
                                        ),
                                    ),
                                )
                                append(linkText)
                                pop()
                            } else {
                                append(linkText)
                            }
                            i = closeParen + 1
                        } else {
                            append(text[i])
                            i++
                        }
                    } else {
                        append(text[i])
                        i++
                    }
                }

                else -> {
                    append(text[i])
                    i++
                }
            }
        }
    }

    /**
     * Line-scoped search for a closing marker: an inline span never spans lines, so a
     * marker left unclosed at end of line stays literal forever.
     *
     * Without this, `**a\nb**` would reach back once the second line arrived and rewrite
     * the literal `**a` already on screen into bold text, which breaks the rule that
     * content already displayed is only ever appended to, never rewritten.
     *
     * @return the index of [needle] at or after [from] while it is still on the same
     *   line, or -1 when a newline comes first.
     */
    private fun indexOfInLine(text: String, needle: String, from: Int): Int {
        val idx = text.indexOf(needle, from)
        if (idx < 0) return -1
        val nl = text.indexOf('\n', from)
        return if (nl in 0 until idx) -1 else idx
    }

    /**
     * Style for a heading of the given level.
     *
     * Body text sits at 17sp, so headings step up proportionally from there; h3 must not
     * end up smaller than body text.
     *
     * @param level the heading level, 1 through 6.
     * @return the span style for that level; levels below h3 render at body style.
     */
    fun headingStyle(level: Int): SpanStyle = when (level) {
        1 -> SpanStyle(fontWeight = FontWeight.Bold, fontSize = 23.sp)
        2 -> SpanStyle(fontWeight = FontWeight.SemiBold, fontSize = 19.sp)
        3 -> SpanStyle(fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        else -> SpanStyle()
    }
}

/**
 * Lightweight syntax highlighting.
 *
 * Recognises comments, keywords, strings, numbers and type names and colours them. It is
 * deliberately heuristic rather than a real parser: it has to run on every frame of a
 * streaming code block, across languages it has no grammar for.
 */
object SyntaxHighlighter {

    private val keywords = setOf(
        // JavaScript/TypeScript
        "const", "let", "var", "function", "return", "if", "else", "for", "while",
        "class", "import", "export", "from", "default", "new", "this", "async", "await",
        "try", "catch", "throw", "switch", "case", "break", "continue",
        // Python
        "def", "self", "print", "True", "False", "None", "with", "as", "yield", "lambda",
        // Kotlin/Java
        "fun", "val", "override", "private", "public", "internal", "protected",
        "data", "object", "companion", "sealed", "enum", "interface", "abstract",
        "suspend", "when", "is", "in", "null", "true", "false",
        // Swift
        "struct", "protocol", "extension", "guard", "some",
        // Common
        "static", "final", "void", "int", "string", "bool", "boolean",
    )

    private val types = setOf(
        "String", "Int", "Float", "Double", "Boolean", "List", "Map", "Set",
        "Array", "Any", "Unit", "Nothing", "Void", "Promise", "Observable",
        "Color", "View", "Modifier", "Composable", "State", "Flow",
    )

    fun highlight(code: String, language: String, colors: MarkdownColors): AnnotatedString =
        buildAnnotatedString {
            val lines = code.lines()
            val commentPrefix = commentPrefix(language)

            lines.forEachIndexed { lineIdx, line ->
                if (lineIdx > 0) append('\n')
                highlightLine(line, commentPrefix, colors)
            }
        }

    private fun AnnotatedString.Builder.highlightLine(
        line: String,
        commentPrefix: String,
        colors: MarkdownColors,
    ) {
        val trimmed = line.trimStart()

        // Full-line comment
        if (commentPrefix.isNotEmpty() && trimmed.startsWith(commentPrefix)) {
            pushStyle(SpanStyle(color = colors.syntaxComment))
            append(line)
            pop()
            return
        }

        // C-style line comment
        if (trimmed.startsWith("//")) {
            pushStyle(SpanStyle(color = colors.syntaxComment))
            append(line)
            pop()
            return
        }

        val inlineCommentStart = findLineCommentStart(line, commentPrefix)
        if (inlineCommentStart >= 0) {
            highlightCodeTokens(line.substring(0, inlineCommentStart), colors)
            pushStyle(SpanStyle(color = colors.syntaxComment))
            append(line.substring(inlineCommentStart))
            pop()
            return
        }

        highlightCodeTokens(line, colors)
    }

    private fun AnnotatedString.Builder.highlightCodeTokens(
        line: String,
        colors: MarkdownColors,
    ) {
        val tokens = tokenize(line)
        for (token in tokens) {
            when {
                token.startsWith("\"") || token.startsWith("'") || token.startsWith("`") -> {
                    pushStyle(SpanStyle(color = colors.syntaxString))
                    append(token)
                    pop()
                }
                token.toDoubleOrNull() != null -> {
                    pushStyle(SpanStyle(color = colors.syntaxNumber))
                    append(token)
                    pop()
                }
                token.isVariableToken() -> {
                    pushStyle(SpanStyle(color = colors.syntaxVariable))
                    append(token)
                    pop()
                }
                token in keywords -> {
                    pushStyle(SpanStyle(color = colors.syntaxKeyword))
                    append(token)
                    pop()
                }
                token in types -> {
                    pushStyle(SpanStyle(color = colors.syntaxType))
                    append(token)
                    pop()
                }
                token.isIdentifierToken() && !token.isTypeLikeIdentifier() -> {
                    pushStyle(SpanStyle(color = colors.syntaxVariable))
                    append(token)
                    pop()
                }
                else -> append(token)
            }
        }
    }

    private fun tokenize(line: String): List<String> {
        val tokens = mutableListOf<String>()
        var i = 0
        while (i < line.length) {
            val ch = line[i]
            when {
                // String literal
                ch == '"' || ch == '\'' || ch == '`' -> {
                    val end = findStringEnd(line, i, ch)
                    tokens.add(line.substring(i, end))
                    i = end
                }
                // Word
                ch.isLetterOrDigit() || ch == '_' -> {
                    val start = i
                    while (i < line.length && (line[i].isLetterOrDigit() || line[i] == '_' || line[i] == '.')) i++
                    tokens.add(line.substring(start, i))
                }
                // PHP / shell-style variable
                ch == '$' && i + 1 < line.length && (line[i + 1].isLetter() || line[i + 1] == '_') -> {
                    val start = i
                    i += 2
                    while (i < line.length && (line[i].isLetterOrDigit() || line[i] == '_')) i++
                    tokens.add(line.substring(start, i))
                }
                // Whitespace or operator
                else -> {
                    tokens.add(ch.toString())
                    i++
                }
            }
        }
        return tokens
    }

    private fun findStringEnd(line: String, start: Int, quote: Char): Int {
        var i = start + 1
        while (i < line.length) {
            if (line[i] == '\\') { i += 2; continue }
            if (line[i] == quote) return i + 1
            i++
        }
        return line.length
    }

    private fun findLineCommentStart(line: String, commentPrefix: String): Int {
        val prefix = when (commentPrefix) {
            "#" -> "#"
            "//" -> "//"
            else -> return -1
        }
        var quote: Char? = null
        var escaped = false
        var i = 0

        while (i < line.length) {
            val ch = line[i]
            val currentQuote = quote

            if (currentQuote != null) {
                when {
                    escaped -> escaped = false
                    ch == '\\' -> escaped = true
                    ch == currentQuote -> quote = null
                }
                i++
                continue
            }

            if (ch == '"' || ch == '\'' || ch == '`') {
                quote = ch
                i++
                continue
            }

            if (line.startsWith(prefix, i)) return i
            i++
        }

        return -1
    }

    private fun String.isVariableToken(): Boolean {
        if (length < 2 || this[0] != '$') return false
        val first = this[1]
        if (!first.isLetter() && first != '_') return false
        for (i in 2 until length) {
            val ch = this[i]
            if (!ch.isLetterOrDigit() && ch != '_') return false
        }
        return true
    }

    private fun String.isIdentifierToken(): Boolean {
        if (isEmpty()) return false
        val first = this[0]
        if (!first.isLetter() && first != '_') return false
        for (i in 1 until length) {
            val ch = this[i]
            if (!ch.isLetterOrDigit() && ch != '_' && ch != '.') return false
        }
        return true
    }

    private fun String.isTypeLikeIdentifier(): Boolean =
        firstOrNull()?.isUpperCase() == true

    private fun commentPrefix(language: String): String = when (language.lowercase()) {
        "python", "py", "ruby", "rb", "bash", "sh", "yaml", "yml", "toml" -> "#"
        "html", "xml" -> ""  // handled separately
        else -> "//"
    }
}
