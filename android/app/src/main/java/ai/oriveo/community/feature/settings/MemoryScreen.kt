package ai.oriveo.community.feature.settings

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.automirrored.outlined.StickyNote2
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.PriorityHigh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.util.graphemeCount
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import kotlin.math.ceil
import org.koin.androidx.compose.koinViewModel

// ── Hero accent tone ──

private data class HeroTone(
    val foreground: Color,
    val background: Color,
)

@Composable
private fun heroToneFor(style: MemoryHeroStyle): HeroTone {
    val colors = OriveoTheme.colors
    return when (style) {
        MemoryHeroStyle.DraftStarter, MemoryHeroStyle.ManualStarter -> HeroTone(
            foreground = colors.primary,
            background = colors.primarySoft,
        )
        MemoryHeroStyle.ActiveMemory -> HeroTone(
            foreground = colors.success,
            background = colors.successSoft,
        )
    }
}

// ── Constants ──

private const val MEMORY_CHAR_LIMIT = 2_000
private const val MEMORY_CHAR_SOFT_WARN_THRESHOLD = 1_700
private const val MEMORY_CHAR_WARN_THRESHOLD = 1_900

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoryScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: MemoryViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val usageCount by viewModel.usageCount.collectAsStateWithLifecycle()
    val hasRecentConversations by viewModel.hasRecentConversations.collectAsStateWithLifecycle()
    var showUnsavedDialog by remember { mutableStateOf(false) }
    var isEditorFocused by remember { mutableStateOf(false) }
    var focusRequestTick by remember { mutableIntStateOf(0) }
    val focusRequester = remember { FocusRequester() }
    val presentation = buildMemoryScreenPresentation(
        memoryText = viewModel.editText,
        isEditorFocused = isEditorFocused,
        hasRecentConversations = hasRecentConversations,
    )
    
    
    val reduceMotion = false

    
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

    LaunchedEffect(focusRequestTick) {
        if (focusRequestTick > 0) {
            focusRequester.requestFocus()
        }
    }

    BackHandler(enabled = viewModel.hasChanges) {
        showUnsavedDialog = true
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()
        MemoryAuroraBackdrop()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.memory_title),
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        IconButton(
                            onClick = {
                                if (viewModel.hasChanges) {
                                    showUnsavedDialog = true
                                } else {
                                    onNavigateBack()
                                }
                            },
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = stringResource(R.string.back),
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
            bottomBar = {
                AnimatedVisibility(
                    visible = viewModel.hasChanges || viewModel.showSaveSuccessDialog,
                    enter = slideInVertically(
                        initialOffsetY = { it },
                        animationSpec = spring(dampingRatio = 0.86f, stiffness = 400f),
                    ) + fadeIn(),
                    exit = slideOutVertically(
                        targetOffsetY = { it },
                        animationSpec = tween(200),
                    ) + fadeOut(),
                ) {
                    MemorySaveBar(
                        text = viewModel.editText,
                        reduceMotion = reduceMotion,
                        isSuccess = viewModel.showSaveSuccessDialog,
                        onSave = viewModel::save,
                    )
                }
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
                        .padding(horizontal = OriveoTheme.layout.screenH)
                        .padding(bottom = 64.dp)
                        .alpha(pageAlpha)
                        .offset(y = pageOffsetY),
                    verticalArrangement = Arrangement.spacedBy(30.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Spacer(modifier = Modifier.height(20.dp))

                MemoryHeroSection(
                    presentation = presentation,
                    usageCount = usageCount,
                    antiForgetEnabled = viewModel.antiForgetEnabled && viewModel.editText.isNotBlank(),
                    isGeneratingDraft = viewModel.isGeneratingDraft,
                    reduceMotion = reduceMotion,
                    onAction = { action ->
                        when (action) {
                            MemoryScreenAction.GenerateDraft -> viewModel.generateDraft()
                            MemoryScreenAction.FocusEditor -> {
                                focusRequestTick += 1
                            }
                        }
                    },
                )

                
                MemoryEditorCard(
                    text = viewModel.editText,
                    mode = presentation.mode,
                    focusRequester = focusRequester,
                    isFocused = isEditorFocused,
                    onValueChange = viewModel::updateEditText,
                    onFocusChanged = { focused -> isEditorFocused = focused },
                )

                if (presentation.showsSupportSections) {
                    AntiForgetCard(
                        enabled = viewModel.antiForgetEnabled,
                        onEnabledChange = viewModel::updateAntiForgetEnabled,
                    )
                    PrivacyFootnote()
                }

                Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }

    if (showUnsavedDialog) {
        AlertDialog(
            onDismissRequest = { showUnsavedDialog = false },
            title = { Text(stringResource(R.string.memory_unsaved_title)) },
            text = { Text(stringResource(R.string.memory_unsaved_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showUnsavedDialog = false
                        onNavigateBack()
                    },
                ) {
                    Text(stringResource(R.string.discard))
                }
            },
            dismissButton = {
                TextButton(onClick = { showUnsavedDialog = false }) {
                    Text(stringResource(R.string.memory_keep_editing))
                }
            },
        )
    }

    
    LaunchedEffect(viewModel.showSaveSuccessDialog) {
        if (viewModel.showSaveSuccessDialog) {
            kotlinx.coroutines.delay(1400)
            viewModel.dismissSaveSuccess()
        }
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


@Composable
private fun MemoryAuroraBackdrop() {
    val isDark = OriveoTheme.isDark
    Box(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .size(520.dp)
                .align(Alignment.TopCenter)
                .offset(y = 40.dp)
                .blur(radius = 14.dp)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            OriveoTheme.colors.primary.copy(alpha = if (isDark) 0.16f else 0.10f),
                            Color.Transparent,
                        ),
                    ),
                    shape = CircleShape,
                ),
        )
    }
}

