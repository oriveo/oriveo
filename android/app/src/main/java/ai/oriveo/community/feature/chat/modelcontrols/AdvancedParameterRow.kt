package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.provider.GenerationParameterResolver.DropReason
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation.PresentationClass
import ai.oriveo.community.feature.chat.composer.ModelControlNote
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.DisplayValue
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.FallbackKind
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.Source
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.ValidationError
import ai.oriveo.community.feature.providers.detail.basicParameterAnnotationRes
import ai.oriveo.community.feature.providers.detail.generationParameterTitleRes
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/** Edit actions on a row. Validity is not judged here: an out-of-range value is stored as typed, the outbound gate does not send it and the row is flagged red. */
internal class AdvancedRowActions(
    val setValue: (JsonElement) -> Unit,
    val useModelDefault: () -> Unit,
    val omit: () -> Unit,
)

/**
 * One row of the advanced settings: collapsed (54dp) it shows only the title and the effective value; tapping expands the editor in place.
 * What is shown comes entirely from [GenerationParameterRowModel]; source, drop reason and baseline are not derived again here.
 */
@Composable
internal fun AdvancedParameterRow(
    row: GenerationParameterRowModel,
    parameter: GenerationParameterRef,
    expanded: Boolean,
    canEdit: Boolean,
    /** The raw JSON of the effective value; stop sequences are edited item by item and cannot be split back out of display text. */
    rawValue: JsonElement?,
    onToggle: () -> Unit,
    actions: AdvancedRowActions,
    /** The way out of a row that cannot be adjusted ("see models that support it"); null means none is attached. */
    supportedModelsActionRes: Int? = null,
    onShowSupportedModels: () -> Unit = {},
    /** The explanation under the title (strength items such as DRY / XTC, or a Mirostat subgroup left with a single member). */
    note: String? = null,
) {
    val colors = OriveoTheme.colors
    val title = stringResource(AdvancedSettingsLayout.rowTitleRes(row.id))
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 54.dp)
                .clickable(onClick = onToggle)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = title,
                    fontSize = 16.sp,
                    color = if (row.takenOverBy != null) colors.textSecondary else colors.textPrimary,
                    textDecoration = if (row.takenOverBy != null) TextDecoration.LineThrough else null,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                note?.let { Text(it, fontSize = 12.5.sp, color = colors.textSecondary) }
                row.inlineVerification
                    ?.takeIf { it == GenerationParameterRowModel.Verification.Unverified }
                    ?.let { inlineClassLabelRes(row.presentationClass) }
                    ?.let { Text(stringResource(it), fontSize = 12.5.sp, color = colors.warningText) }
            }
            Spacer(Modifier.width(8.dp))
            AdvancedValueLabel(row)
        }
        // The drop reason and the validation error are written on the row; a takeover only strikes the row through and the reason is stated once at the end of the group.
        val errorText = row.validationError?.let { validationMessage(it, row, parameter) }
        val dropText = row.dropReason?.takeIf { row.validationError == null }?.let { dropReasonText(it, parameter) }
        // An out-of-range value is flagged on the spot with the allowed range and is not clamped.
        val allowedRange = (row.validationError as? ValidationError.OutOfRange)
            ?.let { GenerationParameterRowModel.rangeText(it.range) }
            ?.let { stringResource(R.string.advanced_allowed_range, it) }
        (errorText ?: dropText)?.let { text ->
            Text(
                text = listOfNotNull(text, allowedRange).joinToString(" "),
                fontSize = 12.5.sp,
                color = if (errorText != null) colors.danger else colors.textSecondary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
            )
        }
        supportedModelsActionRes?.let { actionRes ->
            val actionLabel = stringResource(actionRes)
            TextButton(
                colors = modelControlTextButtonColors(),
                onClick = onShowSupportedModels,
                modifier = Modifier
                    .padding(start = 4.dp)
                    .semantics { contentDescription = "$actionLabel · $title" },
            ) { Text(actionLabel) }
        }
        if (expanded) {
            AdvancedRowEditor(row, parameter, canEdit, title, rawValue, actions)
        }
    }
}

