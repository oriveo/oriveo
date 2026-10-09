package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterSource
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.SourcedGenerationParameter
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterResolver
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

    enum class FallbackKind { Unlimited, ModelDefaultValue, ModelDecides }

    sealed interface ValidationError {
        data class OutOfRange(val range: GenerationParameterRange) : ValidationError
        data object Invalid : ValidationError
    }

    data class Chip(val id: String, val display: DisplayValue)
    data class Summary(val chips: List<Chip>, val moreCount: Int)

    data class Page(val rows: List<GenerationParameterRowModel>, val baseline: Verification)

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
         */
        fun page(
            profile: GenerationProfileRef,
            sourced: Map<String, SourcedGenerationParameter>,
            dropped: List<GenerationParameterResolver.DroppedParameter> = emptyList(),
            editableIds: Set<String>? = null,
        ): Page {
            val parameters = profile.parameters.filter { it.id != null }
            val baseline = baseline(parameters)
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
                    inlineVerification = verification(parameter).takeIf { it != baseline },
                )
            }
            return Page(rows, baseline)
        }

        /** Whether "unverified" is the tone of the whole page: the verification state of most rows; a tie counts as verified. */
        fun baseline(parameters: List<GenerationParameterRef>): Verification {
            val unverified = parameters.count { verification(it) == Verification.Unverified }
            return if (unverified * 2 > parameters.size) Verification.Unverified else Verification.Verified
        }

        private fun verification(parameter: GenerationParameterRef): Verification =
            if (parameter.support == "accepted_unverified") Verification.Unverified else Verification.Verified

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
                ?: return DisplayValue.Fallback(FallbackKind.ModelDecides)
            val primitive = default as? JsonPrimitive
            if (primitive?.isString == true && primitive.content in PLACEHOLDER_DEFAULTS) {
                return DisplayValue.Fallback(FallbackKind.ModelDecides)
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
