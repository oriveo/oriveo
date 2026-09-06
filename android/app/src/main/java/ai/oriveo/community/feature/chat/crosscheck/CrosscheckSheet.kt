package ai.oriveo.community.feature.chat.crosscheck

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import ai.oriveo.community.feature.modelpicker.ModelPickerContext
import ai.oriveo.community.feature.modelpicker.ModelPickerSheet
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.theme.OriveoNotesBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CrosscheckSheet(
    originalAnswer: String,
    providers: List<Provider>,
    options: List<CrosscheckOption>,
    state: CrosscheckState,
    onRun: (CrosscheckOption) -> Unit,
    onSave: (CrosscheckOption) -> Unit,
    onEnableModel: (providerId: String, modelId: String) -> Unit,
    onDismiss: () -> Unit,
    sourceProviderKind: ProviderKind? = null,
    sourceProviderName: String? = null,
    sourceModelName: String? = null,
    sourceRelayKind: RelayKind? = null,
) {
    val colors = OriveoTheme.colors
    val pickerSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf(CrosscheckCoordinator.defaultOption(options)) }
    var executed by remember { mutableStateOf<CrosscheckOption?>(null) }
    var showModelPicker by remember { mutableStateOf(false) }
    var showOriginalAnswer by remember { mutableStateOf(false) }
    val visibleOptions = remember(options) { CrosscheckCoordinator.visibleOptions(options) }
    val pickerProviders = remember(providers, visibleOptions) {
        CrosscheckCoordinator.pickerProviders(
            providers = providers,
            visibleOptions = visibleOptions,
        )
    }

    val displayState = if (executed == null) CrosscheckState() else state
    val resultState = CrosscheckSheetPresentation.resultState(displayState)
    val canRun = CrosscheckSheetPresentation.canRun(
        isStreaming = state.isStreaming,
        hasSelectedModel = selected != null,
    )
    val canSave = executed != null && CrosscheckSheetPresentation.canSave(displayState)

    LaunchedEffect(options) {
        selected = CrosscheckCoordinator.visibleOptionOrDefault(options, selected)
    }

    BackHandler {
        if (showModelPicker) {
            showModelPicker = false
        } else {
            onDismiss()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.backgroundBase),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize(),
        ) {
            OriveoNotesBackground()

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            colorStops = arrayOf(
                                0.0f to Color.White.copy(alpha = if (OriveoTheme.isDark) 0.025f else 0.30f),
                                0.5f to Color.Transparent,
                            )
                        )
                    ),
            )
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
                contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 22.dp, bottom = 126.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                item("header") {
                    CrosscheckHeader(
                        selected = selected,
                        sourceProviderKind = sourceProviderKind,
                        sourceProviderName = sourceProviderName,
                        sourceModelName = sourceModelName,
                        sourceRelayKind = sourceRelayKind,
                        onOpenPicker = { if (!state.isStreaming && visibleOptions.isNotEmpty()) showModelPicker = true },
                    )
                }

                if (displayState.error != null) {
                    item("error") {
                        ErrorBanner(message = displayState.error)
                    }
                }

                item("result") {
                    SecondOpinionStage(
                        selected = selected,
                        executed = executed,
                        state = displayState,
                        resultState = resultState,
                    )
                }

                item("original") {
                    OriginalSourceStrip(
                        originalAnswer = originalAnswer,
                        expanded = showOriginalAnswer,
                        onToggle = { showOriginalAnswer = !showOriginalAnswer },
                        sourceProviderKind = sourceProviderKind,
                        sourceRelayKind = sourceRelayKind,
                    )
                }
            }

            CloseButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(top = 10.dp, end = 10.dp),
            )

            CommandDock(
                canRun = canRun,
                canSave = canSave,
                isRunning = state.isStreaming,
                hasResult = resultState == CrosscheckResultState.Result,
                onRun = {
                    selected?.let { option ->
                        executed = option
                        onRun(option)
                    }
                },
                onSave = {
                    executed?.let(onSave)
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }

    if (showModelPicker) {
        ModalBottomSheet(
            onDismissRequest = { showModelPicker = false },
            sheetState = pickerSheetState,
            dragHandle = null,
            contentWindowInsets = { WindowInsets(0) },
            containerColor = colors.backgroundBase,
        ) {
            ModelPickerSheet(
                context = ModelPickerContext.Crosscheck,
                providers = pickerProviders,
                activeProviderId = selected?.provider?.id,
                activeModelId = selected?.model?.id,
                onModelSelected = { providerId, modelId ->
                    val option = visibleOptions.firstOrNull { candidate ->
                        candidate.provider.id == providerId && candidate.model.id == modelId
                    } ?: return@ModelPickerSheet
                    if (option.provider.id != selected?.provider?.id || option.model.id != selected?.model?.id) {
                        executed = null
                    }
                    selected = option
                    showModelPicker = false
                },
                onEnableModel = onEnableModel,
                onDismiss = { showModelPicker = false },
            )
        }
    }
}

