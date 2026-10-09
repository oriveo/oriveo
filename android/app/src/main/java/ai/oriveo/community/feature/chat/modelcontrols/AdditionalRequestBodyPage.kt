package ai.oriveo.community.feature.chat.modelcontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.AdditionalRequestBody.PreviewStatus
import ai.oriveo.community.core.provider.AdditionalRequestBody.Validation
import ai.oriveo.community.feature.chat.composer.ModelControlHairline
import ai.oriveo.community.feature.chat.composer.ModelControlNote
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.modelControlTextButtonColors

/**
 * The additional request body page: a switch card, a dark monospaced editor, a per-field "when sent" list, then an explanation.
 * Validation and the list come only from [AdditionalRequestBody.preview]; the page never parses JSON itself.
 */
@Composable
internal fun AdditionalRequestBodyPage(
    provider: Provider,
    model: AIModel,
    /** Null when entered from the provider detail page, where the model-default layer is edited. */
    conversationId: String?,
    isReadOnly: Boolean,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val colors = OriveoTheme.colors
    val clipboard = LocalClipboardManager.current
    val store = remember(context) { LocalCapabilityCustomFragmentStore.from(context) }
    var body by remember(provider.id, model.id, conversationId) {
        mutableStateOf(AdditionalBodyEditor.load(store, provider, model, conversationId))
    }
    var tidyFailed by remember { mutableStateOf(false) }
    var pendingPaste by remember { mutableStateOf<String?>(null) }
    val canEdit = !isReadOnly

    fun update(next: AdditionalBody) {
        body = next
        AdditionalBodyEditor.save(store, provider, model, conversationId, next)
    }

    pendingPaste?.let { pasted ->
        AlertDialog(
            onDismissRequest = { pendingPaste = null },
            title = { Text(stringResource(R.string.additional_body_paste_replace_title)) },
            text = { Text(stringResource(R.string.additional_body_paste_replace_body)) },
            confirmButton = {
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = {
                        update(body.copy(rawJSON = pasted))
                        pendingPaste = null
                    },
                ) { Text(stringResource(R.string.additional_body_paste)) }
            },
            dismissButton = {
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { pendingPaste = null },
                ) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    val preview = remember(body.rawJSON) { AdditionalRequestBody.preview(body.rawJSON) }
    val errorLines = buildSet {
        (preview.validation as? Validation.Rejected)?.line?.let(::add)
        preview.entries.filter { it.status != PreviewStatus.Included }.mapNotNull { it.line }.forEach(::add)
    }
    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 24.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(
                colors = modelControlTextButtonColors(),
                onClick = onBack,
            ) { Text(stringResource(R.string.back)) }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.additional_body_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                val modelName = model.name.ifBlank { model.id }
                Text(
                    text = if (conversationId != null) "$modelName · ${stringResource(R.string.advanced_this_conversation_only)}" else modelName,
                    fontSize = 12.5.sp,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(top = 6.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AdvancedCard {
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp).padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.additional_body_send_toggle), fontSize = 16.sp, color = colors.textPrimary)
                        Text(stringResource(R.string.additional_body_send_toggle_note), fontSize = 12.5.sp, color = colors.textSecondary)
                    }
                    val toggleLabel = stringResource(R.string.additional_body_send_toggle)
                    Switch(
                        checked = body.sendWithRequest,
                        enabled = canEdit,
                        onCheckedChange = { update(body.copy(sendWithRequest = it)) },
                        modifier = Modifier
                            .semantics { contentDescription = toggleLabel },
                    )
                }
            }
            AdditionalBodyEditorCard(
                raw = body.rawJSON,
                errorLines = errorLines,
                editable = canEdit,
                onChange = {
                    tidyFailed = false
                    update(body.copy(rawJSON = it))
                },
                onPaste = {
                    val pasted = clipboard.getText()?.text ?: return@AdditionalBodyEditorCard
                    if (body.rawJSON.isBlank()) update(body.copy(rawJSON = pasted)) else pendingPaste = pasted
                },
                onTidy = {
                    val tidied = AdditionalRequestBody.tidy(body.rawJSON)
                    tidyFailed = tidied == null
                    if (tidied != null) update(body.copy(rawJSON = tidied))
                },
            )
            if (tidyFailed) {
                ModelControlNote(R.string.additional_body_tidy_invalid, tone = colors.danger)
            }
            WhenSendingSection(preview)
            ModelControlNote(R.string.additional_body_footer)
            AdditionalBodyEditor.engineDocs(provider)?.let { docs ->
                val uriHandler = LocalUriHandler.current
                TextButton(
                    colors = modelControlTextButtonColors(),
                    onClick = { runCatching { uriHandler.openUri(docs.url) } },
                    modifier = Modifier
                        .heightIn(min = 44.dp),
                ) { Text(stringResource(AdditionalBodyEditor.ENGINE_DOCS_LINK_RES, docs.engineName), fontSize = 14.sp, fontWeight = FontWeight.Medium) }
            }
        }
    }
}

