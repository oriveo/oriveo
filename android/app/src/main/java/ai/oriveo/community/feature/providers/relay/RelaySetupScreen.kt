package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.provider.RelayDetectionEvidence
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryAttemptKind
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.local.LocalComputeSetupFields
import ai.oriveo.community.feature.providers.local.LocalComputeSetupViewModel
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoErrorCard
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSectionHeader
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.opacity
import org.koin.androidx.compose.koinViewModel


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RelaySetupScreen(
    entryPoint: ProviderSetupEntryPoint,
    initialMethod: CustomLLMConnectionMethod = CustomLLMConnectionMethod.Relay,
    onBack: () -> Unit,
    onCompleted: (RelaySetupCompletionTarget) -> Unit,
    viewModel: RelaySetupViewModel = koinViewModel(),
) {
    val localViewModel: LocalComputeSetupViewModel = koinViewModel()
    localViewModel.attachCoordinator(viewModel.customLLMCoordinator)
    LaunchedEffect(entryPoint) {
        
    }
    LaunchedEffect(initialMethod) {
        if (initialMethod == CustomLLMConnectionMethod.Relay) viewModel.selectRelayMethod()
        else viewModel.selectLocalMethod()
    }

    LaunchedEffect(viewModel.completionTarget, viewModel.customLLMCoordinator.method, viewModel.customLLMCoordinator.evidence) {
        viewModel.completionTarget?.let { completion ->
            if (viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay)) onCompleted(completion)
        }
    }

    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout
    val density = LocalDensity.current
    // The route already selected the scenario. Render from it immediately so Local never flashes
    // the Relay title or fields while the coordinator is attaching on the first frame.
    val routeMethod = initialMethod
    var actionBarHeightPx by remember { mutableStateOf(0) }
    val showsActionBar = routeMethod == CustomLLMConnectionMethod.Local ||
        (routeMethod == CustomLLMConnectionMethod.Relay &&
            (viewModel.mode == RelaySetupMode.Quick || !viewModel.isChoosingRelayKind))
    val scrollBottomPadding = if (showsActionBar && actionBarHeightPx > 0) {
        with(density) { actionBarHeightPx.toDp() } + spacing.md
    } else {
        spacing.lg
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()
        RelayConstellationAtmosphere()

        Box(
            modifier = Modifier
                .fillMaxSize()
                .imePadding(),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                RelaySetupTopBar(
                    title = stringResource(
                        if (routeMethod == CustomLLMConnectionMethod.Local) {
                            R.string.local_compute_title
                        } else {
                            R.string.provider_setup_relay_title
                        },
                    ),
                    onBack = {
                        when {
                            routeMethod == CustomLLMConnectionMethod.Local -> onBack()
                            viewModel.mode == RelaySetupMode.Quick -> onBack()
                            !viewModel.isChoosingRelayKind -> viewModel.returnToRelayKindPicker()
                            else -> viewModel.showQuickSetup()
                        }
                    },
                )

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = layout.screenH)
                        .padding(top = spacing.lg, bottom = scrollBottomPadding),
                ) {
                    if (routeMethod == CustomLLMConnectionMethod.Local) {
                        LocalComputeSetupFields(
                            onCompleted = { providerId ->
                                onCompleted(RelaySetupCompletionTarget.ProviderDetail(providerId))
                            },
                            coordinator = viewModel.customLLMCoordinator,
                            viewModel = localViewModel,
                        )
                    } else if (viewModel.mode == RelaySetupMode.Quick) {
                        RelayQuickSetupContent(viewModel)
                    } else if (viewModel.isChoosingRelayKind) {
                        RelayStepHeader(
                            stepLabel = stringResource(R.string.relay_setup_step_1_of_2),
                            title = stringResource(R.string.relay_kind_picker_title),
                            subtitle = stringResource(R.string.relay_kind_picker_subtitle),
                        )

                        Spacer(modifier = Modifier.height(layout.sectionGap))

                        RelayKindPicker(
                            selectedKind = viewModel.selectedRelayKind,
                            onSelect = viewModel::selectRelayKind,
                        )
                    } else {
                        viewModel.selectedRelayKind?.let { relayKind ->
                            RelayStep2Header(kind = relayKind)

                            Spacer(modifier = Modifier.height(spacing.md))

                            RelaySimpleSection(viewModel = viewModel)

                            if (relayKind == RelayKind.Custom) {
                                Spacer(modifier = Modifier.height(layout.sectionGap))
                                RelayCustomAdvancedSection(viewModel = viewModel)
                            }

                            viewModel.error?.let { error ->
                                Spacer(modifier = Modifier.height(layout.sectionGap))
                                OriveoErrorCard(error = error)
                            }
                        }
                    }
                }
            }

            if (routeMethod == CustomLLMConnectionMethod.Local) {
                LocalComputeActionBar(
                    isWorking = localViewModel.isConnecting,
                    isVerified = localViewModel.isConnectionVerified,
                    enabled = !localViewModel.isConnecting && localViewModel.endpoint.isNotBlank() &&
                        (localViewModel.engine != ai.oriveo.community.core.provider.LocalEngineKind.OpenWebUI || localViewModel.apiKey.isNotBlank()),
                    onClick = localViewModel::connect,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            } else if (viewModel.mode == RelaySetupMode.Quick) {
                RelayQuickActionBar(
                    action = viewModel.quickAction,
                    isWorking = viewModel.isDiscovering || viewModel.isSubmitting,
                    enabled = viewModel.canRunQuickAction,
                    onClick = viewModel::runQuickAction,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            } else if (routeMethod == CustomLLMConnectionMethod.Relay && !viewModel.isChoosingRelayKind) {
                RelayActionBar(
                    isTesting = viewModel.isTestingConnection,
                    canTest = viewModel.canTestConnection,
                    testResult = viewModel.testConnectionResult,
                    isSaving = viewModel.isSubmitting,
                    canSave = viewModel.canSubmit,
                    onTest = viewModel::testConnection,
                    onSave = viewModel::submit,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            }
        }
    }
}