// ── Hero Section ──

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MemoryHeroSection(
    presentation: MemoryScreenPresentation,
    usageCount: Int,
    antiForgetEnabled: Boolean,
    isGeneratingDraft: Boolean,
    reduceMotion: Boolean,
    onAction: (MemoryScreenAction) -> Unit,
) {
    val colors = OriveoTheme.colors
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }

    val scale by animateFloatAsState(
        targetValue = if (appeared) 1f else 0.86f,
        animationSpec = if (reduceMotion) {
            tween(0)
        } else {
            spring(dampingRatio = 0.85f, stiffness = 320f)
        },
        label = "heroOrbScale",
    )
    val offsetY by animateDpAsState(
        targetValue = if (appeared) 0.dp else 12.dp,
        animationSpec = if (reduceMotion) {
            tween(0)
        } else {
            spring(dampingRatio = 0.85f, stiffness = 320f)
        },
        label = "heroOffsetY",
    )
    val opacityValue by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = if (reduceMotion) tween(0) else tween(360),
        label = "heroOpacity",
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .offset(y = offsetY)
            .scale(if (reduceMotion) 1f else opacityValue.coerceAtLeast(0.001f)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        HeroOrbWithRings(
            modifier = Modifier.scale(scale),
        )

        HeroChip(style = presentation.heroStyle)

        HeroTitleAndDescription(presentation = presentation)

        if (usageCount > 0 || antiForgetEnabled) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm, Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 340.dp),
            ) {
                if (usageCount > 0) {
                    MemoryOverviewBadge(
                        text = stringResource(R.string.memory_usage_count, usageCount),
                        icon = Icons.Filled.CheckCircle,
                        foreground = colors.success,
                        fill = colors.successSoft,
                    )
                }
                if (antiForgetEnabled) {
                    MemoryOverviewBadge(
                        text = stringResource(R.string.memory_anti_forget_toggle),
                        icon = Icons.Filled.Bookmark,
                        foreground = colors.primary,
                        fill = colors.primarySoft,
                    )
                }
            }
        }

        if (presentation.primaryAction != null) {
            Column(
                modifier = Modifier.widthIn(max = 340.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                HeroPrimaryActionButton(
                    action = presentation.primaryAction,
                    loading = isGeneratingDraft,
                    onClick = { onAction(presentation.primaryAction) },
                )
                if (presentation.secondaryAction != null) {
                    HeroSecondaryActionLink(
                        action = presentation.secondaryAction,
                        onClick = { onAction(presentation.secondaryAction) },
                    )
                }
            }
        }
    }
}

// ── Orb ──