@Composable
private fun CrosscheckHeader(
    selected: CrosscheckOption?,
    sourceProviderKind: ProviderKind?,
    sourceProviderName: String?,
    sourceModelName: String?,
    sourceRelayKind: RelayKind?,
    onOpenPicker: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 12.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Column(
            modifier = Modifier.padding(end = 52.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                CrosscheckHeroIcon()
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.notes_crosscheck_title),
                        style = OriveoTheme.typography.title1.copy(
                            fontSize = 26.sp,
                            lineHeight = 32.sp,
                            fontWeight = FontWeight.SemiBold,
                        ),
                        color = colors.textPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = stringResource(R.string.notes_crosscheck_subtitle),
                        style = OriveoTheme.typography.body.copy(fontSize = 14.sp, lineHeight = 20.sp),
                        color = colors.textSecondary,
                    )
                }
            }
        }
        ModelComparisonRail(
            selected = selected,
            sourceProviderKind = sourceProviderKind,
            sourceProviderName = sourceProviderName,
            sourceModelName = sourceModelName,
            sourceRelayKind = sourceRelayKind,
            onOpenPicker = onOpenPicker,
        )
    }
}

@Composable
private fun CrosscheckHeroIcon() {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(colors.primary.copy(alpha = if (OriveoTheme.isDark) 0.18f else 0.11f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.AutoAwesome,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.primary,
        )
    }
}

@Composable
private fun ModelComparisonRail(
    selected: CrosscheckOption?,
    sourceProviderKind: ProviderKind?,
    sourceProviderName: String?,
    sourceModelName: String?,
    sourceRelayKind: RelayKind?,
    onOpenPicker: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
    ) {
        CrosscheckRailHairline()
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 13.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ModelRailBlock(
                label = stringResource(R.string.notes_sort_source_model),
                modelName = sourceModelName?.takeIf { it.isNotBlank() }
                    ?: stringResource(R.string.notes_crosscheck_original),
                providerName = sourceProviderName,
                providerKind = sourceProviderKind,
                relayKind = sourceRelayKind,
                enabled = false,
                modifier = Modifier.weight(1f),
            )

            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                contentDescription = null,
                tint = colors.textTertiary.opacity(if (OriveoTheme.isDark) 0.70f else 0.58f),
                modifier = Modifier.size(14.dp),
            )
            ModelRailBlock(
                label = stringResource(R.string.notes_crosscheck_model),
                modelName = selected?.model?.name ?: "—",
                providerName = selected?.provider?.displayName,
                providerKind = selected?.provider?.let(::resolveProviderLogoKind),
                relayKind = selected?.provider?.resolvedRelayKind(),
                enabled = selected != null,

                modelNameSize = 15.sp,
                onClick = onOpenPicker,
                modifier = Modifier.weight(1f),
            )
        }
        CrosscheckRailHairline()
    }
}

