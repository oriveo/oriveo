package ai.oriveo.community.feature.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.ForceDarkSystemBars
import ai.oriveo.community.ui.component.OriveoWebDestination
import ai.oriveo.community.ui.component.openOriveoWebPage
import kotlinx.coroutines.launch


@Composable
fun OnboardingFlowScreen(
    reduceMotion: Boolean,
    onActViewed: (OnboardingAct) -> Unit,
    onSkipUsed: () -> Unit,
    onGetStarted: () -> Unit,
    onBack: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val config = LocalConfiguration.current
    val screenWidthDp = config.screenWidthDp.toFloat()
    val screenHeightDp = config.screenHeightDp.toFloat()
    val metrics = remember(screenWidthDp, screenHeightDp) {
        OnboardingLayoutMetrics(screenWidthDp, screenHeightDp)
    }

    
    ForceDarkSystemBars()

    val pagerState = rememberPagerState(pageCount = { OnboardingAct.ordered.size })
    val progress by remember {
        derivedStateOf { pagerState.currentPage + pagerState.currentPageOffsetFraction }
    }
    val values = OnboardingStageValues(progress, screenWidthDp)

    var isStageAnimating by remember { mutableStateOf(true) }
    var isExiting by remember { mutableStateOf(false) }

    
    var revealed by remember { mutableStateOf(OnboardingMotionPolicy.revealsInstantly(reduceMotion)) }
    LaunchedEffect(Unit) { revealed = true }
    val revealAlpha by animateFloatAsState(
        targetValue = if (revealed) 1f else 0f,
        animationSpec = tween(if (reduceMotion) 0 else 700),
        label = "reveal",
    )
    val controlsOffsetY by animateFloatAsState(
        targetValue = if (revealed) 0f else 14f,
        animationSpec = spring(dampingRatio = 0.85f),
        label = "controlsOffset",
    )

    
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.settledPage }.collect { page ->
            OnboardingAct.fromIndex(page)?.let(onActViewed)
        }
    }

    val exitScale by animateFloatAsState(
        targetValue = if (isExiting) 0.96f else 1f,
        animationSpec = tween(280),
        label = "exitScale",
    )
    val exitAlpha by animateFloatAsState(
        targetValue = if (isExiting) 0f else 1f,
        animationSpec = tween(280),
        label = "exitAlpha",
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0B0A14))
            .graphicsLayer {
                scaleX = exitScale
                scaleY = exitScale
                alpha = exitAlpha
            },
    ) {
        OnboardingAuroraBackground(values = values, alpha = revealAlpha)

        OnboardingOrbitStage(
            values = values,
            stageScale = metrics.stageScale,
            ringsRevealed = revealed,
            nucleusRevealed = revealed,
            isAnimating = isStageAnimating,
            reduceMotion = reduceMotion,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { translationY = (metrics.orbitCenterYDp - screenHeightDp / 2f) * density },
        )

        
        HorizontalPager(
            state = pagerState,
            
            
            
            modifier = Modifier
                .fillMaxSize()
                .systemGestureExclusion(),
        ) { page ->
            val act = OnboardingAct.ordered[page]
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.weight(1f))
                OnboardingCopyBlock(
                    act = act,
                    metrics = metrics,
                    alpha = values.copyOpacity(act) * revealAlpha,
                )
                Spacer(Modifier.height(metrics.copyBottomInsetDp.dp))
            }
        }

        
        OnboardingControlLayer(
            values = values,
            metrics = metrics,
            alpha = revealAlpha,
            offsetY = controlsOffsetY,
            onDotTap = { index -> scope.launch { pagerState.animateScrollToPage(index) } },
            onStart = {
                if (!isExiting) {
                    isExiting = true
                    isStageAnimating = false
                    onGetStarted()
                }
            },
            onOpenLegal = { destination -> context.openOriveoWebPage(destination) },
        )

        
        OnboardingSkipButton(
            values = values,
            alpha = revealAlpha,
            onSkip = {
                onSkipUsed()
                scope.launch { pagerState.animateScrollToPage(OnboardingAct.Start.index) }
            },
        )
    }
}