@Composable
private fun HeroOrbWithRings(modifier: Modifier = Modifier) {
    val isDark = OriveoTheme.isDark
    val primary = OriveoTheme.colors.primary

    Box(
        modifier = modifier.size(168.dp),
        contentAlignment = Alignment.Center,
    ) {
        
        Box(
            modifier = Modifier
                .size(168.dp)
                .border(
                    width = 1.dp,
                    color = primary.copy(alpha = if (isDark) 0.10f else 0.05f),
                    shape = CircleShape,
                ),
        )
        
        Box(
            modifier = Modifier
                .size(132.dp)
                .border(
                    width = 1.dp,
                    color = primary.copy(alpha = if (isDark) 0.16f else 0.08f),
                    shape = CircleShape,
                ),
        )
        HeroOrb()
    }
}

@Composable
private fun HeroOrb() {
    val isDark = OriveoTheme.isDark
    val primary = OriveoTheme.colors.primary
    val primaryGlow = OriveoTheme.colors.primaryGlow
    val shadowBaseColor = OriveoTheme.colors.shadow

    Box(
        modifier = Modifier
            .size(96.dp)
            
            .shadow(
                elevation = if (isDark) 32.dp else 20.dp,
                shape = CircleShape,
                ambientColor = primaryGlow,
                spotColor = primaryGlow,
            )
            .shadow(
                elevation = 6.dp,
                shape = CircleShape,
                ambientColor = primary.copy(alpha = if (isDark) 0.34f else 0.22f),
                spotColor = primary.copy(alpha = if (isDark) 0.34f else 0.22f),
            )
            .shadow(
                elevation = 1.dp,
                shape = CircleShape,
                ambientColor = shadowBaseColor.copy(alpha = 0.16f),
                spotColor = shadowBaseColor.copy(alpha = 0.16f),
            )
            .background(
                brush = Brush.radialGradient(
                    colors = listOf(
                        Color(0xFFB89BFF),
                        Color(0xFF8347F5),
                        Color(0xFF5A2BB0),
                    ),
                    center = Offset(0.32f * 96f, 0.28f * 96f),
                    radius = 64f,
                ),
                shape = CircleShape,
            )
            
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.42f),
                        Color.White.copy(alpha = 0.06f),
                    ),
                ),
                shape = CircleShape,
            )
            
            
            .drawBehind {
                val arcSize = 78.dp.toPx()
                val centerOffset = Offset((size.width - arcSize) / 2f, (size.height - arcSize) / 2f)
                rotate(degrees = -115f, pivot = Offset(size.width / 2f, size.height / 2f)) {
                    drawArc(
                        color = Color.White.copy(alpha = 0.55f),
                        startAngle = -90f,
                        sweepAngle = 0.32f * 360f,
                        useCenter = false,
                        topLeft = centerOffset,
                        size = Size(arcSize, arcSize),
                        style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round),
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.Psychology,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier
                .size(36.dp)
                .shadow(
                    elevation = 4.dp,
                    shape = CircleShape,
                    ambientColor = Color.Black.copy(alpha = 0.22f),
                    spotColor = Color.Black.copy(alpha = 0.22f),
                ),
        )
    }
}

// ── Hero chip ──

@Composable
private fun HeroChip(style: MemoryHeroStyle) {
    val tone = heroToneFor(style)
    val icon = when (style) {
        MemoryHeroStyle.DraftStarter -> Icons.Filled.AutoAwesome
        MemoryHeroStyle.ManualStarter -> Icons.Outlined.Edit
        MemoryHeroStyle.ActiveMemory -> Icons.Filled.Check
    }
    val text = when (style) {
        MemoryHeroStyle.DraftStarter -> stringResource(R.string.memory_hero_chip_auto)
        MemoryHeroStyle.ManualStarter -> stringResource(R.string.memory_hero_chip_memory)
        MemoryHeroStyle.ActiveMemory -> stringResource(R.string.memory_hero_chip_ready)
    }

    Row(
        modifier = Modifier
            .background(tone.background, RoundedCornerShape(999.dp))
            .border(
                width = OriveoBorderWidth.standard,
                color = tone.foreground.copy(alpha = 0.18f),
                shape = RoundedCornerShape(999.dp),
            )
            .padding(horizontal = 10.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tone.foreground,
            modifier = Modifier.size(10.dp),
        )
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.6.sp,
            ),
            color = tone.foreground,
        )
    }
}

