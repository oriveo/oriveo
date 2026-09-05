package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.FlashOn
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
internal fun RelayEditConnectionCard(
    endpoint: String,
    onEndpointChange: (String) -> Unit,
    apiKeyPreview: String,
    
    requiresCredential: Boolean,
    securityMode: RelayConnectionSecurityMode,
    hasCredentialMaterial: Boolean,
    isSubmitting: Boolean,
    isTestingConnection: Boolean,
    testResult: RelayConnectionTestResult?,
    endpointPlaceholder: String,
    endpointSelectionRange: IntRange? = null,
    onEditApiKey: () -> Unit,
    onSecurityModeSelected: (
        RelayConnectionSecurityMode,
        RelaySecurityModePolicy.Assessment,
        Boolean,
    ) -> Unit,
    onTestConnection: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val spacing = OriveoTheme.spacing
    
    val sectionTint = colors.info

    val canTest = endpoint.trim().isNotEmpty()

    Column(verticalArrangement = Arrangement.spacedBy(spacing.md)) {
        RelayGroupHeader(
            title = stringResource(R.string.relay_section_connection),
            icon = Icons.Filled.Link,
            tint = sectionTint,
        )

        val cardShape = RoundedCornerShape(OriveoTheme.radius.md)
        val borderColor = sectionTint.copy(alpha = if (isDark) 0.16f else 0.10f)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(cardShape)
                .background(colors.surfaceChrome)
                .border(OriveoBorderWidth.standard, borderColor, cardShape),
        ) {
            
            EndpointBlock(
                value = endpoint,
                onValueChange = onEndpointChange,
                placeholder = endpointPlaceholder,
                enabled = !isSubmitting,
                sectionTint = sectionTint,
                selectionRange = endpointSelectionRange,
            )
            Divider()
            Box(modifier = Modifier.padding(horizontal = spacing.lg)) {
                RelaySecurityModeControl(
                    endpoint = endpoint,
                    selectedMode = securityMode,
                    hasCredentialMaterial = hasCredentialMaterial,
                    enabled = !isSubmitting && !isTestingConnection,
                    onModeSelected = onSecurityModeSelected,
                )
            }
            Divider()
            
            ApiKeyRow(
                state = RelayApiKeyRowState.of(requiresCredential, apiKeyPreview),
                apiKeyPreview = apiKeyPreview,
                isCleartext = securityMode == RelayConnectionSecurityMode.LocalHttp ||
                    securityMode == RelayConnectionSecurityMode.PrivateVpn,
                enabled = !isSubmitting,
                onClick = onEditApiKey,
            )
            Divider()
            
            TestRow(
                isTesting = isTestingConnection,
                enabled = canTest && !isSubmitting,
                sectionTint = sectionTint,
                onClick = onTestConnection,
            )
            
            if (testResult != null) {
                TestResultRow(result = testResult)
            }
        }
    }
}

@Composable
private fun EndpointBlock(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    enabled: Boolean,
    sectionTint: Color,
    selectionRange: IntRange?,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val spacing = OriveoTheme.spacing
    val textStyle = OriveoTheme.typography.body.copy(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        color = if (enabled) colors.textPrimary else colors.textTertiary,
    )
    var fieldValue by remember { mutableStateOf(TextFieldValue(value, selection = TextRange(value.length))) }
    LaunchedEffect(value, selectionRange) {
        if (fieldValue.text != value || selectionRange != null) {
            fieldValue = TextFieldValue(
                text = value,
                selection = selectionRange?.let { TextRange(it.first, it.last + 1) }
                    ?: TextRange(value.length),
            )
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = spacing.lg, vertical = spacing.md),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = stringResource(R.string.relay_field_endpoint).uppercase(),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(colors.surfaceInset.copy(alpha = if (isDark) 0.6f else 0.9f))
                .border(
                    OriveoBorderWidth.fine,
                    sectionTint.copy(alpha = if (isDark) 0.18f else 0.10f),
                    RoundedCornerShape(10.dp),
                )
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Language,
                contentDescription = null,
                tint = sectionTint.copy(alpha = 0.8f),
                modifier = Modifier.size(14.dp),
            )
            BasicTextField(
                value = fieldValue,
                onValueChange = {
                    fieldValue = it
                    onValueChange(it.text)
                },
                singleLine = true,
                enabled = enabled,
                textStyle = textStyle,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                cursorBrush = SolidColor(colors.primary),
                modifier = Modifier.weight(1f),
                decorationBox = { innerTextField ->
                    Box(modifier = Modifier.fillMaxWidth()) {
                        if (fieldValue.text.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = textStyle.copy(color = colors.textTertiary),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        innerTextField()
                    }
                },
            )
        }
    }
}