@Composable
private fun CrosscheckRailHairline() {
    val colors = OriveoTheme.colors

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(colors.border.opacity(if (OriveoTheme.isDark) 0.24f else 0.14f)),
    )
}

@Composable
private fun ModelRailBlock(
    label: String,
    modelName: String,
    providerName: String?,
    providerKind: ProviderKind?,
    relayKind: RelayKind?,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    modelNameSize: TextUnit = 14.sp,
    onClick: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val clickModifier = if (onClick != null) {
        Modifier.clickable(enabled = enabled, onClick = onClick)
    } else {
        Modifier
    }
    Row(
        modifier = modifier
            .then(clickModifier)
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (providerKind != null) {
            ProviderBadgeIcon(kind = providerKind, relayKind = relayKind, size = 28.dp)
        } else {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(colors.surfaceElevated),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Key,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.textTertiary,
                )
            }
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                text = label,
                style = OriveoTheme.typography.footnote.copy(
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                ),
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = modelName,
                style = OriveoTheme.typography.body.copy(
                    fontSize = modelNameSize,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = if (enabled) colors.textPrimary else colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            if (!providerName.isNullOrBlank()) {
                Text(
                    text = providerName,
                    style = OriveoTheme.typography.footnote.copy(fontSize = 10.sp),
                    color = colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (onClick != null) {

            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
private fun ErrorBanner(message: String) {
    val colors = OriveoTheme.colors
    Text(
        text = message,
        style = OriveoTheme.typography.caption,
        color = colors.danger,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.dangerSoft)
            .border(1.dp, colors.danger.copy(alpha = 0.16f), RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    )
}

@Composable
private fun SecondOpinionStage(
    selected: CrosscheckOption?,
    executed: CrosscheckOption?,
    state: CrosscheckState,
    resultState: CrosscheckResultState,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            SecondOpinionTitle(modifier = Modifier.weight(1f))
            executed?.let { ModelMicroChip(option = it) }
        }

        val isDark = OriveoTheme.isDark
        val showsCanvas = resultState != CrosscheckResultState.Empty
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = if (resultState == CrosscheckResultState.Empty) 264.dp else 188.dp)

                .drawWithContent {
                    drawContent()
                    val lineH = 1.dp.toPx()
                    drawLine(
                        color = Color.White.copy(alpha = if (isDark) 0.04f else 0.42f),
                        start = Offset(4.dp.toPx(), lineH / 2f),
                        end = Offset(size.width - 4.dp.toPx(), lineH / 2f),
                        strokeWidth = lineH,
                    )
                }
                .shadow(16.dp, RoundedCornerShape(30.dp), ambientColor = colors.primary.copy(alpha = 0.06f), spotColor = colors.primary.copy(alpha = 0.06f))
                .clip(RoundedCornerShape(30.dp))

                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            colors.surfaceElevated.opacity(if (isDark) 0.92f else 0.98f),
                            colors.primary.copy(alpha = if (isDark) 0.045f else 0.024f),
                            colors.surface.opacity(if (isDark) 0.88f else 0.96f),
                        )
                    )
                )

                .border(0.5.dp, colors.border.opacity(if (showsCanvas) 0.10f else 0.16f), RoundedCornerShape(30.dp)),
        ) {
            when (resultState) {
                CrosscheckResultState.Empty -> EmptyResultContent(selected = selected)
                CrosscheckResultState.Running -> RunningResultContent(selected = executed ?: selected, state = state)
                CrosscheckResultState.Result -> ResultContent(text = state.text)
            }
        }
    }
}

@Composable
private fun ResultContent(
    text: String,
    modifier: Modifier = Modifier
        .fillMaxWidth()
        .padding(21.dp),
    isStreaming: Boolean = false,
) {
    MarkdownMessageView(
        text = text,
        modifier = modifier,
        isStreaming = isStreaming,
    )
}

