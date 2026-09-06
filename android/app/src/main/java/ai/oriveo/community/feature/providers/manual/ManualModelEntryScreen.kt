package ai.oriveo.community.feature.providers.manual

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.NorthWest
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.feature.providers.relay.relayKindMeta
import ai.oriveo.community.ui.component.OriveoErrorCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.capabilityIcon
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ManualModelEntryScreen(
    onBack: () -> Unit,
    onCompleted: () -> Unit,
    viewModel: ManualModelEntryViewModel = koinViewModel(),
) {
    val provider by viewModel.provider.collectAsStateWithLifecycle()

    LaunchedEffect(viewModel.saveCompleted) {
        if (viewModel.saveCompleted) onCompleted()
    }

    val isRelayMode = provider?.kind == ProviderKind.Relay
    val layout = OriveoTheme.layout
    val colors = OriveoTheme.colors

    Scaffold(
        containerColor = Color.Transparent,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = stringResource(
                            if (isRelayMode) R.string.add_model else R.string.manual_model_entry_title
                        ),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = colors.textPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                ),
            )
        },
        bottomBar = {
            BottomBar(
                isRelayMode = isRelayMode,
                canSave = viewModel.canSave,
                isSaving = viewModel.isSaving,
                isRetrying = viewModel.isRetrying,
                onSave = viewModel::saveManualModel,
                onRetry = viewModel::retrySync,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            val currentProvider = provider
            if (currentProvider != null) {
                SpotlightHero(
                    provider = currentProvider,
                    isRelayMode = isRelayMode,
                    isCompact = layout.isCompact,
                )
            } else {
                Spacer(modifier = Modifier.height(layout.sectionGap))
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = layout.screenH),
                verticalArrangement = Arrangement.spacedBy(if (layout.isCompact) 20.dp else 28.dp),
            ) {
                UnderlineInputSection(
                    modelID = viewModel.modelID,
                    onChange = { viewModel.modelID = it },
                    placeholder = stringResource(
                        if (isRelayMode) R.string.model_id_placeholder_relay
                        else R.string.model_id_placeholder
                    ),
                    footnote = stringResource(
                        if (isRelayMode) R.string.use_exact_model_id
                        else R.string.model_id_footnote
                    ),
                )

                if (isRelayMode) {
                    ExamplesList(
                        onPick = { example -> viewModel.modelID = example },
                    )
                }

                AnimatedVisibility(
                    visible = viewModel.modelID.trim().isNotEmpty() && currentProvider != null,
                    enter = fadeIn() + scaleIn(initialScale = 0.96f),
                    exit = fadeOut() + scaleOut(targetScale = 0.96f),
                ) {
                    if (currentProvider != null) {
                        PreviewCard(
                            provider = currentProvider,
                            modelID = viewModel.modelID.trim(),
                        )
                    }
                }

                viewModel.error?.let { err ->
                    OriveoErrorCard(error = err)
                }
            }

            Spacer(modifier = Modifier.height(layout.sectionGap))
        }
    }
}

// MARK: - Spotlight Hero