@androidx.compose.runtime.Immutable
internal enum class RelayApiKeyRowState {
    
    NotRequired,

    
    Missing,

    
    Present,
    ;

    companion object {
        fun of(requiresCredential: Boolean, apiKeyPreview: String): RelayApiKeyRowState = when {
            apiKeyPreview.isNotBlank() -> Present
            requiresCredential -> Missing
            else -> NotRequired
        }
    }
}

@Composable
private fun ApiKeyRow(
    state: RelayApiKeyRowState,
    apiKeyPreview: String,
    isCleartext: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isWarning = state == RelayApiKeyRowState.Missing
    val accent = if (isWarning) colors.warning else colors.textSecondary
    
    val clickable = enabled && state != RelayApiKeyRowState.NotRequired
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = clickable, onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Key,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(14.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = stringResource(R.string.api_key),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                text = when (state) {
                    RelayApiKeyRowState.Present -> apiKeyPreview
                    RelayApiKeyRowState.Missing -> stringResource(R.string.error_api_key_required)
                    RelayApiKeyRowState.NotRequired ->
                        stringResource(
                            if (isCleartext) R.string.relay_connection_no_key_required_cleartext
                            else R.string.relay_connection_no_key_required,
                        )
                },
                style = if (state == RelayApiKeyRowState.Present) {
                    OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace)
                } else {
                    OriveoTheme.typography.footnote
                },
                color = if (isWarning) colors.warning else colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (clickable) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(colors.primarySoft.opacity(0.86f))
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) {
                Text(
                    text = stringResource(R.string.relay_type_row_change),
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.primary,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun TestRow(
    isTesting: Boolean,
    enabled: Boolean,
    sectionTint: Color,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(sectionTint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            if (isTesting) {
                CircularProgressIndicator(
                    color = sectionTint,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(14.dp),
                )
            } else {
                Icon(
                    imageVector = Icons.Filled.FlashOn,
                    contentDescription = null,
                    tint = sectionTint,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        Text(
            text = stringResource(
                if (isTesting) R.string.relay_test_connection_testing
                else R.string.relay_test_connection,
            ),
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = if (enabled) colors.textPrimary else colors.textTertiary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun TestResultRow(result: RelayConnectionTestResult) {
    val colors = OriveoTheme.colors
    val tint = if (result.isSuccess) colors.success else colors.warning
    val icon = if (result.isSuccess) Icons.Filled.CheckCircle else Icons.Filled.Warning
    val message = result.message.ifBlank {
        stringResource(
            if (result.isSuccess) R.string.relay_test_connection_success
            else R.string.relay_test_connection_missing_fields,
        )
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(tint.copy(alpha = 0.08f))
            .padding(
                horizontal = OriveoTheme.spacing.lg,
                vertical = 10.dp,
            ),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(14.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = message,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            result.failurePresentation?.let { RelayEditFailureDetails(it) }
        }
    }
}

@Composable
internal fun RelayEditFailureDetails(presentation: RelayEditFailurePresentation) {
    val colors = OriveoTheme.colors
    if (presentation.endpoint.isNotBlank()) {
        Text(
            text = "${stringResource(R.string.relay_field_endpoint)}: ${presentation.endpoint}",
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textTertiary,
        )
    }
    presentation.statusCode?.let { code ->
        Text(
            text = "HTTP $code",
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textTertiary,
        )
    }
    Text(
        text = stringResource(R.string.relay_quick_automatic_retries, presentation.automaticRetryCount),
        style = OriveoTheme.typography.footnote,
        color = colors.textTertiary,
    )
    presentation.upstreamJson?.let { body ->
        Text(
            text = stringResource(R.string.relay_upstream_response_redacted),
            style = OriveoTheme.typography.footnote,
            color = colors.textTertiary,
        )
        Text(
            text = body,
            style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
            color = colors.textSecondary,
            maxLines = 6,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun Divider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.6.dp)
            .background(OriveoTheme.colors.border.opacity(0.5f)),
    )
}