@Composable
private fun RelaySetupTopBar(
    title: String,
    onBack: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 24.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .clickable(onClick = onBack),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.back),
                tint = colors.textPrimary,
                modifier = Modifier.size(17.dp),
            )
        }

        Text(
            text = title,
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )

        Spacer(modifier = Modifier.size(36.dp))
    }
}

@Composable
private fun RelayConstellationAtmosphere() {
    val colors = OriveoTheme.colors
    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(310.dp),
    ) {
        val points = listOf(
            Offset(size.width * 0.04f, size.height * 0.18f),
            Offset(size.width * 0.22f, size.height * 0.08f),
            Offset(size.width * 0.39f, size.height * 0.24f),
            Offset(size.width * 0.58f, size.height * 0.10f),
            Offset(size.width * 0.76f, size.height * 0.28f),
            Offset(size.width * 0.96f, size.height * 0.14f),
            Offset(size.width * 0.15f, size.height * 0.46f),
            Offset(size.width * 0.48f, size.height * 0.52f),
            Offset(size.width * 0.84f, size.height * 0.48f),
        )
        val links = listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 4 to 5, 0 to 6, 2 to 7, 4 to 8, 6 to 7, 7 to 8)
        links.forEach { (from, to) ->
            val alpha = 0.22f * (1f - ((points[from].y + points[to].y) / 2f / size.height))
            drawLine(colors.primary.copy(alpha = alpha), points[from], points[to], strokeWidth = 1.dp.toPx())
        }
        points.forEach { point ->
            val alpha = 0.5f * (1f - point.y / size.height)
            drawCircle(colors.primary.copy(alpha = alpha), radius = 2.2.dp.toPx(), center = point)
            drawCircle(colors.primary.copy(alpha = alpha * 0.16f), radius = 10.dp.toPx(), center = point)
        }
    }
}