// ── Hero title / description ──

@Composable
private fun HeroTitleAndDescription(presentation: MemoryScreenPresentation) {
    val colors = OriveoTheme.colors
    val title = if (presentation.mode == MemoryScreenMode.Starter) {
        stringResource(R.string.memory_empty_title)
    } else {
        stringResource(R.string.memory_title)
    }
    val description = if (presentation.mode == MemoryScreenMode.Starter) {
        stringResource(R.string.memory_empty_description)
    } else {
        stringResource(R.string.memory_edit_description)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .widthIn(max = 320.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.hero.copy(letterSpacing = (-0.4).sp),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            text = description,
            style = OriveoTheme.typography.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

// ── Action buttons ──

@Composable
private fun HeroPrimaryActionButton(
    action: MemoryScreenAction,
    loading: Boolean,
    onClick: () -> Unit,
) {
    val label = when (action) {
        MemoryScreenAction.GenerateDraft -> stringResource(R.string.memory_generate_draft)
        MemoryScreenAction.FocusEditor -> stringResource(R.string.memory_write_manually)
    }
    val icon: ImageVector? = when (action) {
        MemoryScreenAction.GenerateDraft -> if (loading) null else Icons.Filled.AutoAwesome
        MemoryScreenAction.FocusEditor -> Icons.Outlined.Edit
    }

    OriveoPrimaryButton(
        text = label,
        onClick = onClick,
        loading = loading && action == MemoryScreenAction.GenerateDraft,
        enabled = !(loading && action == MemoryScreenAction.GenerateDraft),
        modifier = Modifier.fillMaxWidth(),
        leadingIcon = icon?.let {
            {
                Icon(
                    imageVector = it,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(15.dp),
                )
            }
        },
    )
}

@Composable
private fun HeroSecondaryActionLink(
    action: MemoryScreenAction,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val label = when (action) {
        MemoryScreenAction.GenerateDraft -> stringResource(R.string.memory_generate_draft)
        MemoryScreenAction.FocusEditor -> stringResource(R.string.memory_write_manually)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.Medium),
            color = colors.primary,
        )
        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier
                .size(12.dp)
                .scale(scaleX = -1f, scaleY = 1f),
        )
    }
}

// ── Editor card ──