@Composable
private fun OnboardingAuroraBackground(values: OnboardingStageValues, alpha: Float) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { this.alpha = alpha }
            .background(
                Brush.radialGradient(
                    colors = listOf(values.auroraTop.toColor().copy(alpha = 0.5f), Color.Transparent),
                    center = androidx.compose.ui.geometry.Offset(0f, 0f),
                    radius = 900f,
                ),
            ),
    )
    Box(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { this.alpha = alpha }
            .background(
                Brush.radialGradient(
                    colors = listOf(values.auroraBottom.toColor().copy(alpha = 0.42f), Color.Transparent),
                    center = androidx.compose.ui.geometry.Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                    radius = 900f,
                ),
            ),
    )
}


@Composable
private fun OnboardingCopyBlock(
    act: OnboardingAct,
    metrics: OnboardingLayoutMetrics,
    alpha: Float,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = metrics.horizontalPaddingDp.dp)
            .graphicsLayer { this.alpha = alpha },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (act == OnboardingAct.Brand) {
            Text(
                text = "Oriveo",
                fontSize = metrics.wordmarkSizeSp.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = (-0.7).sp,
                color = OnboardingPalette.ink,
            )
        } else {
            Text(
                text = stringResource(eyebrowRes(act)).uppercase(),
                fontSize = 10.5.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                letterSpacing = 2.3.sp,
                color = OnboardingPalette.purpleBright,
            )
        }

        HighlightedTitle(
            raw = stringResource(titleRes(act)),
            fontSizeSp = metrics.titleSizeSp,
        )

        Text(
            text = stringResource(subtitleRes(act)),
            fontSize = 14.sp,
            color = OnboardingPalette.muted,
            textAlign = TextAlign.Center,
            lineHeight = 21.sp,
            modifier = Modifier.width(300.dp),
        )
    }
}


@Composable
private fun HighlightedTitle(raw: String, fontSizeSp: Float) {
    val segments = remember(raw) { OnboardingCopyMarkup.parse(raw) }
    val text = buildAnnotatedString {
        segments.forEach { segment ->
            if (segment.isHighlighted) {
                withStyle(SpanStyle(brush = OnboardingPalette.highlightGradient)) { append(segment.text) }
            } else {
                withStyle(SpanStyle(color = OnboardingPalette.ink)) { append(segment.text) }
            }
        }
    }
    Text(
        text = text,
        fontSize = fontSizeSp.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.4).sp,
        lineHeight = (fontSizeSp * 1.28f).sp,
        textAlign = TextAlign.Center,
    )
}

private fun eyebrowRes(act: OnboardingAct): Int = when (act) {
    OnboardingAct.Models -> R.string.onboarding_eyebrow_models
    OnboardingAct.Byok -> R.string.onboarding_eyebrow_byok
    else -> R.string.onboarding_eyebrow_start
}

private fun titleRes(act: OnboardingAct): Int = when (act) {
    OnboardingAct.Brand -> R.string.onboarding_title_brand
    OnboardingAct.Models -> R.string.onboarding_title_models
    OnboardingAct.Byok -> R.string.onboarding_title_byok
    OnboardingAct.Start -> R.string.onboarding_title_start
}

private fun subtitleRes(act: OnboardingAct): Int = when (act) {
    OnboardingAct.Brand -> R.string.onboarding_subtitle_brand
    OnboardingAct.Models -> R.string.onboarding_subtitle_models
    OnboardingAct.Byok -> R.string.onboarding_subtitle_byok
    OnboardingAct.Start -> R.string.onboarding_subtitle_start
}