@Composable
private fun RelayQuickSetupContent(viewModel: RelaySetupViewModel) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
            Text(
                text = stringResource(R.string.relay_quick_title),
                style = OriveoTheme.typography.hero,
                color = colors.textPrimary,
            )
            Text(
                text = stringResource(R.string.relay_quick_subtitle),
                style = OriveoTheme.typography.body,
                color = colors.textSecondary,
            )
        }

        RelayQuickField(
            label = stringResource(R.string.relay_field_endpoint),
            value = viewModel.endpoint,
            onValueChange = viewModel::updateEndpoint,
            placeholder = stringResource(R.string.relay_endpoint_placeholder),
            footnote = stringResource(R.string.relay_request_url_footnote),
            icon = Icons.Filled.Link,
            keyboardType = KeyboardType.Uri,
            selectionRange = viewModel.endpointHighlightRange,
        )
        RelayQuickField(
            label = stringResource(R.string.api_key),
            value = viewModel.apiKey,
            onValueChange = viewModel::updateApiKey,
            placeholder = stringResource(R.string.relay_api_key_placeholder),
            icon = Icons.Filled.Key,
            secure = true,
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(spacing.sm),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = colors.primary, modifier = Modifier.size(14.dp))
            Text(
                text = stringResource(R.string.relay_api_key_privacy),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }

        if (viewModel.detectedModelIDs.isEmpty()) {
            RelayQuickField(
                label = stringResource(R.string.relay_default_model_label),
                value = viewModel.defaultModel,
                onValueChange = viewModel::updateDefaultModel,
                placeholder = viewModel.defaultModelPlaceholder,
                footnote = stringResource(R.string.relay_default_model_recommended_footnote),
                icon = Icons.Filled.AutoAwesome,
            )
        } else {
            RelayDetectedModelPicker(viewModel)
        }

        RelayFormIssueNotes(issues = viewModel.formIssues)

        RelayQuickResult(viewModel)
        RelayManualSetupEntry(onClick = viewModel::showManualSetup)
    }
}

@Composable
private fun RelayQuickField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    footnote: String? = null,
    secure: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    selectionRange: IntRange? = null,
) {
    val colors = OriveoTheme.colors
    val surfaceFill = relayQuickSurfaceFillColor(colors, OriveoTheme.isDark)
    var focused by remember { mutableStateOf(false) }
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
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = colors.primary, modifier = Modifier.size(16.dp))
            Text(label, style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
        }
        BasicTextField(
            value = fieldValue,
            onValueChange = {
                fieldValue = it
                onValueChange(it.text)
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(54.dp)
                .onFocusChanged { focused = it.isFocused }
                .clip(RoundedCornerShape(OriveoTheme.radius.inset))
                .background(surfaceFill)
                .border(
                    width = if (focused) 1.dp else 0.dp,
                    color = if (focused) colors.primary.copy(alpha = 0.72f) else Color.Transparent,
                    shape = RoundedCornerShape(OriveoTheme.radius.inset),
                )
                .padding(horizontal = 16.dp),
            textStyle = OriveoTheme.typography.body.copy(color = colors.textPrimary),
            cursorBrush = SolidColor(colors.primary),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (fieldValue.text.isEmpty()) {
                        Text(placeholder, style = OriveoTheme.typography.body, color = colors.textTertiary)
                    }
                    inner()
                }
            },
        )
        footnote?.let {
            Text(it, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        }
    }
}