@Composable
private fun MemoryEditorCard(
    text: String,
    mode: MemoryScreenMode,
    focusRequester: FocusRequester,
    isFocused: Boolean,
    onValueChange: (String) -> Unit,
    onFocusChanged: (Boolean) -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    
    
    val charCount = remember(text) { text.graphemeCount() }
    val approxTokens = remember(charCount, text.isEmpty()) {
        if (text.isEmpty()) null else ceil(charCount * 0.35).toInt()
    }
    
    val countColor = when {
        charCount > MEMORY_CHAR_WARN_THRESHOLD -> colors.warning
        charCount > MEMORY_CHAR_SOFT_WARN_THRESHOLD -> Color(
            red = colors.warning.red * 0.78f + colors.textSecondary.red * 0.22f,
            green = colors.warning.green * 0.78f + colors.textSecondary.green * 0.22f,
            blue = colors.warning.blue * 0.78f + colors.textSecondary.blue * 0.22f,
            alpha = 1f,
        )
        else -> colors.textSecondary
    }

    
    
    val focusedShadowElevation = if (isFocused) 24.dp else if (isDark) 18.dp else 12.dp
    val focusedShadowColor = if (isFocused) {
        colors.primaryGlow
    } else {
        colors.shadow.copy(alpha = if (isDark) 0.45f else 0.10f)
    }
    val borderColor = if (isFocused) colors.primary.copy(alpha = 0.32f) else colors.border
    
    val shineBrush = remember(isDark) {
        Brush.horizontalGradient(
            colors = listOf(
                Color.Transparent,
                Color.White.copy(alpha = if (isDark) 0.10f else 0.55f),
                Color.Transparent,
            ),
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            
            
            .shadow(
                elevation = focusedShadowElevation,
                shape = cardShape,
                ambientColor = focusedShadowColor,
                spotColor = focusedShadowColor,
            )
            .background(colors.surfaceElevated, cardShape)
            
            
            .drawWithCache {
                val shineHeight = 1.dp.toPx()
                val rectSize = Size(size.width, shineHeight)
                onDrawBehind {
                    drawRect(brush = shineBrush, topLeft = Offset.Zero, size = rectSize)
                }
            }
            .border(
                width = if (isFocused) 1.dp else OriveoBorderWidth.standard,
                color = borderColor,
                shape = cardShape,
            )
            .padding(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        EditorHeader(
            mode = mode,
            charCount = charCount,
            countColor = countColor,
        )

        // hairline
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        colors = listOf(
                            colors.border.copy(alpha = 0f),
                            colors.border,
                            colors.border.copy(alpha = 0f),
                        ),
                    ),
                ),
        )

        EditorTextField(
            text = text,
            focusRequester = focusRequester,
            onValueChange = onValueChange,
            onFocusChanged = onFocusChanged,
        )

        if (approxTokens != null) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Psychology,
                    contentDescription = null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(10.dp),
                )
                Text(
                    text = "$approxTokens tokens",
                    style = OriveoTheme.typography.footnote.copy(fontFamily = FontFamily.Monospace),
                    color = colors.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun EditorHeader(
    mode: MemoryScreenMode,
    charCount: Int,
    countColor: Color,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            colors.primarySoft,
                            colors.primarySoft.copy(alpha = 0.55f),
                        ),
                    ),
                    shape = RoundedCornerShape(9.dp),
                )
                .border(
                    width = OriveoBorderWidth.standard,
                    color = colors.primary.copy(alpha = 0.16f),
                    shape = RoundedCornerShape(9.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Outlined.StickyNote2,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            text = if (mode == MemoryScreenMode.Starter) {
                stringResource(R.string.memory_write_manually)
            } else {
                stringResource(R.string.memory_title)
            },
            style = OriveoTheme.typography.title3,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = "$charCount / 2,000",
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            ),
            color = countColor,
            maxLines = 1,
        )
    }
}

@Composable
private fun EditorTextField(
    text: String,
    focusRequester: FocusRequester,
    onValueChange: (String) -> Unit,
    onFocusChanged: (Boolean) -> Unit,
) {
    val colors = OriveoTheme.colors
    
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 200.dp, max = 320.dp),
    ) {
        BasicTextField(
            value = text,
            onValueChange = onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 200.dp, max = 320.dp)
                .focusRequester(focusRequester)
                .onFocusChanged { onFocusChanged(it.isFocused) },
            textStyle = LocalTextStyle.current.merge(
                OriveoTheme.typography.body.copy(color = colors.textPrimary),
            ),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
            cursorBrush = SolidColor(colors.primary),
        )
        if (text.isEmpty()) {
            Text(
                text = stringResource(R.string.memory_placeholder),
                style = OriveoTheme.typography.body.copy(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic),
                color = colors.textTertiary,
                modifier = Modifier
                    .padding(top = 4.dp, start = 2.dp),
            )
        }
    }
}

// ── Overview badge ──

@Composable
private fun MemoryOverviewBadge(
    text: String,
    icon: ImageVector,
    foreground: Color,
    fill: Color,
) {
    Row(
        modifier = Modifier
            .background(fill, RoundedCornerShape(999.dp))
            .border(
                width = OriveoBorderWidth.standard,
                color = foreground.copy(alpha = 0.16f),
                shape = RoundedCornerShape(999.dp),
            )
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = foreground,
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = foreground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ── AntiForget card ──

@Composable
private fun AntiForgetCard(
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)

    val borderColor = if (enabled) {
        colors.primary.copy(alpha = 0.32f)
    } else {
        colors.border
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = if (isDark) 14.dp else 10.dp,
                shape = cardShape,
                ambientColor = colors.shadow.copy(alpha = if (isDark) 0.40f else 0.08f),
                spotColor = colors.shadow.copy(alpha = if (isDark) 0.40f else 0.08f),
            )
            .shadow(
                elevation = 1.5.dp,
                shape = cardShape,
                ambientColor = colors.shadow.copy(alpha = if (isDark) 0.24f else 0.04f),
                spotColor = colors.shadow.copy(alpha = if (isDark) 0.24f else 0.04f),
            )
            .background(colors.surfaceElevated, cardShape)
            .drawBehind {
                val shineHeight = 1.dp.toPx()
                drawRect(
                    brush = Brush.horizontalGradient(
                        colors = listOf(
                            Color.Transparent,
                            Color.White.copy(alpha = if (isDark) 0.10f else 0.55f),
                            Color.Transparent,
                        ),
                    ),
                    topLeft = Offset.Zero,
                    size = Size(size.width, shineHeight),
                )
            }
            .border(
                width = OriveoBorderWidth.standard,
                color = borderColor,
                shape = cardShape,
            )
            .padding(horizontal = 18.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AntiForgetIcon(enabled = enabled)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = stringResource(R.string.memory_anti_forget_title),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = buildHighlightedDescription(
                    text = stringResource(R.string.memory_anti_forget_description),
                    highlight = colors.primary,
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onEnabledChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = colors.primary,
                uncheckedThumbColor = Color.White,
                uncheckedTrackColor = colors.borderStrong,
            ),
        )
    }
}

