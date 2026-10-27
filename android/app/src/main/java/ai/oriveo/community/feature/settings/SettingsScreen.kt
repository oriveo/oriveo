package ai.oriveo.community.feature.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.add
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.lifecycle.compose.LifecycleResumeEffect
import ai.oriveo.community.core.app.resolve
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.outlined.Autorenew
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.FolderShared
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Compress
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import ai.oriveo.community.ui.component.OriveoFullScreenDialog
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import androidx.compose.material3.TextButton
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.component.rootTabTopInset
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.outlined.AutoAwesome
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.feature.home.resolveBackendDomainLabel
import ai.oriveo.community.feature.onboarding.OnboardingFlowScreen
import ai.oriveo.community.feature.onboarding.OnboardingViewModel
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.feature.chat.ContextCapPresentation
import ai.oriveo.community.ui.component.FlatGroup
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.FlatTapRow
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.OriveoWebDestination
import ai.oriveo.community.ui.component.OriveoSettingsRow
import ai.oriveo.community.ui.component.FeatureBadgeDot
import ai.oriveo.community.ui.component.openOriveoWebPage
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.util.findActivity
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigateToMemory: () -> Unit = {},
    onNavigateToContextSettings: () -> Unit = {},
    onNavigateToThemeSettings: () -> Unit = {},
    onNavigateToMcpServers: () -> Unit = {},
    onNavigateToBackup: () -> Unit = {},
    onNavigateToSkills: () -> Unit = {},
    onNavigateToVoiceSettings: () -> Unit = {},
    viewModel: SettingsViewModel = koinViewModel(),
) {
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val darkPalette by viewModel.darkPalette.collectAsStateWithLifecycle()
    val language by viewModel.language.collectAsStateWithLifecycle()
    val memoryText by viewModel.memoryText.collectAsStateWithLifecycle()
    val showMemoryFeatureBadge by viewModel.memoryFeatureBadgeVisible.collectAsStateWithLifecycle()
    val contextAISummaryEnabled by viewModel.contextAISummaryEnabled.collectAsStateWithLifecycle()
    val contextDefaultCap by viewModel.contextDefaultCap.collectAsStateWithLifecycle()
    val voiceEngineLabel by viewModel.voiceEngineLabel.collectAsStateWithLifecycle()
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val context = LocalContext.current
    val resources = LocalResources.current

    // Re-read the read-aloud engine every time the page returns to the foreground: it may have changed on the voice page.
    LifecycleResumeEffect(viewModel) {
        viewModel.refreshVoiceEngineLabel()
        onPauseOrDispose { }
    }

    // Semantic icon colors kept for the two rows in the developer menu
    val aiColor = colors.primary
    val dataColor = colors.info

    var showLanguagePicker by remember { mutableStateOf(false) }
    var aboutTapCount by remember { mutableStateOf(0) }
    var showApiEndpointDialog by remember { mutableStateOf(false) }
    var showDeveloperMenu by remember { mutableStateOf(false) }

    var showOnboardingRehearsal by remember { mutableStateOf(false) }
    val memoryRowDetails = remember(memoryText, resources) {
        memoryRowContent(
            memoryText = memoryText,
            notSetLabel = resources.getString(R.string.memory_not_set),
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()
        // The dark top glow belongs to the settings home only; the shared background stays untouched.
        SettingsHomeTopGlow()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.settings_title),
                            style = OriveoTheme.typography.title1.copy(
                                fontSize = 34.sp,
                                fontWeight = FontWeight.ExtraBold,
                                letterSpacing = (-0.03).em,
                            ),
                            color = OriveoTheme.colors.textPrimary,
                        )
                    },

                    windowInsets = TopAppBarDefaults.windowInsets
                        .only(WindowInsetsSides.Horizontal)
                        .add(WindowInsets(top = rootTabTopInset())),
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            val layout = OriveoTheme.layout
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = layout.screenH)
                    .padding(bottom = OriveoTheme.layout.tabBarOverlay),
            ) {
                // AI grid: memory, context, skills, voice (2x2)
                Spacer(modifier = Modifier.height(20.dp))
                SettingsSectionTitle(text = "AI")
                Spacer(modifier = Modifier.height(10.dp))
                SettingsGrid(
                    items = listOf(
                        SettingsGridItem(
                            key = "memory",
                            icon = R.drawable.ic_settings_memory,
                            title = stringResource(R.string.memory_title),
                            tag = "settings_memory_tile",
                            value = memoryRowDetails.value,
                            showBadge = showMemoryFeatureBadge,
                            onClick = onNavigateToMemory,
                        ),
                        SettingsGridItem(
                            key = "context",
                            icon = R.drawable.ic_settings_context,
                            title = stringResource(R.string.settings_context_title),
                            // The context cell keeps the tag and testTag of the old row (E2E locator).
                            tag = "settings_context_row",
                            value = ContextCapPresentation.settingsRowValue(
                                template = stringResource(R.string.settings_context_row_value),
                                cap = contextDefaultCap,
                                mode = stringResource(
                                    if (contextAISummaryEnabled) {
                                        R.string.settings_context_mode_ai
                                    } else {
                                        R.string.settings_context_row_value_fallback
                                    },
                                ),
                                autoLabel = stringResource(R.string.context_cap_auto),
                                unlimitedLabel = stringResource(R.string.context_cap_unlimited),
                                locale = LocalConfiguration.current.locales[0].toLanguageTag(),
                            ),
                            onClick = onNavigateToContextSettings,
                        ),
                        // Skills have no "enabled" notion, so no value is shown.
                        SettingsGridItem(
                            key = "skills",
                            icon = R.drawable.ic_settings_skills,
                            title = stringResource(R.string.skills_title),
                            tag = "settings_skills_tile",
                            onClick = onNavigateToSkills,
                        ),
                        SettingsGridItem(
                            key = "voice",
                            icon = R.drawable.ic_settings_voice,
                            title = stringResource(R.string.voice_settings_title),
                            // The voice cell keeps the tag and testTag of the old row.
                            tag = "settings_voice_row",
                            value = voiceEngineLabel?.resolve(context),
                            onClick = onNavigateToVoiceSettings,
                        ),
                    ),
                )

                // Tools & connections: the MCP servers cell (hidden entirely while the MCP master switch is off)
                Spacer(modifier = Modifier.height(34.dp))
                ai.oriveo.community.feature.mcp.SettingsToolsSection(
                    onNavigateToMcpServers = onNavigateToMcpServers,
                )

                // General: theme, language, backup and export/import
                Spacer(modifier = Modifier.height(34.dp))
                SettingsSectionTitle(text = stringResource(R.string.settings_section_general))
                Spacer(modifier = Modifier.height(4.dp))
                Column {
                    SettingsListRow(
                        iconRes = R.drawable.ic_settings_theme,
                        title = stringResource(R.string.theme),
                        onClick = onNavigateToThemeSettings,
                        showDivider = true,
                        value = themeSummaryLabel(
                            theme = theme,
                            darkPalette = darkPalette,
                            appearanceLabel = { resources.getString(themeAppearanceNameRes(it)) },
                            paletteLabel = { resources.getString(themeSwatchNameRes(it)) },
                            appearanceWithPalette = { appearance, name ->
                                resources.getString(themeSummaryWithPaletteRes(appearance), name)
                            },
                        ),
                        // The color dot only shows in dark.
                        leadingValueDot = if (isDark) settingsThemeDotBrush(colors.primary, colors.accent) else null,
                    )
                    SettingsListRow(
                        iconRes = R.drawable.ic_settings_language,
                        title = stringResource(R.string.language),
                        onClick = { showLanguagePicker = true },
                        showDivider = true,
                        value = languageSummaryLabel(
                            language = language,
                            systemLabel = stringResource(R.string.theme_system),
                        ),
                    )
                    SettingsListRow(
                        iconRes = R.drawable.ic_settings_backup,
                        title = stringResource(R.string.backup_and_export),
                        onClick = onNavigateToBackup,
                        showDivider = false,
                    )
                }

                // Help & about: report an issue, source code (1x2)
                Spacer(modifier = Modifier.height(34.dp))
                SettingsSectionTitle(text = stringResource(R.string.settings_section_help_about))
                Spacer(modifier = Modifier.height(10.dp))
                SettingsGrid(
                    style = SettingsGridStyle.Compact,
                    items = listOf(
                        SettingsGridItem(
                            key = "issue",
                            icon = R.drawable.ic_settings_feedback,
                            title = stringResource(R.string.settings_report_issue),
                            tag = "settings_issue_tile",
                            onClick = { context.openOriveoWebPage(OriveoWebDestination.Issues) },
                        ),
                        SettingsGridItem(
                            key = "source",
                            icon = R.drawable.ic_settings_faq,
                            title = stringResource(R.string.settings_source_code),
                            tag = "settings_source_code_tile",
                            onClick = { context.openOriveoWebPage(OriveoWebDestination.SourceCode) },
                        ),
                    ),
                )

                // Footer: logo, name + version, tagline, legal links
                Spacer(modifier = Modifier.height(38.dp))
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    // Footer logo: ten taps open the developer options; it stays out of the accessibility tree.
                    val logoInteraction = remember { MutableInteractionSource() }
                    Image(
                        painter = rememberBrandPainter(R.drawable.ic_oriveo_logo, 40.dp),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .clickable(
                                interactionSource = logoInteraction,
                                indication = null,
                            ) {
                                val result = registerAboutLogoTap(aboutTapCount)
                                aboutTapCount = result.nextCount
                                if (result.shouldRevealEndpoint) {
                                    showDeveloperMenu = true
                                }
                            }
                            .clearAndSetSemantics {},
                    )
                    // The "name + version" line opens the changelog.
                    Row(
                        modifier = Modifier
                            .padding(top = 4.dp)
                            .clickable {
                                context.openOriveoWebPage(OriveoWebDestination.Changelog)
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.app_name),
                            style = OriveoTheme.typography.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.Bold),
                            color = colors.textPrimary,
                        )
                        Text(
                            text = formatAppVersion(
                                versionName = BuildConfig.VERSION_NAME,
                                versionCode = BuildConfig.VERSION_CODE,
                            ),
                            style = OriveoTheme.typography.code.copy(fontSize = 11.5.sp),
                            color = colors.textTertiary,
                        )
                    }
                    Text(
                        text = stringResource(R.string.app_tagline),
                        modifier = Modifier.padding(top = 2.dp),
                        style = OriveoTheme.typography.footnote.copy(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                    // Legal links: centered small grey text with a separator dot, no row or rule.
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val privacyInteraction = remember { MutableInteractionSource() }
                        val termsInteraction = remember { MutableInteractionSource() }
                        Text(
                            text = stringResource(R.string.privacy_policy),
                            style = OriveoTheme.typography.footnote.copy(fontSize = 12.sp),
                            color = colors.textTertiary,
                            modifier = Modifier.clickable(
                                interactionSource = privacyInteraction,
                                indication = null,
                            ) { context.openOriveoWebPage(OriveoWebDestination.PrivacyPolicy) },
                        )
                        Text(
                            text = "·",
                            style = OriveoTheme.typography.footnote.copy(fontSize = 12.sp),
                            color = colors.textTertiary,
                        )
                        Text(
                            text = stringResource(R.string.terms_of_service),
                            style = OriveoTheme.typography.footnote.copy(fontSize = 12.sp),
                            color = colors.textTertiary,
                            modifier = Modifier.clickable(
                                interactionSource = termsInteraction,
                                indication = null,
                            ) { context.openOriveoWebPage(OriveoWebDestination.TermsOfService) },
                        )
                    }
                }

                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))
        }
    }

    if (showOnboardingRehearsal) {
        val rehearsalContext = LocalContext.current
        val rehearsalReduceMotion = remember(rehearsalContext) { isReduceMotionEnabled(rehearsalContext) }

        val rehearsalViewModel: OnboardingViewModel = koinViewModel()
        // The toast host inside the full-screen dialog keeps link failures on the last page visible.
        OriveoFullScreenDialog(onDismissRequest = { showOnboardingRehearsal = false }) {
            OnboardingFlowScreen(
                reduceMotion = rehearsalReduceMotion,
                onActViewed = {},
                onSkipUsed = {},
                onGetStarted = { showOnboardingRehearsal = false },
                onBack = { showOnboardingRehearsal = false },
            )
        }
    }

    if (showDeveloperMenu) {
        AlertDialog(
            onDismissRequest = { showDeveloperMenu = false },
            title = { Text(stringResource(R.string.developer_options)) },
            text = {
                Column {
                    FlatTapRow(onClick = {
                        showDeveloperMenu = false
                        showApiEndpointDialog = true
                    }) {
                        OriveoSettingsRow(
                            icon = Icons.Filled.Language,
                            iconColor = dataColor,
                            title = stringResource(R.string.api_endpoint),
                        )
                    }
                    InsetHairline()
                    FlatTapRow(onClick = {
                        showDeveloperMenu = false
                        showOnboardingRehearsal = true
                    }) {
                        OriveoSettingsRow(
                            icon = Icons.Outlined.AutoAwesome,
                            iconColor = aiColor,
                            title = stringResource(R.string.replay_onboarding),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showDeveloperMenu = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    if (showApiEndpointDialog) {
        // An empty METADATA_BASE_URL is a supported build configuration: it means no model catalog
        // is fetched at all, so there is no host to name here.
        val catalogHost = resolveBackendDomainLabel(BuildConfig.METADATA_BASE_URL)
            .ifBlank { stringResource(R.string.api_endpoint_not_configured) }
        AlertDialog(
            onDismissRequest = { showApiEndpointDialog = false },
            title = { Text(stringResource(R.string.api_endpoint)) },
            text = { Text(catalogHost) },
            confirmButton = {
                TextButton(onClick = { showApiEndpointDialog = false }) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

    if (showLanguagePicker) {
        OriveoModalBottomSheet(
            onDismissRequest = { showLanguagePicker = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            dragHandle = { OriveoSheetDragHandle() },
        ) {
            Column(modifier = Modifier.padding(OriveoTheme.spacing.lg)) {
                Text(stringResource(R.string.language), style = OriveoTheme.typography.title2)
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                LanguageOption.entries.forEach { option ->
                    val label = languageSummaryLabel(
                        language = option,
                        systemLabel = stringResource(R.string.theme_system),
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                viewModel.setLanguage(option)
                                showLanguagePicker = false
                            }
                            .padding(vertical = OriveoTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = option == language,
                            onClick = {
                                viewModel.setLanguage(option)
                                showLanguagePicker = false
                            },
                        )
                        Spacer(modifier = Modifier.width(OriveoTheme.spacing.md))
                        Text(label, style = OriveoTheme.typography.caption)
                    }
                }
                Spacer(modifier = Modifier.height(OriveoTheme.layout.sectionGap))
            }
        }
    }
}
}

internal fun shouldStackSettingsHubCards(maxWidthDp: Float, fontScale: Float): Boolean =
    maxWidthDp < 322f || fontScale >= 1.3f

internal data class AboutLogoTapResult(
    val nextCount: Int,
    val shouldRevealEndpoint: Boolean,
)

internal fun registerAboutLogoTap(currentCount: Int): AboutLogoTapResult {
    val nextCount = currentCount + 1
    return if (nextCount >= 10) {
        AboutLogoTapResult(nextCount = 0, shouldRevealEndpoint = true)
    } else {
        AboutLogoTapResult(nextCount = nextCount, shouldRevealEndpoint = false)
    }
}
