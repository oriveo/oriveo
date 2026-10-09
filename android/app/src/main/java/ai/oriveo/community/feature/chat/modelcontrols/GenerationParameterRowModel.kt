package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterSource
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.SourcedGenerationParameter
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation.PresentationClass
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/**
 * One row of the advanced settings: the effective value, its source, the allowed range, validation errors, the reason it is dropped and what takes it over.
 *
 * The data comes from three production results only: the layered evaluation of `GenerationParameterSettingsStore.resolveWithSources`,
 * `GenerationParameterResolver.applyWithResult` and its `dropped`, plus the profile's own range /
 * conflictsWith. The row model never decides on its own whether an item will be sent, otherwise the panel and the request body drift apart sooner or later.
 * No copy is produced here: [titleKey] is only a title reference that the UI layer maps to `@StringRes`.
 */
internal data class GenerationParameterRowModel(
    val id: String,
    val titleKey: String,
    val display: DisplayValue,
    val source: Source,
    val range: GenerationParameterRange?,
    /** An out-of-range value is flagged on the spot together with the allowed range; the displayed value stays as the user wrote it and is not clamped. */
    val validationError: ValidationError?,
    val dropReason: GenerationParameterResolver.DropReason?,
    /** Which effective parameter takes this one over (the UI only strikes the row through and states the reason once at the end of the group). */
    val takenOverBy: String?,
    val isEditable: Boolean,
    /** A reasoning-group row whose profile has no write path: not editable, and the note says thinking is set under Model options > Thinking. */
    val reasoningSetInModelOptions: Boolean,
    /** Non-null only for a row that differs from the page-level tone. */
    val inlineVerification: Verification?,
    /** The presentation class of this row (the support's presentation class); it decides which label the inline marker uses. */
    val presentationClass: PresentationClass = PresentationClass.Silent,
) {
    enum class Source { Session, ModelDefault, ModelDecides }
    enum class Verification { Verified, Unverified }

    sealed interface DisplayValue {
        /** Display text of the effective value (a string is shown without JSON quotes). */
        data class Value(val text: String) : DisplayValue
        /** The user chose not to send this item. */
        data object Omitted : DisplayValue
        /** The fallback copy slot when there is no value: unlimited / model default / decided by the model. */
        data class Fallback(val kind: FallbackKind, val text: String? = null) : DisplayValue
    }

    /** RandomEachTime / PlainText are the specific wordings of "decided by the model" for the random seed and the output format; used only when no layer gives a value. */
    enum class FallbackKind { Unlimited, ModelDefaultValue, ModelDecides, RandomEachTime, PlainText }

    sealed interface ValidationError {
        data class OutOfRange(val range: GenerationParameterRange) : ValidationError
        data object Invalid : ValidationError
    }

    data class Chip(val id: String, val display: DisplayValue)
    data class Summary(val chips: List<Chip>, val moreCount: Int)

    data class Page(
        val rows: List<GenerationParameterRowModel>,
        val baseline: Verification,
        /** The class the page header speaks of when the baseline holds: the most common presentation class among unverified rows. */
        val baselineClass: PresentationClass? = null,
    )

    companion object {
        const val MAX_SUMMARY_CHIPS: Int = 2

        /** A placeholder word is not a value: drawing it would show a protocol word to the user verbatim. */
        private val PLACEHOLDER_DEFAULTS = setOf("provider_default", "unknown")

        /** At most two chips for set items; the rest fold into "N more". */
        fun summary(rows: List<GenerationParameterRowModel>): Summary {
            val set = rows.filter { it.source != Source.ModelDecides }
            return Summary(
                chips = set.take(MAX_SUMMARY_CHIPS).map { Chip(it.id, it.display) },
                moreCount = (set.size - MAX_SUMMARY_CHIPS).coerceAtLeast(0),
            )
        }

        /**
         * @param sourced The result of `resolveWithSources`.
         * @param dropped `applyWithResult(...).dropped`, optionally merged with the thinking-interplay preview.
         * @param editableIds The editable set given by the outbound gate; null means judge only by a non-empty wire.
         * @param isUnverified Whether this row counts as unverified. Production callers always pass
         *   `GenerationParameterPanelPresentation.showsUnverifiedBadge`, so both pages use one criterion;
         *   the default (no projection) treats every row as verified.
         */
        fun page(
            profile: GenerationProfileRef,
            sourced: Map<String, SourcedGenerationParameter>,
            dropped: List<GenerationParameterResolver.DroppedParameter> = emptyList(),
            editableIds: Set<String>? = null,
            isUnverified: (GenerationParameterRef) -> Boolean = { false },
        ): Page {
            val parameters = profile.parameters.filter { it.id != null }
            val verification: (GenerationParameterRef) -> Verification = {
                if (isUnverified(it)) Verification.Unverified else Verification.Verified
            }
            val baseline = baseline(parameters, verification)
            val baselineClass = baselineClass(parameters, verification).takeIf { baseline == Verification.Unverified }
            val droppedById = dropped.associate { it.parameterId to it.reason }
            val effective = parameters.mapNotNull { it.id }.filter { id ->
                sourced[id]?.override?.state == GenerationOverrideState.Value && id !in droppedById
            }
            val rows = parameters.map { parameter ->
                val id = parameter.id!!
                val hasWire = !profile.wire[id].isNullOrEmpty()
                val noWriterReasoning = GenerationParameterAvailability.isReasoningParameter(parameter) && !hasWire
                val value = sourced[id]
                GenerationParameterRowModel(
                    id = id,
                    titleKey = id,
                    display = display(parameter, value),
                    source = when (value?.source) {
                        GenerationParameterSource.Session -> Source.Session
                        GenerationParameterSource.ModelDefault -> Source.ModelDefault
                        null -> Source.ModelDecides
                    },
                    range = parameter.range,
                    validationError = value?.takeIf { it.override.state == GenerationOverrideState.Value }
                        ?.override?.value?.let { validation(it, parameter) },
                    dropReason = droppedById[id],
                    takenOverBy = effective.firstOrNull { other ->
                        other != id && conflicts(parameters, id, other)
                    },
                    isEditable = !noWriterReasoning && hasWire && (editableIds?.contains(id) ?: true),
                    reasoningSetInModelOptions = noWriterReasoning,
                    inlineVerification = inlineVerification(verification(parameter), parameter, baseline, baselineClass),
                    presentationClass = presentationClass(parameter),
                )
            }
            return Page(rows, baseline, baselineClass)
        }

        /**
         * Only a row that differs from the baseline is marked. When the baseline holds, a row that is just as unverified but whose presentation class differs from the one the page header speaks of
         * (for example "no data" among "effect unverified" rows) is still marked, otherwise the one-line header would say something wrong about it.
         */
        private fun inlineVerification(
            verification: Verification,
            parameter: GenerationParameterRef,
            baseline: Verification,
            baselineClass: PresentationClass?,
        ): Verification? {
            return when {
                verification != baseline -> verification
                verification == Verification.Unverified && presentationClass(parameter) != baselineClass -> verification
                else -> null
            }
        }

        /** The most common presentation class among unverified rows; a tie goes to the one declared first. */
        private fun baselineClass(
            parameters: List<GenerationParameterRef>,
            verification: (GenerationParameterRef) -> Verification,
        ): PresentationClass? =
            parameters.filter { verification(it) == Verification.Unverified }
                .groupingBy(::presentationClass).eachCount()
                .maxWithOrNull(compareBy<Map.Entry<PresentationClass, Int>> { it.value }.thenByDescending { it.key.ordinal })
                ?.key

        /** Whether "unverified" is the tone of the whole page: the verification state of most rows; a tie counts as verified. */
        fun baseline(
            parameters: List<GenerationParameterRef>,
            verification: (GenerationParameterRef) -> Verification,
        ): Verification {
            val unverified = parameters.count { verification(it) == Verification.Unverified }
            return if (unverified * 2 > parameters.size) Verification.Unverified else Verification.Verified
        }

        private fun presentationClass(parameter: GenerationParameterRef): PresentationClass =
            GenerationParameterSupportPresentation.entry(parameter.support).presentationClass

        private fun conflicts(parameters: List<GenerationParameterRef>, id: String, other: String): Boolean {
            val self = parameters.firstOrNull { it.id == id }
            val winner = parameters.firstOrNull { it.id == other }
            return self?.conflictsWith?.contains(other) == true || winner?.conflictsWith?.contains(id) == true
        }

        private fun validation(value: JsonElement, parameter: GenerationParameterRef): ValidationError? {
            if (GenerationParameterResolver.isValidGenerationValue(value, parameter)) return null
            val number = (value as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
            val range = parameter.range
            return if (number != null && range != null && number.isFinite()) {
                ValidationError.OutOfRange(range)
            } else {
                ValidationError.Invalid
            }
        }

        fun display(parameter: GenerationParameterRef, value: SourcedGenerationParameter?): DisplayValue {
            when (value?.override?.state) {
                GenerationOverrideState.Value -> value.override.value?.let { return DisplayValue.Value(text(it)) }
                GenerationOverrideState.Omit -> return DisplayValue.Omitted
                GenerationOverrideState.Inherit, null -> Unit
            }
            parameter.fixedValue?.takeUnless { it is JsonNull }?.let { return DisplayValue.Value(text(it)) }
            val default = parameter.defaultDescription?.takeUnless { it is JsonNull }
                ?: return modelDecides(parameter)
            val primitive = default as? JsonPrimitive
            if (primitive?.isString == true && primitive.content in PLACEHOLDER_DEFAULTS) {
                return modelDecides(parameter)
            }
            // The engine uses a sentinel outside the allowed range to mean unlimited (-1 for llama.cpp's max tokens).
            // It may only be shown as "unlimited": the number itself must not appear and is never sent (no value, nothing written).
            val number = primitive?.takeUnless { it.isString }?.doubleOrNull
            val min = parameter.range?.min
            if (parameter.id == "max_output_tokens" && number != null && min != null && number < min) {
                return DisplayValue.Fallback(FallbackKind.Unlimited)
            }
            return DisplayValue.Fallback(FallbackKind.ModelDefaultValue, text(default))
        }

        /** The allowed range written out for an out-of-range value ("0 - 2", ">= 1"); null when the range has no bound at all. */
        fun rangeText(range: GenerationParameterRange): String? {
            val lower = range.min?.let { "≥ ${advancedNumberText(it)}" } ?: range.minExclusive?.let { "> ${advancedNumberText(it)}" }
            val upper = range.max?.let { "≤ ${advancedNumberText(it)}" } ?: range.maxExclusive?.let { "< ${advancedNumberText(it)}" }
            return when {
                range.min != null && range.max != null -> "${advancedNumberText(range.min)} – ${advancedNumberText(range.max)}"
                lower != null && upper != null -> "$lower – $upper"
                else -> lower ?: upper
            }
        }

        /** "Decided by the model" has a more specific wording for the seed and the output format: no seed means random every time, no format means plain text. */
        private fun modelDecides(parameter: GenerationParameterRef): DisplayValue = DisplayValue.Fallback(
            when (parameter.id) {
                "seed" -> FallbackKind.RandomEachTime
                "json_schema", "response_format" -> FallbackKind.PlainText
                else -> FallbackKind.ModelDecides
            },
        )

        /** A string is shown without JSON quotes, a string array is listed item by item, anything else as raw JSON. */
        fun text(value: JsonElement): String = when {
            value is JsonPrimitive && value.isString -> value.content
            value is JsonPrimitive -> value.content
            value is JsonArray && value.all { (it as? JsonPrimitive)?.isString == true } ->
                value.joinToString(", ") { (it as JsonPrimitive).content }
            else -> value.toString()
        }
    }
}