@Composable
private fun AntiForgetIcon(enabled: Boolean) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Box(
        modifier = Modifier
            .size(38.dp)
            .then(
                if (enabled) {
                    Modifier
                        .shadow(
                            elevation = 8.dp,
                            shape = RoundedCornerShape(11.dp),
                            ambientColor = colors.primaryGlow,
                            spotColor = colors.primaryGlow,
                        )
                        .background(
                            brush = Brush.linearGradient(
                                colors = listOf(
                                    Color(0xFF9B6BFF),
                                    Color(0xFF7238E5),
                                ),
                            ),
                            shape = RoundedCornerShape(11.dp),
                        )
                        .border(
                            width = OriveoBorderWidth.standard,
                            color = Color.White.copy(alpha = 0.28f),
                            shape = RoundedCornerShape(11.dp),
                        )
                } else {
                    Modifier
                        .background(colors.surfaceInset, RoundedCornerShape(11.dp))
                        .border(
                            width = OriveoBorderWidth.standard,
                            color = colors.border,
                            shape = RoundedCornerShape(11.dp),
                        )
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Bookmark,
            contentDescription = null,
            tint = if (enabled) Color.White else colors.textSecondary,
            modifier = Modifier.size(15.dp),
        )
    }
}

// ── Privacy footnote ──

@Composable
private fun PrivacyFootnote() {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            colors.warningSoft,
                            colors.warningSoft.copy(alpha = 0.5f),
                        ),
                    ),
                    shape = RoundedCornerShape(7.dp),
                )
                .border(
                    width = OriveoBorderWidth.standard,
                    color = colors.warning.copy(alpha = 0.22f),
                    shape = RoundedCornerShape(7.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.PriorityHigh,
                contentDescription = null,
                tint = colors.warning,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(
            text = stringResource(R.string.memory_privacy_warning),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
    }
}

// ── Save bar ──

@Composable
private fun MemorySaveBar(
    text: String,
    reduceMotion: Boolean,
    isSuccess: Boolean,
    onSave: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    
    val charCount = remember(text) { text.graphemeCount() }
    val approxTokens = remember(charCount, text.isEmpty()) {
        if (text.isEmpty()) 0 else ceil(charCount * 0.35).toInt()
    }
    val bgColor by animateColorAsState(
        targetValue = if (isSuccess) {
            
            Color(
                red = colors.success.red * 0.06f + colors.backgroundBase.red * 0.94f,
                green = colors.success.green * 0.06f + colors.backgroundBase.green * 0.94f,
                blue = colors.success.blue * 0.06f + colors.backgroundBase.blue * 0.94f,
                alpha = 0.96f,
            )
        } else {
            colors.backgroundBase.copy(alpha = 0.94f)
        },
        animationSpec = tween(220),
        label = "saveBarBg",
    )

    Column(
        modifier = Modifier
            .fillMaxWidth(),
    ) {
        
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            colors.shadow.copy(alpha = if (isDark) 0.18f else 0.06f),
                        ),
                    ),
                ),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(bgColor)
                .border(
                    width = OriveoBorderWidth.standard,
                    color = if (isSuccess) colors.success.copy(alpha = 0.32f) else colors.border,
                    shape = RoundedCornerShape(0.dp),
                )
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (isSuccess) {
                
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .background(colors.success.copy(alpha = 0.16f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Check,
                        contentDescription = null,
                        tint = colors.success,
                        modifier = Modifier.size(12.dp),
                    )
                }
            } else {
                SavePulseDot(reduceMotion = reduceMotion)
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = if (isSuccess) {
                        stringResource(R.string.memory_saved)
                    } else {
                        stringResource(R.string.memory_unsaved_bar_title)
                    },
                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = if (isSuccess) colors.success else colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val subtitle = buildString {
                    append("$charCount / 2,000 ")
                    append(stringResource(R.string.memory_chars))
                    if (approxTokens > 0) {
                        append(" · $approxTokens tokens")
                    }
                }
                Text(
                    text = subtitle,
                    style = OriveoTheme.typography.footnote.copy(
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        fontFamily = FontFamily.Monospace,
                    ),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (!isSuccess) {
                Box(modifier = Modifier.widthIn(max = 132.dp)) {
                    OriveoPrimaryButton(
                        text = stringResource(R.string.save),
                        onClick = onSave,
                    )
                }
            }
        }
    }
}