@Composable
private fun AdvancedValueLabel(row: GenerationParameterRowModel) {
    val colors = OriveoTheme.colors
    val text = when (val display = row.display) {
        is DisplayValue.Value -> display.text
        DisplayValue.Omitted -> stringResource(R.string.generation_parameter_omitted_value)
        is DisplayValue.Fallback -> when (display.kind) {
            FallbackKind.Unlimited -> stringResource(R.string.advanced_no_limit)
            FallbackKind.ModelDefaultValue -> display.text.orEmpty()
            FallbackKind.ModelDecides -> stringResource(R.string.generation_parameter_default)
            FallbackKind.RandomEachTime -> stringResource(R.string.advanced_random_each_time)
            FallbackKind.PlainText -> stringResource(R.string.advanced_plain_text)
        }
    }
    val invalid = row.validationError != null
    when (row.source) {
        Source.Session -> Text(
            text = text,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = if (invalid) colors.danger else colors.primaryTextSafe,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .heightIn(min = 28.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(if (invalid) colors.dangerSoft else colors.primarySoft)
                .padding(horizontal = 12.dp, vertical = 5.dp),
        )
        Source.ModelDefault -> Row(
            modifier = Modifier
                .heightIn(min = 28.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(colors.textSecondary.copy(alpha = 0.12f))
                .padding(horizontal = 12.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, fontSize = 14.sp, color = if (invalid) colors.danger else colors.textPrimary, maxLines = 1)
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.advanced_your_default), fontSize = 11.5.sp, color = colors.textSecondary, maxLines = 1)
        }
        Source.ModelDecides -> Text(text, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1)
    }
}

@Composable
private fun AdvancedRowEditor(
    row: GenerationParameterRowModel,
    parameter: GenerationParameterRef,
    canEdit: Boolean,
    title: String,
    rawValue: JsonElement?,
    actions: AdvancedRowActions,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (row.reasoningSetInModelOptions) {
            ModelControlNote(R.string.advanced_reasoning_set_by_thinking)
            return@Column
        }
        val editable = canEdit && row.isEditable
        val current = (row.display as? DisplayValue.Value)?.text?.takeIf { row.source != Source.ModelDecides }
        when (parameter.valueSchema) {
            "enum" -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                parameter.enumValues.forEach { choice ->
                    val choiceText = GenerationParameterRowModel.text(choice)
                    FilterChip(
                        selected = current == choiceText,
                        enabled = editable,
                        onClick = { actions.setValue(choice) },
                        label = { Text(choiceText) },
                        modifier = Modifier
                            .semantics { contentDescription = "$title · $choiceText" },
                    )
                }
            }
            "boolean" -> Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                Switch(
                    checked = current == "true",
                    enabled = editable,
                    onCheckedChange = { actions.setValue(JsonPrimitive(it)) },
                    modifier = Modifier
                        .semantics { contentDescription = title },
                )
            }
            "string-list" -> AdvancedStopSequences(rawValue, editable, actions)
            "json-schema" -> AdvancedTextInput(
                initial = current.orEmpty(),
                editable = editable,
                title = title,
                singleLine = false,
                keyboardType = KeyboardType.Text,
                onCommit = { raw ->
                    if (raw.isBlank()) actions.useModelDefault()
                    else actions.setValue(runCatching { kotlinx.serialization.json.Json.parseToJsonElement(raw) }.getOrElse { JsonPrimitive(raw) })
                },
            )
            else -> {
                val numeric = parameter.valueSchema == "number" || parameter.valueSchema == "integer"
                AdvancedTextInput(
                    initial = current.orEmpty(),
                    editable = editable,
                    title = title,
                    singleLine = true,
                    keyboardType = if (numeric) KeyboardType.Decimal else KeyboardType.Text,
                    placeholder = placeholderText(row),
                    notNumberRes = when (parameter.valueSchema) {
                        "integer" -> R.string.advanced_error_integer
                        "number" -> R.string.advanced_error_number
                        else -> null
                    },
                    onCommit = { raw ->
                        when {
                            raw.isBlank() -> actions.useModelDefault()
                            !numeric -> actions.setValue(JsonPrimitive(raw))
                            // Not a number: do not store it yet. It would only be dropped by the outbound gate as an invalid value, so it stays in the field for the user to fix.
                            else -> raw.trim().toDoubleOrNull()?.let { actions.setValue(numberValue(it, parameter)) }
                        }
                    },
                )
                if (parameter.valueSchema == "number") {
                    AdvancedSlider(parameter, current?.toDoubleOrNull(), editable) { actions.setValue(numberValue(it, parameter)) }
                }
            }
        }
        basicParameterAnnotationRes(row.id)?.let { ModelControlNote(it) }
        if (parameter.id == "stop") ModelControlNote(R.string.advanced_stop_sequences_note)
        if (editable) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val defaultLabel = stringResource(R.string.advanced_use_model_default)
                val omitLabel = stringResource(R.string.advanced_dont_send)
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = actions.useModelDefault,
                    modifier = Modifier
                        .semantics { contentDescription = "$defaultLabel · $title" },
                ) { Text(defaultLabel) }
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = actions.omit,
                    modifier = Modifier
                        .semantics { contentDescription = "$omitLabel · $title" },
                ) { Text(omitLabel) }
            }
        }
    }
}