@Composable
private fun OnboardingControlLayer(
    values: OnboardingStageValues,
    metrics: OnboardingLayoutMetrics,
    alpha: Float,
    offsetY: Float,
    onDotTap: (Int) -> Unit,
    onStart: () -> Unit,
    onOpenLegal: (OriveoWebDestination) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.navigationBars)
            .graphicsLayer {
                this.alpha = alpha
                translationY = offsetY * density
            },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))

        
        Box(
            modifier = Modifier
                .padding(top = 26.dp)
                .width(values.pillWidth.dp)
                .height(52.dp)
                .clip(CircleShape)
                .background(OnboardingPalette.ctaGradient(values.ctaMorph))
                .then(
                    if (values.isCtaInteractive) {
                        Modifier.clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = onStart,
                        )
                    } else {
                        Modifier
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(9.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.graphicsLayer { this.alpha = values.dotsOpacity },
            ) {
                OnboardingAct.ordered.forEach { act ->
                    val isActive = Math.round(values.progress) == act.index
                    Box(
                        modifier = Modifier
                            .width(if (isActive) 22.dp else 7.dp)
                            .height(7.dp)
                            .clip(CircleShape)
                            .background(
                                if (isActive) OnboardingPalette.purpleBright else Color.White.copy(alpha = 0.28f),
                            )
                            .then(
                                if (values.areDotsInteractive) {
                                    Modifier.clickable(
                                        interactionSource = remember { MutableInteractionSource() },
                                        indication = null,
                                    ) { onDotTap(act.index) }
                                } else {
                                    Modifier
                                },
                            ),
                    )
                }
            }

            Text(
                text = stringResource(R.string.get_started),
                fontSize = 16.5.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                maxLines = 1,
                modifier = Modifier.graphicsLayer { this.alpha = values.ctaLabelOpacity },
            )
        }

        OnboardingLegalLine(
            alpha = values.legalOpacity,
            enabled = values.legalOpacity > 0.5f,
            onOpen = onOpenLegal,
        )

        Spacer(Modifier.height(metrics.controlBottomPaddingDp.dp))
    }
}


@Composable
private fun OnboardingLegalLine(
    alpha: Float,
    enabled: Boolean,
    onOpen: (OriveoWebDestination) -> Unit,
) {
    val raw = stringResource(R.string.onboarding_legal)
    val segments = remember(raw) { OnboardingLinkMarkup.parse(raw) }

    Row(
        modifier = Modifier
            .padding(top = 13.dp, start = 24.dp, end = 24.dp)
            .graphicsLayer { this.alpha = alpha },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        segments.forEach { segment ->
            val destination = when {
                segment.url?.endsWith("terms") == true -> OriveoWebDestination.TermsOfService
                segment.url?.endsWith("privacy") == true -> OriveoWebDestination.PrivacyPolicy
                else -> null
            }
            Text(
                text = segment.text,
                fontSize = 10.5.sp,
                color = if (destination != null) OnboardingPalette.muted else OnboardingPalette.faint,
                textDecoration = if (destination != null) TextDecoration.Underline else null,
                modifier = if (destination != null && enabled) {
                    Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { onOpen(destination) }
                } else {
                    Modifier
                },
            )
        }
    }
}


@Composable
private fun OnboardingSkipButton(
    values: OnboardingStageValues,
    alpha: Float,
    onSkip: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(top = 6.dp, end = 22.dp),
        contentAlignment = Alignment.TopEnd,
    ) {
        Text(
            text = stringResource(R.string.onboarding_skip),
            fontSize = 13.5.sp,
            color = OnboardingPalette.muted,
            modifier = Modifier
                .graphicsLayer { this.alpha = values.skipOpacity * alpha }
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.05f))
                .border(1.dp, OnboardingPalette.hairline, CircleShape)
                .then(
                    if (values.isSkipInteractive) {
                        Modifier.clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = onSkip,
                        )
                    } else {
                        Modifier
                    },
                )
                .padding(horizontal = 14.dp, vertical = 8.dp),
        )
    }
}


class OnboardingLayoutMetrics(private val widthDp: Float, private val heightDp: Float) {

    val stageScale: Float
        get() = minOf(widthDp / OnboardingStageValues.REFERENCE_WIDTH, heightDp / 844f)
            .coerceIn(0.78f, 1.12f)

    val orbitCenterYDp: Float get() = heightDp * 0.355f

    
    val copyBottomInsetDp: Float get() = 190f * verticalScale

    val controlBottomPaddingDp: Float get() = 18f

    val horizontalPaddingDp: Float get() = if (widthDp < 380f) 28f else 36f

    val titleSizeSp: Float get() = if (heightDp < 720f) 24f else 27f

    val wordmarkSizeSp: Float get() = if (heightDp < 720f) 30f else 34f

    private val verticalScale: Float get() = (heightDp / 844f).coerceIn(0.84f, 1.06f)
}