@Composable
private fun RelayDetectedModelPicker(viewModel: RelaySetupViewModel) {
    val colors = OriveoTheme.colors
    val surfaceFill = relayQuickSurfaceFillColor(colors, OriveoTheme.isDark)
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = colors.primary, modifier = Modifier.size(16.dp))
            Text(
                stringResource(R.string.relay_default_model_label),
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textSecondary,
            )
        }
        Box {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp)
                    .clip(RoundedCornerShape(OriveoTheme.radius.inset))
                    .background(surfaceFill)
                    .clickable { expanded = true }
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(viewModel.defaultModel, style = OriveoTheme.typography.body, color = colors.textPrimary, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Icon(Icons.Filled.ExpandMore, contentDescription = null, tint = colors.textTertiary)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                viewModel.detectedModelIDs.forEach { modelID ->
                    DropdownMenuItem(
                        text = { Text(modelID, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        onClick = { viewModel.updateDefaultModel(modelID); expanded = false },
                    )
                }
            }
        }
        Text(
            stringResource(R.string.relay_models_found, viewModel.detectedModelIDs.size),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}


internal fun relayQuickSurfaceFillColor(colors: OriveoColors, isDark: Boolean): Color =
    colors.primarySoft
        .opacity(if (isDark) 0.68f else 0.62f)
        .compositeOver(colors.surfaceInset)

@Composable
private fun RelayQuickResult(viewModel: RelaySetupViewModel) {
    val colors = OriveoTheme.colors
    val detection = viewModel.selectedDetection ?: viewModel.discoveryResult?.detections?.firstOrNull()
    val failure = viewModel.discoveryFailureDetail
    if (detection == null && failure == null) return
    val success = detection != null && failure == null
    val tone = if (success) colors.success else colors.warning
    val fill = if (success) colors.successSoft else colors.warningSoft
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(fill)
            .border(1.dp, tone.copy(alpha = 0.3f), RoundedCornerShape(OriveoTheme.radius.md))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(if (success) Icons.Filled.CheckCircle else Icons.Filled.Warning, contentDescription = null, tint = tone, modifier = Modifier.size(18.dp))
            Text(
                if (success) stringResource(R.string.relay_quick_detected) else stringResource(R.string.relay_quick_failed),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = tone,
            )
        }
        Text(
            text = when {
                failure != null -> failure
                detection?.generationVerified == true -> stringResource(R.string.relay_quick_verified_protocol, detection.transport.localizedLabel())
                detection?.detectionEvidence == RelayDetectionEvidence.GenerationProbe -> stringResource(R.string.relay_quick_probe_protocol, detection.transport.localizedLabel())
                else -> stringResource(R.string.relay_quick_empty_catalog)
            },
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
        )
        if (!success) {
            val attempts = viewModel.discoveryResult?.attempts.orEmpty()
            relayAttemptDiagnosticLines(attempts).forEach { diagnostic ->
                Text(
                    text = diagnostic,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
            val retryCount = relayRetryCount(attempts)
            if (retryCount > 0) {
                Text(
                    text = stringResource(R.string.relay_quick_automatic_retries, retryCount),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
            relayPreferredUpstreamMessage(attempts)
                ?.let { Text(it, style = OriveoTheme.typography.footnote, color = colors.textPrimary) }
        }
    }
}

internal fun relayAttemptDiagnosticLines(attempts: List<RelayDiscoveryAttempt>): List<String> =
    attempts.map { attempt ->
        val method = when (attempt.kind) {
            RelayDiscoveryAttemptKind.Catalog -> "GET"
            RelayDiscoveryAttemptKind.GenerationProbe -> "POST"
        }
        "$method ${attempt.requestUrl} -> ${attempt.statusCode?.toString() ?: "-"}"
    }

internal fun relayPreferredUpstreamMessage(attempts: List<RelayDiscoveryAttempt>): String? {
    val informative = attempts.filter { !it.upstreamMessage.isNullOrBlank() }
    return informative.lastOrNull { it.statusCode == 400 || it.statusCode == 422 }?.upstreamMessage
        ?: informative.lastOrNull()?.upstreamMessage
}

internal fun relayRetryCount(attempts: List<RelayDiscoveryAttempt>): Int = attempts.sumOf { it.retryCount }

@Composable
private fun RelayManualSetupEntry(onClick: () -> Unit) {
    val colors = OriveoTheme.colors
    Column {
        Box(
            Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(Brush.horizontalGradient(listOf(Color.Transparent, colors.border, Color.Transparent))),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.relay_manual_setup), style = OriveoTheme.typography.body, color = colors.textPrimary)
                Text(stringResource(R.string.relay_manual_setup_subtitle), style = OriveoTheme.typography.footnote, color = colors.textSecondary)
            }
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun RelayQuickActionBar(
    action: RelayQuickAction,
    isWorking: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val text = when (action) {
        RelayQuickAction.Detect -> stringResource(R.string.relay_quick_detect_action)
        RelayQuickAction.ConnectAndSave -> stringResource(R.string.relay_quick_connect_save)
        RelayQuickAction.SaveAndContinue -> stringResource(R.string.relay_quick_save_continue)
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, colors.background.copy(alpha = 0.96f), colors.background)))
            .navigationBarsPadding()
            .padding(horizontal = OriveoTheme.layout.screenH, vertical = 18.dp),
    ) {
        OriveoPrimaryButton(
            text = text,
            onClick = onClick,
            enabled = enabled,
            loading = isWorking,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun LocalComputeActionBar(
    isWorking: Boolean,
    isVerified: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(
                    listOf(Color.Transparent, colors.background.copy(alpha = 0.96f), colors.background),
                ),
            )
            .navigationBarsPadding()
            .padding(horizontal = OriveoTheme.layout.screenH, vertical = 18.dp),
    ) {
        OriveoPrimaryButton(
            text = if (isWorking) {
                stringResource(R.string.local_compute_connecting)
            } else if (isVerified) {
                stringResource(R.string.relay_quick_connect_save)
            } else {
                stringResource(R.string.relay_test_connection)
            },
            onClick = onClick,
            enabled = enabled,
            loading = isWorking,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun RelayTransport.localizedLabel(): String = stringResource(
    when (this) {
        RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> R.string.relay_transport_openai_chat_completions
        RelayTransport.LlamaCppNative -> R.string.relay_transport_llamacpp_native
        RelayTransport.OpenAIResponses -> R.string.relay_transport_openai_responses
        RelayTransport.AnthropicMessages -> R.string.relay_transport_anthropic_messages
        RelayTransport.GeminiGenerateContent -> R.string.relay_transport_gemini_generate_content
    },
)

@Composable
private fun RelayActionBar(
    isTesting: Boolean,
    canTest: Boolean,
    testResult: RelayConnectionTestResult?,
    isSaving: Boolean,
    canSave: Boolean,
    onTest: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, colors.background, colors.background)))
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(spacing.sm),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = layout.screenH)
                .padding(top = spacing.md, bottom = spacing.lg),
            verticalArrangement = Arrangement.spacedBy(spacing.sm),
        ) {
            RelayConnectionResultRow(testResult = testResult)

            Text(
                text = stringResource(R.string.relay_test_connection_subtitle),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(spacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OriveoSecondaryButton(
                    text = stringResource(R.string.relay_test_connection),
                    onClick = onTest,
                    enabled = canTest,
                    loading = isTesting,
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Filled.NetworkCheck,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                    modifier = Modifier.weight(1f),
                )
                OriveoPrimaryButton(
                    text = if (isSaving) stringResource(R.string.saving) else stringResource(R.string.save),
                    onClick = onSave,
                    enabled = canSave,
                    loading = isSaving,
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Filled.Save,
                            contentDescription = null,
                            tint = androidx.compose.ui.graphics.Color.White,
                            modifier = Modifier.size(18.dp),
                        )
                    },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun RelayConnectionResultRow(testResult: RelayConnectionTestResult?) {
    if (testResult == null) return

    val colors = OriveoTheme.colors
    val isSuccess = testResult.isSuccess
    val tone = if (isSuccess) colors.success else colors.warning
    val fill = if (isSuccess) colors.successSoft else colors.warningSoft
    val message = testResult.message.ifBlank {
        stringResource(
            if (isSuccess) R.string.relay_test_connection_success
            else R.string.relay_test_connection_missing_fields,
        )
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(fill)
            .border(OriveoBorderWidth.standard, tone.opacity(0.22f), RoundedCornerShape(OriveoTheme.radius.md))
            .padding(horizontal = OriveoTheme.spacing.md, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Icon(
            imageVector = if (isSuccess) Icons.Filled.CheckCircle else Icons.Filled.Warning,
            contentDescription = null,
            tint = tone,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = message,
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = tone,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RelaySimpleSection(
    viewModel: RelaySetupViewModel,
) {
    val spacing = OriveoTheme.spacing

    Column {
            OriveoSectionHeader(title = stringResource(R.string.relay_mode_simple))

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoLabeledField(
                label = stringResource(R.string.relay_field_name),
                value = viewModel.name,
                onValueChange = { viewModel.name = it },
                placeholder = stringResource(R.string.relay_name_placeholder),
                footnote = stringResource(R.string.relay_name_footnote),
                enabled = !viewModel.isSubmitting,
            )

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoLabeledField(
                label = stringResource(R.string.relay_field_endpoint),
                value = viewModel.endpoint,
                onValueChange = viewModel::updateEndpoint,
                placeholder = stringResource(R.string.relay_endpoint_placeholder),
                footnote = stringResource(R.string.relay_endpoint_footnote),
                enabled = !viewModel.isSubmitting,
                selectionRange = viewModel.endpointHighlightRange,
            )

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoLabeledField(
                label = stringResource(R.string.api_key),
                value = viewModel.apiKey,
                onValueChange = viewModel::updateApiKey,
                placeholder = stringResource(R.string.relay_api_key_placeholder),
                isSecure = true,
                enabled = !viewModel.isSubmitting,
            )

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoLabeledField(
                label = stringResource(R.string.relay_default_model_label),
                value = viewModel.defaultModel,
                onValueChange = viewModel::updateDefaultModel,
                placeholder = stringResource(R.string.relay_default_model_placeholder),
                footnote = stringResource(R.string.relay_default_model_footnote),
                enabled = !viewModel.isSubmitting,
            )

            Spacer(modifier = Modifier.height(spacing.lg))

            RelayFormIssueNotes(issues = viewModel.formIssues)
    }
}


@Composable
private fun RelayStepHeader(stepLabel: String, title: String, subtitle: String) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
        Text(
            text = stepLabel,
            style = OriveoTheme.typography.caption,
            color = colors.primary,
        )
        Text(
            text = title,
            style = OriveoTheme.typography.title1,
            color = colors.textPrimary,
        )
        Text(
            text = subtitle,
            style = OriveoTheme.typography.body,
            color = colors.textSecondary,
        )
    }
}


@Composable
private fun RelayStep2Header(kind: RelayKind) {
    val meta = relayKindMeta(kind)
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val tint = meta.tint
    Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
        Text(
            text = stringResource(R.string.relay_setup_step_2_of_2),
            style = OriveoTheme.typography.caption,
            color = colors.primary,
        )
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(tint.copy(alpha = 0.12f))
                .padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = meta.systemIcon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = stringResource(meta.titleRes),
                style = OriveoTheme.typography.caption,
                color = tint,
            )
        }
        Text(
            text = stringResource(R.string.relay_setup_page_title),
            style = OriveoTheme.typography.title1,
            color = colors.textPrimary,
        )
        Text(
            text = stringResource(meta.subtitleRes),
            style = OriveoTheme.typography.body,
            color = colors.textSecondary,
        )
    }
}

@Composable
private fun RelayCustomAdvancedSection(viewModel: RelaySetupViewModel) {
    val spacing = OriveoTheme.spacing

    OriveoCard {
        Column {
            OriveoSectionHeader(title = stringResource(R.string.relay_advanced_title))
            Spacer(modifier = Modifier.height(spacing.lg))
            RelayEnumDropdown(
                title = stringResource(R.string.relay_advanced_transport),
                value = viewModel.customTransport,
                values = RelayTransport.entries,
                label = { relayTransportLabel(it) },
                onSelect = { newTransport ->
                    viewModel.customTransport = newTransport
                    
                    if (newTransport != RelayTransport.OpenAIResponses) {
                        viewModel.customWebSearchToolName = null
                    }
                },
            )
            Spacer(modifier = Modifier.height(spacing.md))
            RelayEnumDropdown(
                title = stringResource(R.string.relay_advanced_auth_mode),
                value = viewModel.customAuthMode,
                values = RelayAuthMode.entries,
                label = { relayAuthModeLabel(it) },
                onSelect = { viewModel.customAuthMode = it },
            )
            Spacer(modifier = Modifier.height(spacing.md))
            RelayEnumDropdown(
                title = stringResource(R.string.relay_advanced_reasoning_effort),
                value = viewModel.customReasoningEffort,
                values = RelayReasoningEffort.entries,
                label = { relayReasoningLabel(it) },
                onSelect = { viewModel.customReasoningEffort = it },
            )
            Spacer(modifier = Modifier.height(spacing.md))
            OutlinedTextField(
                value = viewModel.customServiceTier,
                onValueChange = { viewModel.customServiceTier = it },
                label = { Text(stringResource(R.string.relay_advanced_service_tier)) },
                placeholder = { Text(stringResource(R.string.relay_advanced_service_tier_placeholder)) },
                singleLine = true,
                enabled = !viewModel.isSubmitting,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(spacing.md))
            RelaySwitchRow(
                title = stringResource(R.string.relay_advanced_stream),
                checked = viewModel.customStream,
                enabled = !viewModel.isSubmitting,
                onCheckedChange = { viewModel.customStream = it },
            )
            RelaySwitchRow(
                title = stringResource(R.string.relay_advanced_disable_response_storage),
                checked = viewModel.customDisableResponseStorage,
                enabled = !viewModel.isSubmitting,
                onCheckedChange = { viewModel.customDisableResponseStorage = it },
            )
            
            if (viewModel.customTransport == RelayTransport.OpenAIResponses) {
                Spacer(modifier = Modifier.height(spacing.md))
                val current = viewModel.customWebSearchToolName ?: RelayWebSearchToolName.WebSearch
                RelayEnumDropdown(
                    title = stringResource(R.string.relay_advanced_web_search_tool_name),
                    value = current,
                    values = RelayWebSearchToolName.entries,
                    label = { relayWebSearchToolNameLabel(it) },
                    onSelect = { viewModel.customWebSearchToolName = it },
                )
                
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xs))
                val hintRes = when (current) {
                    RelayWebSearchToolName.WebSearch -> R.string.relay_web_search_tool_hint_default
                    RelayWebSearchToolName.WebSearchPreview -> R.string.relay_web_search_tool_hint_legacy
                    RelayWebSearchToolName.Disabled -> R.string.relay_web_search_tool_hint_disabled
                }
                Text(
                    text = stringResource(hintRes),
                    style = OriveoTheme.typography.caption,
                    color = if (current == RelayWebSearchToolName.Disabled)
                        OriveoTheme.colors.warning
                    else
                        OriveoTheme.colors.textTertiary,
                )
            }

            
            Spacer(modifier = Modifier.height(spacing.md))
            RelaySwitchRow(
                title = stringResource(R.string.relay_advanced_has_web_search),
                checked = viewModel.customHasWebSearch,
                enabled = !viewModel.isSubmitting,
                onCheckedChange = { enabled ->
                    viewModel.customHasWebSearch = enabled
                    if (!enabled) viewModel.customWebSearchProfile = null
                },
            )
            if (viewModel.customHasWebSearch) {
                Spacer(modifier = Modifier.height(spacing.sm))
                RelayProfileDropdown(
                    title = stringResource(R.string.relay_advanced_web_search_profile),
                    value = viewModel.customWebSearchProfile,
                    options = RELAY_WEB_SEARCH_PROFILES,
                    onSelect = { viewModel.customWebSearchProfile = it },
                )
            }
            Spacer(modifier = Modifier.height(spacing.md))
            RelayProfileDropdown(
                title = stringResource(R.string.relay_advanced_transport_kind),
                value = viewModel.customTransportKindOverride,
                options = RELAY_TRANSPORT_KINDS,
                onSelect = { viewModel.customTransportKindOverride = it },
                allowNull = true,
            )
        }
    }

    Spacer(modifier = Modifier.height(spacing.lg))

    OriveoCard {
        Column {
            OriveoSectionHeader(title = stringResource(R.string.relay_advanced_headers))
            Spacer(modifier = Modifier.height(spacing.lg))
            OutlinedTextField(
                value = viewModel.customUserAgent,
                onValueChange = { viewModel.customUserAgent = it },
                label = { Text(stringResource(R.string.relay_advanced_user_agent)) },
                singleLine = true,
                enabled = !viewModel.isSubmitting,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(spacing.lg))
            RelayKeyValueEditor(
                rows = viewModel.customHeaders,
                onRowsChange = { viewModel.customHeaders = it },
                enabled = !viewModel.isSubmitting,
            )
        }
    }

    Spacer(modifier = Modifier.height(spacing.lg))

    OriveoCard {
        Column {
            OriveoSectionHeader(title = stringResource(R.string.relay_advanced_query_params))
            Spacer(modifier = Modifier.height(spacing.lg))
            RelayKeyValueEditor(
                rows = viewModel.customQueryParams,
                onRowsChange = { viewModel.customQueryParams = it },
                enabled = !viewModel.isSubmitting,
            )
        }
    }
}