@Composable
private fun placeholderText(row: GenerationParameterRowModel): String =
    when (val display = row.display) {
        is DisplayValue.Fallback -> when (display.kind) {
            FallbackKind.Unlimited -> stringResource(R.string.advanced_no_limit)
            FallbackKind.ModelDefaultValue -> display.text.orEmpty()
            FallbackKind.ModelDecides -> stringResource(R.string.generation_parameter_default)
            FallbackKind.RandomEachTime -> stringResource(R.string.advanced_random_each_time)
            FallbackKind.PlainText -> stringResource(R.string.advanced_plain_text)
        }
        else -> ""
    }

/** A 38dp-high, right-aligned input; the cursor lands as soon as it expands. Every change is committed immediately, before blur or enter, as the earlier panel did. */
@Composable
private fun AdvancedTextInput(
    initial: String,
    editable: Boolean,
    title: String,
    singleLine: Boolean,
    keyboardType: KeyboardType,
    placeholder: String = "",
    /** Numeric input: a non-number is not stored and is flagged in place (it would only be dropped by the outbound gate as invalid). */
    @StringRes notNumberRes: Int? = null,
    onCommit: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    // Every change is saved at once and the page recomputes; the draft follows the outside value only when it really changed (back to default, reset),
    // otherwise a typed "0." would be overwritten by the recomputed "0.0" and the cursor would jump.
    var draft by remember { mutableStateOf(initial) }
    LaunchedEffect(initial) {
        if (normalizedInput(draft) != normalizedInput(initial)) draft = initial
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { if (editable) runCatching { focus.requestFocus() } }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 38.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(colors.surfaceInset)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        contentAlignment = Alignment.CenterEnd,
    ) {
        if (draft.isEmpty() && placeholder.isNotEmpty()) {
            Text(placeholder, fontSize = 14.sp, color = colors.textSecondary, textAlign = TextAlign.End, modifier = Modifier.fillMaxWidth())
        }
        BasicTextField(
            value = draft,
            enabled = editable,
            onValueChange = { raw ->
                draft = raw
                onCommit(raw)
            },
            singleLine = singleLine,
            minLines = if (singleLine) 1 else 5,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            textStyle = TextStyle(
                fontSize = 14.sp,
                color = colors.textPrimary,
                textAlign = if (singleLine) TextAlign.End else TextAlign.Start,
            ),
            cursorBrush = SolidColor(colors.primary),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focus)
                .semantics { contentDescription = title },
        )
    }
    if (notNumberRes != null && draft.isNotBlank() && draft.trim().toDoubleOrNull() == null) {
        Text(stringResource(notNumberRes), fontSize = 12.5.sp, color = colors.danger)
    }
}

private fun normalizedInput(raw: String): String = raw.trim().toDoubleOrNull()?.toString() ?: raw.trim()

/** Only a number with a finite lower and upper bound gets a slider; the "model default" tick sits at the default the profile declares. */
@Composable
private fun AdvancedSlider(
    parameter: GenerationParameterRef,
    current: Double?,
    editable: Boolean,
    onChange: (Double) -> Unit,
) {
    val range = parameter.range ?: return
    val min = range.min ?: range.minExclusive ?: return
    val max = range.max ?: range.maxExclusive ?: return
    if (!(max > min)) return
    val colors = OriveoTheme.colors
    val default = (parameter.defaultDescription as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
    Column {
        Slider(
            value = (current ?: default ?: min).coerceIn(min, max).toFloat(),
            onValueChange = { onChange(roundToStep(it.toDouble(), range)) },
            valueRange = min.toFloat()..max.toFloat(),
            enabled = editable,
            colors = SliderDefaults.colors(thumbColor = colors.primary, activeTrackColor = colors.primary),
        )
        if (default != null && default in min..max) {
            BoxWithConstraints(modifier = Modifier.fillMaxWidth().height(16.dp)) {
                val fraction = ((default - min) / (max - min)).toFloat()
                Text(
                    text = stringResource(R.string.advanced_model_defaults),
                    fontSize = 11.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    modifier = Modifier.offset(x = (maxWidth * fraction - 24.dp).coerceAtLeast(0.dp)),
                )
            }
        }
    }
}

@Composable
private fun AdvancedStopSequences(rawValue: JsonElement?, editable: Boolean, actions: AdvancedRowActions) {
    val colors = OriveoTheme.colors
    val entries = remember(rawValue) {
        (rawValue as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
    }
    var draft by remember { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        entries.forEachIndexed { index, entry ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(entry.replace("\n", "↵"), fontSize = 14.sp, color = colors.textPrimary, modifier = Modifier.weight(1f))
                if (editable) {
                    val label = stringResource(R.string.advanced_remove_item, entry)
                    TextButton(
                        colors = modelControlTextButtonColors(),
                        onClick = {
                            val next = entries.filterIndexed { i, _ -> i != index }
                            if (next.isEmpty()) actions.useModelDefault() else actions.setValue(JsonArray(next.map(::JsonPrimitive)))
                        },
                        modifier = Modifier
                            .semantics { contentDescription = label },
                    ) { Text(stringResource(R.string.delete)) }
                }
            }
        }
        if (editable) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.weight(1f)) {
                    AdvancedTextInput(
                        initial = draft,
                        editable = true,
                        title = stringResource(R.string.advanced_new_stop_sequence),
                        singleLine = true,
                        keyboardType = KeyboardType.Text,
                        placeholder = stringResource(R.string.advanced_new_stop_sequence),
                        onCommit = { draft = it },
                    )
                }
                TextButton(
                    colors = modelControlTextButtonColors(),
                    enabled = draft.isNotEmpty(),
                    onClick = {
                        actions.setValue(JsonArray((entries + draft).map(::JsonPrimitive)))
                        draft = ""
                    },
                ) { Text(stringResource(R.string.add)) }
            }
        }
    }
}