@Composable
private fun SavePulseDot(reduceMotion: Boolean) {
    val primary = OriveoTheme.colors.primary
    val transition = rememberInfiniteTransition(label = "savePulse")
    val scale = if (reduceMotion) {
        1f
    } else {
        transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.6f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1400, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "savePulseScale",
        ).value
    }
    val alpha = if (reduceMotion) {
        0.45f
    } else {
        transition.animateFloat(
            initialValue = 0.45f,
            targetValue = 0f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1400, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "savePulseAlpha",
        ).value
    }

    Box(
        modifier = Modifier.size(16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .scale(scale)
                .background(primary.copy(alpha = alpha), CircleShape),
        )
        Box(
            modifier = Modifier
                .size(7.dp)
                .background(primary, CircleShape),
        )
    }
}


private fun buildHighlightedDescription(text: String, highlight: Color): AnnotatedString {
    return buildAnnotatedString {
        val pattern = Regex("\\d+")
        var lastEnd = 0
        pattern.findAll(text).forEach { match ->
            if (match.range.first > lastEnd) {
                append(text.substring(lastEnd, match.range.first))
            }
            withStyle(SpanStyle(color = highlight, fontWeight = FontWeight.Bold)) {
                append(match.value)
            }
            lastEnd = match.range.last + 1
        }
        if (lastEnd < text.length) {
            append(text.substring(lastEnd))
        }
    }
}

// ── Previews ──

@Preview(showBackground = true, widthDp = 360, heightDp = 720)
@Composable
private fun MemoryScreenPreviewCompact() {
    OriveoTheme {
        Box(modifier = Modifier.fillMaxSize()) {
            MemoryHeroSection(
                presentation = MemoryScreenPresentation(
                    mode = MemoryScreenMode.Starter,
                    heroStyle = MemoryHeroStyle.DraftStarter,
                    primaryAction = MemoryScreenAction.GenerateDraft,
                    secondaryAction = MemoryScreenAction.FocusEditor,
                    showsExampleSuggestions = false,
                    showsSupportSections = false,
                ),
                usageCount = 0,
                antiForgetEnabled = false,
                isGeneratingDraft = false,
                reduceMotion = true,
                onAction = {},
            )
        }
    }
}

@Preview(showBackground = true, widthDp = 360, heightDp = 720, uiMode = android.content.res.Configuration.UI_MODE_NIGHT_YES)
@Composable
private fun MemoryScreenPreviewCompactDark() {
    OriveoTheme(darkTheme = true) {
        Box(modifier = Modifier.fillMaxSize()) {
            MemoryHeroSection(
                presentation = MemoryScreenPresentation(
                    mode = MemoryScreenMode.Editor,
                    heroStyle = MemoryHeroStyle.ActiveMemory,
                    primaryAction = null,
                    secondaryAction = null,
                    showsExampleSuggestions = false,
                    showsSupportSections = true,
                ),
                usageCount = 3,
                antiForgetEnabled = true,
                isGeneratingDraft = false,
                reduceMotion = true,
                onAction = {},
            )
        }
    }
}
