package ai.oriveo.community.feature.settings

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryScreen(
    onNavigateBack: () -> Unit = {},
    onNavigateToInbox: () -> Unit = {},
    viewModel: MemoryViewModel = koinViewModel(),
    inboxViewModel: MemoryInboxViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    // Opening the memory settings page clears the new-feature red dot on the Settings "Memory" row (counts from any entry path).
    LaunchedEffect(Unit) { viewModel.markMemoryFeatureBadgeSeen() }
    val inboxState by inboxViewModel.state.collectAsStateWithLifecycle()
    // Pending count is re-read whenever the page comes back (e.g. from the inbox).
    LifecycleResumeEffect(inboxViewModel) {
        inboxViewModel.refresh()
        onPauseOrDispose { }
    }
    val hasRecentConversations by viewModel.hasRecentConversations.collectAsStateWithLifecycle()
    val items by viewModel.items.collectAsStateWithLifecycle()
    val folderNames by viewModel.folderNames.collectAsStateWithLifecycle()
    val listPresentation = remember(items, viewModel.deviceId, folderNames) {
        buildMemoryItemListPresentation(items, viewModel.deviceId, folderNames)
    }
    val presentation = buildMemoryScreenPresentation(
        hasItems = !listPresentation.isEmpty,
        hasRecentConversations = hasRecentConversations,
    )
    // Android's equivalent of "reduce motion" is ANIMATOR_DURATION_SCALE == 0, and
    // isReduceMotionEnabled (process-level cache + ContentObserver) is this repository's single read point for it.
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    var pageAppeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { pageAppeared = true }
    val pageAlpha by animateFloatAsState(
        targetValue = if (pageAppeared) 1f else 0f,
        animationSpec = if (reduceMotion) tween(0) else tween(360),
        label = "pageAlpha",
    )
    val pageOffsetY by animateDpAsState(
        targetValue = if (pageAppeared) 0.dp else 6.dp,
        animationSpec = if (reduceMotion) tween(0) else tween(420),
        label = "pageOffsetY",
    )

    val listActions = remember(viewModel) {
        MemoryItemListActions(
            onAdd = { group -> viewModel.openNewEditor(group) },
            onEdit = viewModel::openEditor,
            onTogglePin = viewModel::togglePinned,
            onTogglePause = viewModel::togglePaused,
            onDelete = viewModel::requestDelete,
            onKeepConflict = viewModel::keepConflict,
            onAddEpisodic = viewModel::openNewEpisodicEditor,
            onResolveL3Conflict = viewModel::resolveL3Conflict,
            onOrganize = viewModel::organize,
            onRawView = viewModel::openRawView,
        )
    }

    viewModel.rawView?.let { state ->
        MemoryRawScreen(
            state = state,
            onTextChange = viewModel::updateRawText,
            onSave = viewModel::saveRawView,
            onCancel = viewModel::dismissRawView,
        )
        return
    }

    val isStarter = presentation.mode == MemoryScreenMode.Starter
    Box(modifier = Modifier.fillMaxSize()) {
        MemoryAtlasBackground(atlasHeight = if (isStarter) 420.dp else 360.dp)

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {},
                    navigationIcon = {
                        OriveoBackButton(onClick = onNavigateBack)
                    },
                    actions = {
                        if (!isStarter) {
                            listActions.onRawView?.let { onRawView ->
                                TextButton(onClick = onRawView) {
                                    Text(
                                        text = stringResource(R.string.memory_raw_view),
                                        style = memoryText(17f, 22f),
                                        color = colors.primaryTextSafe,
                                    )
                                }
                            }
                            MemoryIconButton(
                                icon = MemoryGlyphs.Plus,
                                contentDescription = stringResource(R.string.memory_add_item),
                                onClick = { listActions.onAdd(MemoryItemGroup.About) },
                                tint = colors.primaryTextSafe,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.TopCenter,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = 600.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 56.dp)
                        .alpha(pageAlpha)
                        .offset(y = pageOffsetY),
                ) {
                    MemoryPageHeader(presentation)

                    if (isStarter) {
                        MemoryConstellation(modifier = Modifier.padding(top = 8.dp))
                        MemoryStarterCard(
                            presentation = presentation,
                            isGeneratingDraft = viewModel.isGeneratingDraft,
                            onAction = { action -> runMemoryAction(action, viewModel) },
                            modifier = Modifier.padding(top = 14.dp),
                        )
                        MemoryInboxEntry(inboxState, onNavigateToInbox, Modifier.padding(top = 12.dp))
                        // The starter board carries the privacy note too; showsSupportSections keeps its meaning.
                        MemoryFootnote(
                            icon = MemoryGlyphs.Shield,
                            text = stringResource(R.string.memory_privacy_warning),
                            size = 12.5f,
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    } else {
                        MemorySpectrum(listPresentation, Modifier.padding(top = 20.dp))
                        MemoryInboxEntry(inboxState, onNavigateToInbox, Modifier.padding(top = 24.dp))
                        MemoryItemListContent(presentation = listPresentation, actions = listActions)
                        if (presentation.primaryAction == MemoryScreenAction.GenerateDraft) {
                            MemoryDraftCard(
                                loading = viewModel.isGeneratingDraft,
                                onClick = { runMemoryAction(MemoryScreenAction.GenerateDraft, viewModel) },
                                modifier = Modifier.padding(top = 32.dp),
                            )
                        }
                    }

                    if (presentation.showsSupportSections) {
                        MemoryFootnote(
                            icon = MemoryGlyphs.Shield,
                            text = stringResource(R.string.memory_privacy_warning),
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    }
                }
            }
        }
    }

    viewModel.editor?.let { state ->
        MemoryItemEditorSheet(
            state = state,
            onGroupChange = viewModel::updateEditorGroup,
            onTextChange = viewModel::updateEditorText,
            onEpisodicKindChange = viewModel::updateEditorEpisodicKind,
            onDateChange = viewModel::updateEditorDate,
            onSave = viewModel::saveEditor,
            onDismiss = viewModel::dismissEditor,
        )
    }

    viewModel.organize?.let { state ->
        MemoryOrganizeSheet(
            state = state,
            onToggle = viewModel::toggleOrganizeSelection,
            onKeepOriginalChange = viewModel::setOrganizeKeepOriginal,
            onSave = viewModel::saveOrganized,
            onDismiss = viewModel::dismissOrganize,
        )
    }

    if (viewModel.pendingDelete != null) {
        AlertDialog(
            onDismissRequest = viewModel::cancelDelete,
            title = { Text(stringResource(R.string.memory_delete_confirm_title)) },
            text = { Text(stringResource(R.string.memory_delete_confirm_body)) },
            confirmButton = {
                TextButton(onClick = viewModel::confirmDelete) {
                    Text(stringResource(R.string.memory_action_delete), color = colors.error)
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::cancelDelete) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    if (viewModel.showDraftConflictDialog) {
        AlertDialog(
            onDismissRequest = viewModel::dismissPendingGeneratedDraft,
            title = { Text(stringResource(R.string.memory_draft_ready_title)) },
            text = { Text(stringResource(R.string.memory_draft_ready_message)) },
            confirmButton = {
                TextButton(onClick = viewModel::applyPendingGeneratedDraft) {
                    Text(stringResource(R.string.memory_draft_apply))
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::dismissPendingGeneratedDraft) {
                    Text(stringResource(android.R.string.cancel))
                }
            },
        )
    }

    viewModel.extractionDisclosure?.let { disclosure ->
        AlertDialog(
            onDismissRequest = viewModel::cancelExtraction,
            title = { Text(stringResource(disclosure.titleRes)) },
            text = {
                Text(
                    disclosure.bodyLines()
                        .map { line -> stringResource(line.resId, *line.args.toTypedArray()) }
                        .joinToString("\n"),
                )
            },
            confirmButton = {
                TextButton(onClick = viewModel::confirmExtraction) {
                    Text(stringResource(R.string.memory_extraction_send))
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::cancelExtraction) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    viewModel.draftError?.let { error ->
        AlertDialog(
            onDismissRequest = viewModel::dismissDraftError,
            title = { Text(stringResource(error.titleRes)) },
            text = {
                val message = when {
                    error.messageLiteral != null -> error.messageLiteral
                    error.messageRes != null -> stringResource(error.messageRes, *error.args.toTypedArray())
                    else -> ""
                }
                Text(message)
            },
            confirmButton = {
                TextButton(onClick = viewModel::dismissDraftError) {
                    Text(stringResource(android.R.string.ok))
                }
            },
        )
    }
}

private fun runMemoryAction(action: MemoryScreenAction, viewModel: MemoryViewModel) {
    when (action) {
        MemoryScreenAction.GenerateDraft -> viewModel.generateDraft()
        MemoryScreenAction.AddItem -> viewModel.openNewEditor()
    }
}

// ── Atlas background ──

/** Grouped page background with a 14dp dot grid fading out over [atlasHeight] (decoration only). */
@Composable
internal fun MemoryAtlasBackground(atlasHeight: Dp, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val dot = colors.memoryAtlasDot
    Box(modifier = modifier.fillMaxSize().background(colors.backgroundGrouped)) {
        Canvas(modifier = Modifier.fillMaxWidth().height(atlasHeight)) {
            val step = 14.dp.toPx()
            val radius = 1.dp.toPx()
            val rows = (size.height / step).toInt()
            val columns = (size.width / step).toInt() + 1
            for (row in 0..rows) {
                val y = step / 2f + row * step
                val fade = (1f - y / size.height).coerceIn(0f, 1f)
                if (fade <= 0f) continue
                val tint = dot.copy(alpha = dot.alpha * fade)
                for (column in 0..columns) {
                    drawCircle(tint, radius, Offset(step / 2f + column * step, y))
                }
            }
        }
    }
}

// ── Header ──

@Composable
private fun MemoryPageHeader(presentation: MemoryScreenPresentation) {
    val colors = OriveoTheme.colors
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = stringResource(R.string.memory_title),
                style = memoryText(34f, 41f, FontWeight.Bold).copy(letterSpacing = (-0.6).sp),
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (presentation.heroStyle == MemoryHeroStyle.ActiveMemory) MemoryReadyChip()
        }
        if (presentation.mode == MemoryScreenMode.Items) {
            Text(
                text = stringResource(R.string.memory_edit_description),
                style = memoryText(15f, 22f),
                color = colors.textSecondary,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun MemoryReadyChip() {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .height(26.dp)
            .background(memoryCardFill(), CircleShape)
            .border(1.dp, colors.border, CircleShape)
            .padding(start = 9.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(13.dp)
                .background(colors.success.copy(alpha = 0.22f), CircleShape)
                .padding(3.dp)
                .background(colors.success, CircleShape),
        )
        Text(
            text = stringResource(R.string.memory_hero_chip_ready),
            style = memoryText(12.5f, 16f, FontWeight.SemiBold),
            color = colors.textSecondary,
        )
    }
}

// ── Starter constellation ──

/** Star positions on the 358 × 196 board; x scales with the width, y is fixed. */
private val CONSTELLATION_STARS = listOf(78f to 34f, 282f to 28f, 296f to 132f, 190f to 178f, 68f to 150f)
private const val CONSTELLATION_WIDTH = 358f

@Composable
private fun MemoryConstellation(modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val line = memoryLineStrong()
    val faint = colors.border
    val core = colors.primary
    val stars: List<Triple<ImageVector, Color, String>> = MemoryItemGroup.entries.map { group ->
        Triple(group.glyph, memoryGroupHue(group), memoryItemGroupTitle(group))
    } + Triple(MemoryGlyphs.Episodic, colors.memoryHueEpisodic, stringResource(R.string.memory_group_episodic))
    BoxWithConstraints(modifier = modifier.fillMaxWidth().height(196.dp).clearAndSetSemantics {}) {
        val scale = constraints.maxWidth / CONSTELLATION_WIDTH
        Canvas(modifier = Modifier.fillMaxSize()) {
            val center = Offset(size.width / 2f, 98.dp.toPx())
            val dash = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 5.dp.toPx()))
            drawCircle(line, 54.dp.toPx(), center, style = Stroke(1.dp.toPx(), pathEffect = dash))
            drawCircle(faint, 90.dp.toPx(), center, style = Stroke(1.dp.toPx(), pathEffect = dash))
            CONSTELLATION_STARS.forEach { (x, y) ->
                drawLine(line, center, Offset(x * size.width / CONSTELLATION_WIDTH, y.dp.toPx()), 1.dp.toPx())
            }
            drawCircle(core.copy(alpha = 0.07f), 23.dp.toPx(), center)
            drawCircle(core.copy(alpha = 0.16f), 14.dp.toPx(), center)
            drawCircle(core, 7.dp.toPx(), center)
        }
        Layout(
            modifier = Modifier.fillMaxSize(),
            content = { stars.forEach { (glyph, hue, label) -> ConstellationStar(glyph, hue, label) } },
        ) { measurables, constraints ->
            val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
            layout(constraints.maxWidth, constraints.maxHeight) {
                placeables.forEachIndexed { index, placeable ->
                    val (x, y) = CONSTELLATION_STARS[index]
                    val left = (x * scale - placeable.width / 2f).roundToInt()
                        .coerceIn(0, (constraints.maxWidth - placeable.width).coerceAtLeast(0))
                    val top = (y.dp.toPx() - placeable.height / 2f).roundToInt()
                        .coerceIn(0, (constraints.maxHeight - placeable.height).coerceAtLeast(0))
                    placeable.place(left, top)
                }
            }
        }
    }
}

@Composable
private fun ConstellationStar(glyph: ImageVector, hue: Color, label: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .height(30.dp)
            .shadow(2.dp, CircleShape, ambientColor = colors.shadow, spotColor = colors.shadow)
            .background(memoryCardFill(), CircleShape)
            .border(1.dp, colors.border, CircleShape)
            .padding(start = 10.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(glyph, contentDescription = null, tint = hue, modifier = Modifier.size(14.dp))
        Text(text = label, style = memoryText(13f, 16f, FontWeight.Medium), color = colors.textPrimary, maxLines = 1)
    }
}

// ── Starter card ──

@Composable
private fun memoryActionLabel(action: MemoryScreenAction): String = when (action) {
    MemoryScreenAction.GenerateDraft -> stringResource(R.string.memory_generate_draft)
    MemoryScreenAction.AddItem -> stringResource(R.string.memory_add_item)
}

private fun memoryActionGlyph(action: MemoryScreenAction): ImageVector = when (action) {
    MemoryScreenAction.GenerateDraft -> MemoryGlyphs.Sparkle
    MemoryScreenAction.AddItem -> MemoryGlyphs.Plus
}

@Composable
private fun MemoryStarterCard(
    presentation: MemoryScreenPresentation,
    isGeneratingDraft: Boolean,
    onAction: (MemoryScreenAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .memoryCard(radius = 24.dp, outlined = true)
            .padding(start = 22.dp, end = 22.dp, top = 22.dp, bottom = 18.dp),
    ) {
        Text(
            text = stringResource(R.string.memory_empty_title),
            style = memoryText(22f, 30f, FontWeight.Bold).copy(letterSpacing = (-0.3).sp),
            color = colors.textPrimary,
        )
        Text(
            text = stringResource(R.string.memory_empty_description),
            style = memoryText(15f, 23f),
            color = colors.textSecondary,
            modifier = Modifier.padding(top = 8.dp),
        )
        Row(
            modifier = Modifier
                .padding(top = 16.dp)
                .fillMaxWidth()
                .background(colors.surfaceElevated, RoundedCornerShape(14.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Decorative open quote mark in front of the example.
            Text(
                text = "“",
                style = memoryText(26f, 22f, FontWeight.Bold).copy(fontFamily = FontFamily.Serif),
                color = colors.primary,
                modifier = Modifier.clearAndSetSemantics {},
            )
            Text(
                text = stringResource(R.string.memory_placeholder),
                style = memoryText(13.5f, 21f),
                color = colors.textSecondary,
                modifier = Modifier.weight(1f),
            )
        }
        presentation.primaryAction?.let { action ->
            val loading = isGeneratingDraft && action == MemoryScreenAction.GenerateDraft
            MemoryStarterPrimaryButton(
                label = memoryActionLabel(action),
                glyph = memoryActionGlyph(action),
                loading = loading,
                onClick = { onAction(action) },
                modifier = Modifier.padding(top = 18.dp),
            )
        }
        presentation.secondaryAction?.let { action ->
            Row(
                modifier = Modifier
                    .padding(top = 4.dp)
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { onAction(action) },
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(memoryActionGlyph(action), contentDescription = null, tint = colors.primaryTextSafe, modifier = Modifier.size(16.dp))
                Text(
                    text = memoryActionLabel(action),
                    style = memoryText(15f, 20f, FontWeight.SemiBold),
                    color = colors.primaryTextSafe,
                )
            }
        }
    }
}

@Composable
private fun MemoryStarterPrimaryButton(
    label: String,
    glyph: ImageVector,
    loading: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    val glow = colors.primary.copy(alpha = 0.28f)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .shadow(8.dp, shape, ambientColor = glow, spotColor = glow)
            .clip(shape)
            .background(colors.primaryTextSafe)
            .clickable(enabled = !loading, onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (loading) {
            CircularProgressIndicator(color = colors.onPrimary, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        } else {
            Icon(glyph, contentDescription = null, tint = colors.onPrimary, modifier = Modifier.size(18.dp))
        }
        Text(text = label, style = memoryText(16f, 21f, FontWeight.SemiBold), color = colors.onPrimary)
    }
}

// ── Suggestions entry ──

/** Suggestions entry: a plain card with nothing pending, a three-layer deck previewing the first suggestion otherwise. */
@Composable
private fun MemoryInboxEntry(state: MemoryInboxUiState, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val first = state.candidates.firstOrNull()
    val row: @Composable () -> Unit = {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = onClick)
                .padding(start = 16.dp, end = 14.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(MemoryGlyphs.Inbox, contentDescription = null, tint = colors.primary, modifier = Modifier.size(22.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.memory_inbox_title),
                    style = memoryText(16f, 21f, FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                if (first != null) {
                    Text(
                        text = first.content,
                        style = memoryText(13.5f, 19f),
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
            }
            state.entryValue?.let { count ->
                Box(
                    modifier = Modifier
                        .heightIn(min = 24.dp)
                        .widthIn(min = 24.dp)
                        .background(colors.primaryTextSafe, CircleShape)
                        .padding(horizontal = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(text = count, style = memoryDigits(12.5f), color = colors.onPrimary)
                }
            }
            Icon(MemoryGlyphs.Chevron, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
        }
    }
    if (first == null) {
        Box(modifier = modifier.fillMaxWidth().memoryCard(outlined = true)) { row() }
        return
    }
    Box(modifier = modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 24.dp)
                .fillMaxWidth()
                .height(40.dp)
                .alpha(0.5f)
                .memoryCard(radius = 18.dp, outlined = true),
        )
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(start = 12.dp, end = 12.dp, bottom = 6.dp)
                .fillMaxWidth()
                .height(40.dp)
                .alpha(0.8f)
                .memoryCard(radius = 18.dp, outlined = true),
        )
        Box(modifier = Modifier.padding(bottom = 12.dp).fillMaxWidth().memoryCard(outlined = true)) { row() }
    }
}

// ── Draft entry (items mode) ──

@Composable
private fun MemoryDraftCard(loading: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .memoryCard()
            .clickable(enabled = !loading, onClick = onClick)
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (loading) {
            CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
        } else {
            Icon(MemoryGlyphs.Sparkle, contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
        }
        Text(
            text = stringResource(R.string.memory_generate_draft),
            style = memoryText(16f, 21f, FontWeight.Medium),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f).padding(vertical = 14.dp),
        )
        Icon(MemoryGlyphs.Chevron, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
    }
}