@StringRes
// "Unverified" is decided by the shared badge function; the presentation class only picks the sentence: no data is stated on its own, everything else says unverified.
private fun inlineClassLabelRes(presentationClass: PresentationClass): Int = when (presentationClass) {
    PresentationClass.NoData -> R.string.generation_parameter_class_no_data
    PresentationClass.Unverified, PresentationClass.Silent, PresentationClass.NotAdjustable ->
        R.string.generation_parameter_unverified_badge
}

private fun numberValue(value: Double, parameter: GenerationParameterRef): JsonPrimitive =
    if (parameter.valueSchema == "integer" && value == Math.floor(value) && !value.isInfinite()) {
        JsonPrimitive(value.toLong())
    } else {
        JsonPrimitive(value)
    }

private fun roundToStep(value: Double, range: GenerationParameterRange): Double {
    val step = range.step?.takeIf { it > 0 } ?: 0.01
    return Math.round(value / step) * step
}

/** A number without a redundant `.0`; the bounds in an out-of-range hint use this format. */
internal fun advancedNumberText(value: Double): String =
    if (value == Math.floor(value) && !value.isInfinite() && kotlin.math.abs(value) < 1e15) value.toLong().toString() else value.toString()

@Composable
private fun validationMessage(error: ValidationError, row: GenerationParameterRowModel, parameter: GenerationParameterRef): String {
    val value = (row.display as? DisplayValue.Value)?.text?.toDoubleOrNull()
    return when (error) {
        is ValidationError.OutOfRange -> {
            val range = error.range
            when {
                value != null && range.max != null && value > range.max ->
                    if (row.id == "max_output_tokens") stringResource(R.string.advanced_error_max_tokens, advancedNumberText(range.max))
                    else stringResource(R.string.advanced_error_highest, advancedNumberText(range.max))
                value != null && range.maxExclusive != null && value >= range.maxExclusive ->
                    stringResource(R.string.advanced_error_less_than, advancedNumberText(range.maxExclusive))
                value != null && range.min != null && value < range.min ->
                    stringResource(R.string.advanced_error_lowest, advancedNumberText(range.min))
                value != null && range.minExclusive != null && value <= range.minExclusive ->
                    stringResource(R.string.advanced_error_greater_than, advancedNumberText(range.minExclusive))
                else -> stringResource(R.string.advanced_error_value_rejected)
            }
        }
        ValidationError.Invalid -> when (parameter.valueSchema) {
            "integer" -> stringResource(R.string.advanced_error_integer)
            "number" -> stringResource(R.string.advanced_error_number)
            "json-schema" -> stringResource(R.string.advanced_error_json_schema)
            else -> stringResource(R.string.advanced_error_value_rejected)
        }
    }
}

@Composable
private fun dropReasonText(reason: DropReason, parameter: GenerationParameterRef): String = when (reason) {
    DropReason.ThinkingIncompatible -> stringResource(R.string.advanced_dropped_thinking)
    DropReason.ThinkingBudget -> stringResource(R.string.advanced_dropped_reasoning_budget)
    DropReason.InvalidValue -> stringResource(R.string.advanced_dropped_value)
    DropReason.RequiredField -> stringResource(R.string.advanced_dropped_required_default)
    DropReason.Conflict -> parameter.conflictsWith.firstOrNull()
        ?.let { stringResource(R.string.advanced_dropped_conflict_with, stringResource(generationParameterTitleRes(it))) }
        ?: stringResource(R.string.advanced_dropped_conflict)
    DropReason.RequirementUnmet -> parameter.requires.firstOrNull()
        ?.let { (it["key"] as? JsonPrimitive)?.content }
        ?.let { stringResource(R.string.advanced_dropped_requires, stringResource(generationParameterTitleRes(it))) }
        ?: stringResource(R.string.advanced_dropped_depends)
}