@Composable
private fun AdditionalBodyEditorCard(
    raw: String,
    errorLines: Set<Int>,
    editable: Boolean,
    onChange: (String) -> Unit,
    onPaste: () -> Unit,
    onTidy: () -> Unit,
) {
    val colors = OriveoTheme.colors
    // The editor is always dark: the light theme uses the text color as its background, the dark theme the page's deepest background.
    val editorBackground = if (OriveoTheme.isDark) colors.backgroundBase else colors.textPrimary
    val editorText = if (OriveoTheme.isDark) colors.textPrimary else colors.textInverse
    val mono = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 20.sp, color = editorText)
    val lineCount = raw.count { it == '\n' } + 1
    val editorLabel = stringResource(R.string.additional_body_title)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(editorBackground),
    ) {
        Row(modifier = Modifier.fillMaxWidth().heightIn(min = 140.dp).padding(vertical = 12.dp)) {
            // Line number column; the failing line's number is tinted red so it matches the line numbers in the "when sent" list.
            Column(modifier = Modifier.padding(horizontal = 10.dp)) {
                (1..lineCount).forEach { line ->
                    val error = line in errorLines
                    Text(
                        text = line.toString(),
                        style = mono.copy(color = if (error) colors.danger else editorText.copy(alpha = 0.4f)),
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(if (error) colors.dangerSoft else editorBackground)
                            .padding(horizontal = 4.dp),
                    )
                }
            }
            BasicTextField(
                value = raw,
                onValueChange = onChange,
                enabled = editable,
                textStyle = mono,
                cursorBrush = SolidColor(editorText),
                modifier = Modifier
                    .weight(1f)
                    .padding(end = 12.dp)
                    .semantics { contentDescription = editorLabel },
            )
        }
        ModelControlHairline(leadingInset = 0)
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ModelControlNote(
                text = stringResource(R.string.additional_body_device_only),
                icon = Icons.Outlined.PhoneAndroid,
                tone = editorText.copy(alpha = 0.7f),
            )
            Spacer(Modifier.width(4.dp))
            TextButton(
                enabled = editable,
                onClick = onPaste,
            ) { Text(stringResource(R.string.additional_body_paste), color = editorText) }
            TextButton(
                enabled = editable,
                onClick = onTidy,
            ) { Text(stringResource(R.string.additional_body_tidy), color = editorText) }
        }
    }
}

@Composable
private fun WhenSendingSection(preview: AdditionalRequestBody.Preview) {
    val colors = OriveoTheme.colors
    val rejection = preview.validation as? Validation.Rejected
    // A syntax error has no per-field list, only the one-sentence reason (with the line number).
    val syntaxReason = rejection?.takeIf { preview.entries.isEmpty() }?.let { syntaxReasonText(it) }
    if (preview.entries.isEmpty() && syntaxReason == null) return
    AdvancedSectionLabel(stringResource(R.string.additional_body_when_sending))
    AdvancedCard {
        if (syntaxReason != null) {
            Text(syntaxReason, fontSize = 14.sp, color = colors.danger, modifier = Modifier.padding(16.dp))
        }
        preview.entries.forEachIndexed { index, entry ->
            if (index > 0) ModelControlHairline()
            val included = entry.status == PreviewStatus.Included
            Column(modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp).padding(horizontal = 16.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = entry.path,
                        style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = stringResource(if (included) R.string.additional_body_included else R.string.additional_body_cannot_change),
                        fontSize = 13.sp,
                        color = if (included) colors.success else colors.danger,
                    )
                }
                if (!included) {
                    val reason = stringResource(AdditionalBodyEditor.reasonRes(entry))
                    Text(
                        text = entry.line?.let { stringResource(R.string.additional_body_remove_line, reason, it) } ?: reason,
                        fontSize = 12.5.sp,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun syntaxReasonText(rejection: Validation.Rejected): String {
    val reason = when (rejection.reason) {
        "too_large" -> stringResource(R.string.additional_body_reason_too_large)
        "invalid_json" -> stringResource(R.string.additional_body_reason_invalid_json)
        "not_object" -> stringResource(R.string.additional_body_reason_not_object)
        "too_deep" -> stringResource(R.string.additional_body_reason_too_deep)
        else -> stringResource(R.string.additional_body_check)
    }
    return rejection.line?.let { stringResource(R.string.local_request_line_format, it, reason) } ?: reason
}