@Composable
private fun SpotlightHero(
    provider: Provider,
    isRelayMode: Boolean,
    isCompact: Boolean,
) {
    val colors = OriveoTheme.colors
    val layout = OriveoTheme.layout

    val badgeSize: Dp = if (isCompact) 56.dp else 64.dp
    val glowSize: Dp = if (isCompact) 150.dp else 180.dp
    val heroSpacerTop: Dp = if (isCompact) 4.dp else 8.dp
    val titleStyle = if (isCompact) OriveoTheme.typography.title1 else OriveoTheme.typography.hero

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = heroSpacerTop)
            .padding(horizontal = layout.screenH),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(if (isCompact) 12.dp else 16.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(glowSize),
        ) {
            ProviderBadgeIcon(
                kind = provider.kind,
                size = badgeSize,
                relayKind = if (provider.kind == ProviderKind.Relay) provider.relayKind else null,
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {

            Text(
                text = "${provider.displayName} · ${providerKindLabel(provider)}",
                style = OriveoTheme.typography.caption,
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            // Hero title
            Text(
                text = stringResource(
                    if (isRelayMode) R.string.add_a_model else R.string.manual_model_entry_headline
                ),
                style = titleStyle,
                color = colors.textPrimary,
            )

            Box(
                modifier = Modifier
                    .width(36.dp)
                    .height(3.dp)
                    .background(OriveoGradients.primary, CircleShape),
            )

            Spacer(modifier = Modifier.height(2.dp))

            Text(
                text = stringResource(
                    if (isRelayMode) R.string.enter_a_model_id_relay_supports
                    else R.string.manual_model_entry_description
                ),
                style = OriveoTheme.typography.body,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun providerKindLabel(provider: Provider): String {
    return if (provider.kind == ProviderKind.Relay) {
        val kind = provider.relayKind ?: RelayKind.Custom
        stringResource(relayKindMeta(kind).titleRes)
    } else {
        provider.kind.displayName
    }
}

@Composable
private fun SectionCaps(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = OriveoTheme.typography.footnote.copy(
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        ),
        color = OriveoTheme.colors.textTertiary,
        modifier = modifier,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

// MARK: - Underline-only Input

@Composable
private fun UnderlineInputSection(
    modelID: String,
    onChange: (String) -> Unit,
    placeholder: String,
    footnote: String,
) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val isFocused by interactionSource.collectIsFocusedAsState()

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionCaps(text = stringResource(R.string.model_id_label))

        Column {
            Box(modifier = Modifier.height(56.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    Box(modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    ) {
                        BasicTextField(
                            value = modelID,
                            onValueChange = onChange,
                            singleLine = true,
                            interactionSource = interactionSource,
                            textStyle = LocalTextStyle.current.copy(
                                color = colors.textPrimary,
                                fontSize = 22.sp,
                                fontWeight = FontWeight.Medium,
                                fontFamily = FontFamily.Monospace,
                            ),
                            cursorBrush = SolidColor(colors.primary),
                            keyboardOptions = KeyboardOptions.Default,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (modelID.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = LocalTextStyle.current.copy(
                                    color = colors.textTertiary,
                                    fontSize = 16.sp,
                                    fontFamily = FontFamily.Monospace,
                                ),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (modelID.isNotEmpty()) {
                        IconButton(
                            onClick = { onChange("") },
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                Icons.Filled.Cancel,
                                contentDescription = stringResource(R.string.manual_model_clear),
                                tint = colors.textTertiary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }

            AnimatedUnderline(isFocused = isFocused)

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = footnote,
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
                maxLines = 3,
            )
        }
    }
}

@Composable
private fun AnimatedUnderline(isFocused: Boolean) {
    val colors = OriveoTheme.colors
    val widthFraction by animateFloatAsState(
        targetValue = if (isFocused) 1f else 0f,
        animationSpec = spring(
            dampingRatio = 0.78f,
            stiffness = Spring.StiffnessMediumLow,
        ),
        label = "underlineWidth",
    )
    Box(modifier = Modifier
        .fillMaxWidth()
        .height(2.5.dp),
    ) {

        Box(modifier = Modifier
            .fillMaxWidth()
            .height(1.5.dp)
            .background(colors.border)
            .align(Alignment.BottomCenter),
        )

        Box(modifier = Modifier
            .fillMaxWidth(widthFraction)
            .height(2.5.dp)
            .background(OriveoGradients.primary)
            .align(Alignment.BottomStart),
        )
    }
}

// MARK: - Examples List

@Composable
private fun ExamplesList(onPick: (String) -> Unit) {
    val examples = remember {
        listOf(
            ExampleSuggestion("gpt-4o", ProviderKind.OpenAI),
            ExampleSuggestion("claude-sonnet-4.5", ProviderKind.Anthropic),
            ExampleSuggestion("gemini-2.5-flash", ProviderKind.Gemini),
        )
    }
    val colors = OriveoTheme.colors

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SectionCaps(text = stringResource(R.string.common_examples))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surface, RoundedCornerShape(16.dp))
                .border(0.5.dp, colors.border, RoundedCornerShape(16.dp))
                .shadow(
                    elevation = 4.dp,
                    shape = RoundedCornerShape(16.dp),
                    ambientColor = colors.shadow.copy(alpha = colors.shadow.alpha * 0.6f),
                    spotColor = colors.shadow.copy(alpha = colors.shadow.alpha * 0.6f),
                ),
        ) {
            examples.forEachIndexed { idx, example ->
                ExampleRow(suggestion = example, onTap = { onPick(example.modelID) })
                if (idx < examples.lastIndex) {
                    HorizontalDivider(
                        color = colors.border,
                        thickness = 0.5.dp,
                        modifier = Modifier.padding(start = 60.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ExampleRow(suggestion: ExampleSuggestion, onTap: () -> Unit) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow),
        label = "exampleRowScale",
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onTap,
            )
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .padding(horizontal = 14.dp, vertical = 14.dp),
    ) {
        ProviderBadgeIcon(kind = suggestion.providerKind, size = 32.dp)

        Text(
            text = suggestion.modelID,
            style = TextStyle(
                color = colors.textPrimary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = FontFamily.Monospace,
            ),
            maxLines = 1,
            overflow = TextOverflow.MiddleEllipsis,
            modifier = Modifier.weight(1f),
        )

        Icon(
            Icons.Filled.NorthWest,
            contentDescription = stringResource(R.string.tap_to_fill),
            tint = colors.primary.copy(alpha = 0.85f),
            modifier = Modifier.size(18.dp),
        )
    }
}

private data class ExampleSuggestion(
    val modelID: String,
    val providerKind: ProviderKind,
)

// MARK: - Preview Card

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PreviewCard(provider: Provider, modelID: String) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(18.dp)

    val defaultCapabilities = ProviderRepository.DEFAULT_MANUAL_MODEL_CAPABILITIES

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 14.dp,
                shape = shape,
                ambientColor = colors.primaryGlow,
                spotColor = colors.primaryGlow,
            )
            .clip(shape)
            .background(colors.primarySoft, shape)
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = if (isDark) 0.04f else 0.30f),
                        Color.Transparent,
                    ),
                ),
                shape = shape,
            )
            .border(0.5.dp, colors.primary.copy(alpha = 0.22f), shape)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Header: ✨ + WILL BE ADDED
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(14.dp),
            )
            SectionCaps(text = stringResource(R.string.will_be_added))
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ProviderBadgeIcon(
                kind = provider.kind,
                size = 36.dp,
                relayKind = if (provider.kind == ProviderKind.Relay) provider.relayKind else null,
            )
            Text(
                text = modelID,
                style = TextStyle(
                    color = colors.textPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                ),
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
                modifier = Modifier.weight(1f),
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionCaps(text = stringResource(R.string.default_capabilities_label))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                defaultCapabilities.forEach { cap ->
                    CapabilityChip(capability = cap)
                }
            }
        }
    }
}