@Composable
private fun SecondOpinionTitle(modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(colors.primary.copy(alpha = if (OriveoTheme.isDark) 0.18f else 0.11f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = colors.primary,
            )
        }
        Text(
            text = stringResource(R.string.notes_crosscheck_second_opinion),
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun EmptyResultContent(selected: CrosscheckOption?) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 264.dp)
            .padding(horizontal = 30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (selected != null) {
            Box(
                modifier = Modifier.size(70.dp),
                contentAlignment = Alignment.Center,
            ) {
                ProviderBadgeIcon(
                    kind = resolveProviderLogoKind(selected.provider),
                    relayKind = selected.provider.resolvedRelayKind(),
                    size = 49.dp,
                )
            }
        } else {
            Box(
                modifier = Modifier
                    .size(70.dp)
                    .clip(CircleShape)
                    .background(colors.surface.opacity(if (isDark) 0.82f else 0.96f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Key,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
        Spacer(modifier = Modifier.height(18.dp))
        Text(
            text = if (selected == null) {
                stringResource(R.string.notes_crosscheck_no_models)
            } else {
                stringResource(R.string.notes_crosscheck_empty)
            },
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun RunningResultContent(selected: CrosscheckOption?, state: CrosscheckState) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(21.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                color = colors.primary,
                strokeWidth = 2.dp,
            )
            Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.notes_crosscheck_running),
                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Bold),
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                selected?.let {
                    Text(
                        text = it.model.name,
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                    )
                }
            }
        }
        if (state.text.isNotBlank()) {
            ResultContent(
                text = state.text,
                modifier = Modifier.fillMaxWidth(),
                isStreaming = true,
            )
        }
    }
}

@Composable
private fun ModelMicroChip(option: CrosscheckOption) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val providerKind = resolveProviderLogoKind(option.provider)

    val brandBg = ai.oriveo.community.ui.theme.ProviderBadgeColors.forProvider(providerKind).background
        .copy(alpha = if (isDark) 0.72f else 0.92f)
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(brandBg)
            .padding(start = 7.dp, end = 10.dp, top = 5.dp, bottom = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderBadgeIcon(
            kind = resolveProviderLogoKind(option.provider),
            relayKind = option.provider.resolvedRelayKind(),
            size = 16.dp,
        )
        Text(
            text = option.model.name,
            style = OriveoTheme.typography.footnote.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
            modifier = Modifier.widthIn(max = 132.dp),
        )
    }
}

@Composable
private fun OriginalSourceStrip(
    originalAnswer: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    sourceProviderKind: ProviderKind? = null,
    sourceRelayKind: RelayKind? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val chevronRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "chevronRotation",
    )

    val preview = remember(originalAnswer) {
        originalAnswer
            .split('\n')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .let { if (it.length > 220) it.take(220).trimEnd() + "…" else it }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(0.dp),
    ) {

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(0.5.dp)
                .background(colors.border.opacity(if (isDark) 0.24f else 0.14f)),
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggle)
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (sourceProviderKind != null) {
                Box(modifier = Modifier.size(34.dp), contentAlignment = Alignment.Center) {
                    ProviderBadgeIcon(kind = sourceProviderKind, relayKind = sourceRelayKind, size = 28.dp)
                }
            } else {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(CircleShape)
                        .background(colors.surfaceElevated.opacity(0.80f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = colors.textTertiary,
                    )
                }
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(
                    text = stringResource(R.string.notes_crosscheck_original),
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Bold),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = preview,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier
                    .size(14.dp)
                    .rotate(chevronRotation),
            )
        }

        if (expanded) {
            MarkdownMessageView(
                text = originalAnswer.trim(),
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(colors.surfaceElevated.opacity(if (isDark) 0.70f else 0.64f))
                    .padding(16.dp),
            )
        }
    }
}

