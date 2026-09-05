package ai.oriveo.community.feature.settings

import android.content.Intent
import android.net.Uri
import android.widget.Toast
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.StarRate
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.outlined.Autorenew
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.FolderShared
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.feature.home.resolveBackendDomainLabel
import ai.oriveo.community.feature.onboarding.OnboardingFlowScreen
import ai.oriveo.community.feature.onboarding.OnboardingViewModel
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.component.UserAvatarImage
import ai.oriveo.community.ui.component.FlatGroup
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.FlatTapRow
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.OriveoWebDestination
import ai.oriveo.community.ui.component.OriveoSettingsRow
import ai.oriveo.community.ui.component.openOriveoWebPage
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.util.findActivity
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigateToMemory: () -> Unit = {},
    onNavigateToBackup: () -> Unit = {},
    onNavigateToSkills: () -> Unit = {},
    viewModel: SettingsViewModel = koinViewModel(),
) {
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val language by viewModel.language.collectAsStateWithLifecycle()
    val memoryText by viewModel.memoryText.collectAsStateWithLifecycle()
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val resources = LocalResources.current

    
    val aiColor = colors.primary
    val dataColor = colors.info
    val appearanceColor = colors.warning
    val feedbackColor = colors.info
    val faqColor = colors.primary
    val rateColor = colors.warning
    val updateColor = colors.info

    var showThemePicker by remember { mutableStateOf(false) }
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

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.settings_title),
                            style = OriveoTheme.typography.title1,
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
                verticalArrangement = Arrangement.spacedBy(layout.sectionGap),
            ) {
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.xs))
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    FlatSectionHeader(title = "AI")

                    FlatGroup {
                        FlatTapRow(onClick = onNavigateToMemory) {
                            OriveoSettingsRow(
                                icon = Icons.Outlined.Psychology,
                                iconColor = aiColor,
                                title = stringResource(R.string.memory_title),
                                subtitle = memoryRowDetails.subtitle,
                                value = memoryRowDetails.value,
                            )
                        }
                        InsetHairline()
                        FlatTapRow(onClick = onNavigateToSkills) {
                            OriveoSettingsRow(
                                icon = Icons.Outlined.Lightbulb,
                                iconColor = aiColor,
                                title = stringResource(R.string.skills_title),
                            )
                        }
                    }
                }

                
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    FlatSectionHeader(title = stringResource(R.string.data_section))

                    FlatGroup {
                        FlatTapRow(onClick = onNavigateToBackup) {
                            OriveoSettingsRow(
                                icon = Icons.Filled.CloudUpload,
                                iconColor = dataColor,
                                title = stringResource(R.string.backup_and_export),
                            )
                        }
                    }
                }

                
                
                
                

                
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    FlatSectionHeader(title = stringResource(R.string.appearance))

                    FlatGroup {
                        FlatTapRow(onClick = { showThemePicker = true }) {
                            OriveoSettingsRow(
                                icon = Icons.Filled.Brightness6,
                                iconColor = appearanceColor,
                                title = stringResource(R.string.theme),
                                value = themeSummaryLabel(
                                    theme = theme,
                                    systemLabel = stringResource(R.string.theme_system),
                                    lightLabel = stringResource(R.string.theme_light),
                                    darkLabel = stringResource(R.string.theme_dark),
                                ),
                            )
                        }
                        InsetHairline()
                        FlatTapRow(onClick = { showLanguagePicker = true }) {
                            OriveoSettingsRow(
                                icon = Icons.Filled.Language,
                                iconColor = appearanceColor,
                                title = stringResource(R.string.language),
                                value = languageSummaryLabel(
                                    language = language,
                                    systemLabel = stringResource(R.string.theme_system),
                                ),
                            )
                        }
                    }
                }

                
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    FlatSectionHeader(title = stringResource(R.string.help_feedback))

                    FlatGroup {
                        FlatTapRow(
                            onClick = { context.openOriveoWebPage(OriveoWebDestination.SourceCode) },
                        ) {
                            OriveoSettingsRow(
                                icon = Icons.AutoMirrored.Filled.HelpOutline,
                                iconColor = faqColor,
                                title = stringResource(R.string.settings_source_code),
                            )
                        }
                        InsetHairline()
                        FlatTapRow(
                            onClick = { context.openOriveoWebPage(OriveoWebDestination.Issues) },
                        ) {
                            OriveoSettingsRow(
                                icon = Icons.Filled.Email,
                                iconColor = feedbackColor,
                                title = stringResource(R.string.settings_report_issue),
                            )
                        }
                    }
                }


                
                Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                    FlatSectionHeader(title = stringResource(R.string.about))

                    FlatGroup {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    context.openOriveoWebPage(OriveoWebDestination.Changelog)
                                }
                                .padding(OriveoTheme.spacing.lg),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            val logoInteraction = remember { MutableInteractionSource() }
                            Image(
                                painter = rememberBrandPainter(R.drawable.ic_oriveo_logo, 44.dp),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .size(44.dp)
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
                            Spacer(modifier = Modifier.width(OriveoTheme.spacing.md))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = stringResource(R.string.app_name),
                                    style = OriveoTheme.typography.title3,
                                    color = colors.textPrimary,
                                )
                                Text(
                                    text = stringResource(R.string.app_tagline),
                                    style = OriveoTheme.typography.caption,
                                    color = colors.textTertiary,
                                )
                            }
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                contentDescription = null,
                                tint = colors.textTertiary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }

                    // The legal links are a light footer: centred small grey text with a
                    // separator dot. They sit outside the card, so no hairline above them.
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val privacyInteraction = remember { MutableInteractionSource() }
                        val termsInteraction = remember { MutableInteractionSource() }
                        Text(
                            text = stringResource(R.string.privacy_policy),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                            modifier = Modifier.clickable(
                                interactionSource = privacyInteraction,
                                indication = null,
                            ) { context.openOriveoWebPage(OriveoWebDestination.PrivacyPolicy) },
                        )
                        Text(
                            text = "·",
                            style = OriveoTheme.typography.footnote,
                            color = colors.textTertiary,
                        )
                        Text(
                            text = stringResource(R.string.terms_of_service),
                            style = OriveoTheme.typography.footnote,
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
        Dialog(
            onDismissRequest = { showOnboardingRehearsal = false },
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
            ),
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                OnboardingFlowScreen(
                    reduceMotion = rehearsalReduceMotion,
                    onActViewed = {},
                    onSkipUsed = {},
                    onGetStarted = { showOnboardingRehearsal = false },
                    onBack = { showOnboardingRehearsal = false },
                )
            }
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
        AlertDialog(
            onDismissRequest = { showApiEndpointDialog = false },
            title = { Text(stringResource(R.string.api_endpoint)) },
            text = { Text(resolveBackendDomainLabel()) },
            confirmButton = {
                TextButton(onClick = { showApiEndpointDialog = false }) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }

    if (showThemePicker) {
        ModalBottomSheet(
            onDismissRequest = { showThemePicker = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            dragHandle = { OriveoSheetDragHandle() },
        ) {
            Column(modifier = Modifier.padding(OriveoTheme.spacing.lg)) {
                Text(stringResource(R.string.theme), style = OriveoTheme.typography.title2)
                Spacer(modifier = Modifier.height(OriveoTheme.spacing.lg))
                ThemeOption.entries.forEach { option ->
                    val label = themeSummaryLabel(
                        theme = option,
                        systemLabel = stringResource(R.string.theme_system),
                        lightLabel = stringResource(R.string.theme_light),
                        darkLabel = stringResource(R.string.theme_dark),
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                viewModel.setTheme(option)
                                showThemePicker = false
                            }
                            .padding(vertical = OriveoTheme.spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = option == theme,
                            onClick = {
                                viewModel.setTheme(option)
                                showThemePicker = false
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

    if (showLanguagePicker) {
        ModalBottomSheet(
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

@Composable
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

@Composable
private fun AccountHubProfileRow(
    title: String,
    subtitle: String,
    avatarURL: String?,
    avatarLocalID: String?,
    fallbackName: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(58.dp)
                    .background(colors.primary.copy(alpha = 0.10f), RoundedCornerShape(29.dp))
                    .blur(8.dp),
            )
            UserAvatarImage(
                size = 50.dp,
                avatarURL = avatarURL,
                avatarLocalID = avatarLocalID,
                fallbackName = fallbackName,
                modifier = Modifier.border(
                    1.dp,
                    if (OriveoTheme.colors.backgroundBase == DarkOriveoColors.backgroundBase)
                        OriveoTheme.colors.cardHighlight.opacity(5.25f)
                    else Color.White.copy(alpha = 0.42f),
                    RoundedCornerShape(25.dp)
                ),
            )
        }
        Spacer(modifier = Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
            )
            Text(
                text = subtitle,
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textTertiary,
            modifier = Modifier.size(18.dp),
        )
    }
}
