package ai.oriveo.community.feature.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.feature.chat.ContextCapCommit
import ai.oriveo.community.feature.chat.ContextCapPresentation
import ai.oriveo.community.feature.chat.ContextCapSettingsSelection
import ai.oriveo.community.ui.component.FlatGroup
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoSettingsRow
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/**
 * Settings › Context: the global default input cap (auto / unlimited / custom), the price-line reminder
 * switch, then the single choice between keeping only the user's messages and an AI summary.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextSettingsScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: ContextSettingsViewModel = koinViewModel(),
) {
    val colors = OriveoTheme.colors
    val aiSummaryEnabled by viewModel.aiSummaryEnabled.collectAsStateWithLifecycle()
    val defaultCap by viewModel.defaultCap.collectAsStateWithLifecycle()
    val priceLineReminderEnabled by viewModel.priceLineReminderEnabled.collectAsStateWithLifecycle()

    Box(modifier = Modifier.fillMaxSize().testTag("context_settings_screen")) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.settings_context_title),
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = { OriveoBackButton(onClick = onNavigateBack) },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                DefaultCapGroup(
                    cap = defaultCap,
                    onSelect = viewModel::setDefaultCap,
                    onSelectCustom = viewModel::selectCustomDefaultCap,
                    onCommit = viewModel::commitDefaultCap,
                )
                PriceLineReminderGroup(
                    enabled = priceLineReminderEnabled,
                    onChange = viewModel::setPriceLineReminderEnabled,
                )
                FlatSectionHeader(title = stringResource(R.string.settings_context_overflow_header))
                FlatGroup {
                    ContextModeOptionRow(
                        title = stringResource(R.string.settings_context_mode_fallback),
                        hint = stringResource(R.string.settings_context_mode_fallback_hint),
                        selected = !aiSummaryEnabled,
                        tag = "settings_context_fallback_option",
                        onClick = { viewModel.setAISummaryEnabled(false) },
                    )
                    InsetHairline()
                    ContextModeOptionRow(
                        title = stringResource(R.string.settings_context_mode_ai),
                        hint = stringResource(R.string.settings_context_mode_ai_hint),
                        selected = aiSummaryEnabled,
                        tag = "settings_context_ai_summary_option",
                        onClick = { viewModel.setAISummaryEnabled(true) },
                    )
                }
                Text(
                    text = stringResource(R.string.settings_context_overflow_footer),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(horizontal = OriveoTheme.spacing.sm),
                )
            }
        }
    }
}

/** Default cap group (contract P9·U7 rule 4): options, custom input with echo and adjusted hint, footer. */
@Composable
private fun DefaultCapGroup(
    cap: ContextBudgetCap,
    onSelect: (ContextBudgetCap) -> Unit,
    onSelectCustom: () -> Unit,
    onCommit: (String) -> ContextCapCommit,
) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val presentation = ContextCapPresentation.settings(cap)
    val selected = presentation.selected

    FlatSectionHeader(title = stringResource(R.string.settings_context_cap_header))
    FlatGroup {
        ContextModeOptionRow(
            title = stringResource(R.string.context_cap_auto),
            hint = null,
            selected = selected == ContextCapSettingsSelection.AUTO,
            tag = "settings_context_cap_auto_option",
            onClick = { onSelect(ContextBudgetCap.Auto) },
        )
        InsetHairline()
        ContextModeOptionRow(
            title = stringResource(R.string.context_cap_unlimited),
            hint = null,
            selected = selected == ContextCapSettingsSelection.UNLIMITED,
            tag = "settings_context_cap_unlimited_option",
            onClick = { onSelect(ContextBudgetCap.Unlimited) },
        )
        InsetHairline()
        ContextModeOptionRow(
            title = stringResource(R.string.context_cap_custom),
            hint = null,
            selected = selected == ContextCapSettingsSelection.CUSTOM,
            tag = "settings_context_cap_custom_option",
            onClick = { if (selected != ContextCapSettingsSelection.CUSTOM) onSelectCustom() },
        )
        if (selected == ContextCapSettingsSelection.CUSTOM) {
            CustomCapInput(prefill = presentation.customPrefill, locale = locale, onCommit = onCommit)
        }
    }
    Text(
        text = stringResource(
            R.string.settings_context_cap_footer,
            ContextCapPresentation.isolatedCompact(ContextBudget.AUTO_CAP_DEFAULT.toLong(), locale),
            ContextCapPresentation.isolatedCompact(ContextBudget.CUSTOM_CAP_MIN.toLong(), locale),
        ),
        style = OriveoTheme.typography.footnote,
        color = colors.textSecondary,
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.sm),
    )
}

/** Price-line reminder switch (contract P9·U8) and its footnote. */
@Composable
private fun PriceLineReminderGroup(
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
) {
    FlatGroup {
        OriveoSettingsRow(
            title = stringResource(R.string.settings_context_price_line_reminder),
            showChevron = false,
            trailingContent = {
                Switch(
                    checked = enabled,
                    onCheckedChange = onChange,
                    modifier = Modifier,
                )
            },
            modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg, vertical = 9.dp),
        )
    }
    Text(
        text = stringResource(R.string.settings_context_price_line_reminder_footer),
        style = OriveoTheme.typography.footnote,
        color = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.sm),
    )
}

/** Raw token input; commits on Done or focus loss, echoes the compact value and shows the adjusted hint. */
@Composable
private fun CustomCapInput(
    prefill: Int,
    locale: String,
    onCommit: (String) -> ContextCapCommit,
) {
    val colors = OriveoTheme.colors
    val focusManager = LocalFocusManager.current
    // Reset to the stored value whenever storage changes (commit, clamp, restore).
    var text by rememberSaveable(prefill) { mutableStateOf(prefill.toString()) }
    var adjustedTo by remember { mutableStateOf<Int?>(null) }
    var focused by remember { mutableStateOf(false) }

    fun commit() {
        val result = onCommit(text)
        adjustedTo = if (result.adjusted) result.value else null
        text = result.value.toString()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = {
                text = it
                adjustedTo = null
            },
            singleLine = true,
            label = { Text(stringResource(R.string.context_cap_input_label)) },
            suffix = { Text(stringResource(R.string.context_cap_input_unit)) },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { state ->
                    if (focused && !state.isFocused) commit()
                    focused = state.isFocused
                },
        )
        // Echo = the clamped value a commit would store (hidden when unreadable); shown alongside "adjusted".
        val echo = ContextCapPresentation.echoValue(text, u = null)
        if (echo != null) {
            Text(
                text = stringResource(
                    R.string.context_cap_input_echo,
                    ContextCapPresentation.isolatedCompact(echo.toLong(), locale),
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
        adjustedTo?.let { adjusted ->
            Text(
                text = stringResource(
                    R.string.context_cap_adjusted,
                    ContextCapPresentation.isolatedCompact(adjusted.toLong(), locale),
                ),
                style = OriveoTheme.typography.footnote,
                color = colors.warningText,
            )
        }
    }
}

@Composable
private fun ContextModeOptionRow(
    title: String,
    hint: String?,
    selected: Boolean,
    /** One tag for the whole row and its radio, same name as iOS. */
    tag: String,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp, horizontal = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(
            selected = selected,
            onClick = onClick,
            modifier = Modifier,
        )
        Column(modifier = Modifier.weight(1f).padding(top = 3.dp)) {
            Text(
                text = title,
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            if (hint != null) {
                Text(
                    text = hint,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
        }
    }
}