@Composable
private fun CloseButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            .size(44.dp)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = stringResource(R.string.notes_crosscheck_close),
            modifier = Modifier.size(19.dp),
            tint = colors.textSecondary,
        )
    }
}

@Composable
private fun CommandDock(
    canRun: Boolean,
    canSave: Boolean,
    isRunning: Boolean,
    hasResult: Boolean,
    onRun: () -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {

    Box(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 18.dp, end = 18.dp, top = 10.dp, bottom = 12.dp),
    ) {

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (hasResult) {
                IconCircleButton(
                    imageVector = Icons.Filled.Refresh,
                    enabled = canRun,
                    onClick = onRun,
                )
                CrosscheckDockHeroButton(
                    title = stringResource(R.string.notes_crosscheck_save),
                    icon = Icons.AutoMirrored.Outlined.NoteAdd,
                    enabled = canSave,
                    loading = false,
                    onClick = onSave,
                    modifier = Modifier.weight(1f),
                )
            } else {
                CrosscheckDockHeroButton(
                    title = stringResource(if (isRunning) R.string.notes_crosscheck_running else R.string.notes_crosscheck_run),

                    icon = Icons.Filled.Verified,
                    enabled = canRun,
                    loading = isRunning,
                    onClick = onRun,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun IconCircleButton(
    imageVector: androidx.compose.ui.graphics.vector.ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val alpha by animateFloatAsState(if (enabled) 1f else 0.5f, label = "iconBtnAlpha")
    val background by animateColorAsState(
        targetValue = if (pressed) colors.surfaceInset else colors.surfaceElevated,
        animationSpec = tween(120),
        label = "iconBtnBg",
    )
    Box(
        modifier = Modifier
            .size(48.dp)
            .alpha(alpha)

            .shadow(8.dp, CircleShape, ambientColor = colors.shadow.copy(alpha = 0.14f), spotColor = colors.shadow.copy(alpha = 0.14f))
            .clip(CircleShape)
            .background(background, CircleShape)
            .border(0.7.dp, colors.border.opacity(0.18f), CircleShape)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(imageVector = imageVector, contentDescription = null, modifier = Modifier.size(18.dp), tint = colors.textSecondary)
    }
}

@Composable
private fun CrosscheckDockHeroButton(
    title: String,
    icon: ImageVector,
    enabled: Boolean,
    loading: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.985f else 1f, label = "heroScale")
    val pillShape = RoundedCornerShape(percent = 50)
    val interactive = enabled && !loading
    Row(
        modifier = modifier
            .height(54.dp)
            .scale(scale)

            .alpha(if (pressed && interactive) 0.90f else 1f)
            .shadow(
                elevation = if (enabled) 12.dp else 0.dp,
                shape = pillShape,
                ambientColor = colors.primary.copy(alpha = 0.18f),
                spotColor = colors.primary.copy(alpha = 0.18f),
            )
            .clip(pillShape)

            .background(
                brush = if (enabled) {
                    Brush.linearGradient(
                        colors = listOf(colors.primary, colors.primaryPressed),
                        start = Offset.Zero,
                        end = Offset.Infinite,
                    )
                } else {
                    Brush.linearGradient(listOf(colors.surfaceInset, colors.surfaceElevated))
                },
            )
            .border(0.7.dp, Color.White.copy(alpha = if (enabled) 0.12f else 0.06f), pillShape)
            .clickable(
                enabled = interactive,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,

            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Bold),
            color = if (enabled) Color.White else colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Spacer(modifier = Modifier.width(8.dp))
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else {

            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = if (enabled) Color.White else colors.textTertiary,
            )
        }
    }
}

@Composable
private fun Provider.resolvedRelayKind(): RelayKind? {
    val resolvedKind = resolveProviderLogoKind(this)
    return if (kind == ProviderKind.Relay && resolvedKind == ProviderKind.Relay) relayKind else null
}