@Composable
private fun CapabilityChip(capability: ModelCapability) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .clip(CircleShape)
            .background(Color.White.copy(alpha = if (isDark) 0.10f else 0.55f), CircleShape)
            .border(0.5.dp, colors.primary.copy(alpha = 0.20f), CircleShape)
            .padding(horizontal = 9.dp, vertical = 5.dp),
    ) {
        Icon(
            capabilityIcon(capability),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(11.dp),
        )
        Text(
            text = stringResource(capability.titleResId),
            style = TextStyle(
                color = colors.primary,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            ),
        )
    }
}

// MARK: - Bottom Bar

@Composable
private fun BottomBar(
    isRelayMode: Boolean,
    canSave: Boolean,
    isSaving: Boolean,
    isRetrying: Boolean,
    onSave: () -> Unit,
    onRetry: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val layout = OriveoTheme.layout

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surfaceChrome)
            .border(0.5.dp, colors.border, RoundedCornerShape(0.dp))
            .padding(horizontal = layout.screenH)
            .padding(top = 16.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        OriveoPrimaryButton(
            text = stringResource(if (isRelayMode) R.string.save else R.string.save_and_continue),
            onClick = onSave,
            enabled = canSave,
            loading = isSaving,
        )
        if (!isRelayMode) {
            OriveoSecondaryButton(
                text = stringResource(R.string.retry_sync),
                onClick = onRetry,
                enabled = !isRetrying && !isSaving,
                loading = isRetrying,
            )
        }
    }
}