@Composable
private fun <T> RelayEnumDropdown(
    title: String,
    value: T,
    values: List<T>,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val colors = OriveoTheme.colors

    Column {
        Text(
            text = title,
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
        )
        Spacer(modifier = Modifier.height(OriveoTheme.spacing.xs))
        Box {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OriveoTheme.radius.md))
                    .border(OriveoBorderWidth.standard, colors.border, RoundedCornerShape(OriveoTheme.radius.md))
                    .clickable { expanded = true }
                    .padding(horizontal = OriveoTheme.spacing.md, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                Text(
                    text = label(value),
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = colors.textTertiary,
                )
            }
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
            ) {
                values.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(label(option)) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun RelaySwitchRow(
    title: String,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.body,
            color = OriveoTheme.colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onCheckedChange,
        )
    }
}

@Composable
private fun RelayKeyValueEditor(
    rows: List<RelayKeyValue>,
    onRowsChange: (List<RelayKeyValue>) -> Unit,
    enabled: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
        rows.forEachIndexed { index, row ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = row.key,
                    onValueChange = { value ->
                        onRowsChange(rows.toMutableList().also { it[index] = row.copy(key = value) })
                    },
                    label = { Text(stringResource(R.string.relay_key_label)) },
                    singleLine = true,
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = row.value,
                    onValueChange = { value ->
                        onRowsChange(rows.toMutableList().also { it[index] = row.copy(value = value) })
                    },
                    label = { Text(stringResource(R.string.relay_value_label)) },
                    singleLine = true,
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = { onRowsChange(rows.toMutableList().also { it.removeAt(index) }) },
                    enabled = enabled,
                ) {
                    Icon(
                        imageVector = Icons.Filled.RemoveCircle,
                        contentDescription = stringResource(R.string.remove),
                        tint = OriveoTheme.colors.warning,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
        OriveoSecondaryButton(
            text = stringResource(R.string.add),
            onClick = { onRowsChange(rows + RelayKeyValue("", "")) },
            enabled = enabled,
        )
    }
}

@Composable
private fun relayTransportLabel(value: RelayTransport): String = stringResource(
    when (value) {
        RelayTransport.Auto -> R.string.relay_transport_auto
        RelayTransport.OpenAIResponses -> R.string.relay_transport_openai_responses
        RelayTransport.OpenAIChatCompletions -> R.string.relay_transport_openai_chat_completions
        RelayTransport.LlamaCppNative -> R.string.relay_transport_llamacpp_native
        RelayTransport.AnthropicMessages -> R.string.relay_transport_anthropic_messages
        RelayTransport.GeminiGenerateContent -> R.string.relay_transport_gemini_generate_content
    },
)

@Composable
private fun relayAuthModeLabel(value: RelayAuthMode): String = stringResource(
    when (value) {
        RelayAuthMode.Auto -> R.string.relay_auth_auto
        RelayAuthMode.None -> R.string.relay_auth_none
        RelayAuthMode.Bearer -> R.string.relay_auth_bearer
        RelayAuthMode.XApiKey -> R.string.relay_auth_x_api_key
        RelayAuthMode.XGoogApiKey -> R.string.relay_auth_x_goog_api_key
        RelayAuthMode.QueryKey -> R.string.relay_auth_query_key
    },
)

@Composable
private fun relayReasoningLabel(value: RelayReasoningEffort): String = stringResource(
    when (value) {
        RelayReasoningEffort.Automatic -> R.string.relay_reasoning_automatic
        RelayReasoningEffort.Low -> R.string.relay_reasoning_low
        RelayReasoningEffort.Medium -> R.string.relay_reasoning_medium
        RelayReasoningEffort.High -> R.string.relay_reasoning_high
        RelayReasoningEffort.XHigh -> R.string.relay_reasoning_xhigh
    },
)

@Composable
private fun relayWebSearchToolNameLabel(value: RelayWebSearchToolName): String = when (value) {
    RelayWebSearchToolName.WebSearch -> "web_search"
    RelayWebSearchToolName.WebSearchPreview -> "web_search_preview"
    RelayWebSearchToolName.Disabled -> stringResource(R.string.relay_web_search_tool_disabled)
}


private val RELAY_WEB_SEARCH_PROFILES = listOf(
    "oai_responses_web",
    "oai_web_tool",
    "ant_web_tool",
    "gem_web",
    "gem_web_retrieval",
    "grok_responses_web",
    "qwen_web",
    "zhipu_web",
    "or_web",
    "kimi_web_search",
)

private val RELAY_TRANSPORT_KINDS = listOf(
    "openai_chat",
    "openai_responses",
    "anthropic_messages",
    "gemini_generate",
    "dashscope_native",
    "openai_images",
    "gemini_image",
    "qwen_image",
    "grok_image",
    "zhipu_image",
)

@Composable
private fun RelayProfileDropdown(
    title: String,
    value: String?,
    options: List<String>,
    onSelect: (String?) -> Unit,
    allowNull: Boolean = false,
) {
    var expanded by remember { mutableStateOf(false) }
    val colors = OriveoTheme.colors
    val displayValue = value
        ?: if (allowNull) stringResource(R.string.relay_profile_auto) else stringResource(R.string.relay_profile_unset)

    Column {
        Text(
            text = title,
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
        )
        Spacer(modifier = Modifier.height(OriveoTheme.spacing.xs))
        Box {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OriveoTheme.radius.md))
                    .border(OriveoBorderWidth.standard, colors.border, RoundedCornerShape(OriveoTheme.radius.md))
                    .clickable { expanded = true }
                    .padding(horizontal = OriveoTheme.spacing.md, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                Text(
                    text = displayValue,
                    style = OriveoTheme.typography.body,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = colors.textTertiary,
                )
            }
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
            ) {
                if (allowNull) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.relay_profile_auto)) },
                        onClick = {
                            onSelect(null)
                            expanded = false
                        },
                    )
                }
                options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}
