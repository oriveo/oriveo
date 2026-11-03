package ai.oriveo.community.core.studio

/**
 * Builds the composed image prompt (studio_prompt_compose.v1): user text, reference sentences,
 * style and effects sections, trimming effects then style to fit maxPromptChars.
 */
object StudioPromptComposer {
    data class Spec(
        val sectionSeparator: String,
        val inlineReference: String,
        val referenceTemplate: String,
        val baseTemplate: String,
        val styleTemplate: String,
        val effectsTemplate: String,
        val effectsJoiner: String,
        val roleWords: Map<String, String>,
    )

    /** Built-in studio_prompt_compose.v1 spec; tests pin it to the shared fixture spec. */
    val SPEC = Spec(
        sectionSeparator = "\n\n",
        inlineReference = "image {n}",
        referenceTemplate = "Image {n} is the {role} reference.",
        baseTemplate = "Image {n} is the image to edit.",
        styleTemplate = "Style: {fragment}.",
        effectsTemplate = "Effects: {fragments}.",
        effectsJoiner = "; ",
        roleWords = mapOf(
            "subject" to "subject",
            "style" to "style",
            "composition" to "composition",
            "person" to "character",
            "element" to "element",
        ),
    )

    data class Reference(val n: Int, val role: String)

    data class Input(
        val userPrompt: String,
        val references: List<Reference>,
        val styleFragment: String?,
        val effectFragments: List<String>,
        val maxPromptChars: Int,
    )

    enum class Field(val wire: String) { EFFECT("effect"), STYLE("style") }

    data class Adjustment(val field: Field, val dropped: String)

    enum class Error(val wire: String) { PROMPT_TOO_LONG("prompt_too_long") }

    data class Result(val composed: String?, val error: Error?, val adjustments: List<Adjustment>)

    // `@` followed by ASCII digits only; Unicode digits stay literal.
    private val mention = Regex("@([0-9]+)")

    // Only the first placeholder occurrence is filled; values go in verbatim (literal, no `$` patterns, no second pass).
    private fun fill(template: String, key: String, value: String): String = template.replaceFirst(key, value)

    private fun codePoints(text: String): Int = text.codePointCount(0, text.length)

    fun compose(spec: Spec, input: Input): Result {
        val adjustments = mutableListOf<Adjustment>()
        val user = mention.replace(input.userPrompt) { fill(spec.inlineReference, "{n}", it.groupValues[1]) }
        val refLines = input.references.map { ref ->
            if (ref.role == "base") {
                fill(spec.baseTemplate, "{n}", ref.n.toString())
            } else {
                fill(fill(spec.referenceTemplate, "{n}", ref.n.toString()), "{role}", spec.roleWords[ref.role] ?: ref.role)
            }
        }
        var style: String? = input.styleFragment?.takeIf { it.isNotEmpty() }
        val effects = input.effectFragments.toMutableList()
        fun build(): String {
            // An empty user text (exactly "", no trimming) adds no section.
            val sections = mutableListOf<String>()
            if (user.isNotEmpty()) sections += user
            if (refLines.isNotEmpty()) sections += refLines.joinToString(" ")
            style?.let { sections += fill(spec.styleTemplate, "{fragment}", it) }
            if (effects.isNotEmpty()) sections += fill(spec.effectsTemplate, "{fragments}", effects.joinToString(spec.effectsJoiner))
            return sections.joinToString(spec.sectionSeparator)
        }
        var composed = build()
        while (codePoints(composed) > input.maxPromptChars && effects.isNotEmpty()) {
            adjustments += Adjustment(Field.EFFECT, effects.removeAt(effects.lastIndex))
            composed = build()
        }
        val droppedStyle = style
        if (codePoints(composed) > input.maxPromptChars && droppedStyle != null) {
            adjustments += Adjustment(Field.STYLE, droppedStyle)
            style = null
            composed = build()
        }
        if (codePoints(composed) > input.maxPromptChars) return Result(composed = null, error = Error.PROMPT_TOO_LONG, adjustments = adjustments)
        return Result(composed = composed, error = null, adjustments = adjustments)
    }
}
