package ai.oriveo.community.feature.providers.relay

import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoBackButtonDefaults

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.unit.LayoutDirection
import ai.oriveo.community.core.provider.RelayFormValidation
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.heading
import kotlinx.coroutines.delay
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.layout.heightIn
import ai.oriveo.community.R
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.providers.SetupBoardSlot
import ai.oriveo.community.feature.providers.local.LocalPrimaryAction
import ai.oriveo.community.ui.theme.ProviderBadgeColors
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryAttemptKind
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.local.LocalComputeSetupFields
import ai.oriveo.community.feature.providers.local.LocalComputeSetupViewModel
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.opacity
import org.koin.androidx.compose.koinViewModel

/**
 * Relay setup page: Quick Setup is a two-step add: step 1 is address + key + detection, step 2 selects models by group;
 * the display name is offered only after the user deliberately enters manual setup.
 */
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
    val showsModelsStep = routeMethod == CustomLLMConnectionMethod.Relay &&
        viewModel.mode == RelaySetupMode.Quick &&
        viewModel.step == RelaySetupStep.Models
    val showsManual = routeMethod == CustomLLMConnectionMethod.Relay && viewModel.mode == RelaySetupMode.Manual
    // System back on step 2 returns to step 1 (the detection card is kept).
    BackHandler(enabled = showsModelsStep) { viewModel.backToAddress() }
    // System back on the manual page = the top-left "Use quick setup instead": return to step 1, keep the input, discard anything in flight, and do not leave the add page.
    BackHandler(enabled = showsManual) { viewModel.showQuickSetup() }
    var actionBarHeightPx by remember { mutableStateOf(0) }
    val scrollBottomPadding = if (actionBarHeightPx > 0) {
        with(density) { actionBarHeightPx.toDp() } + spacing.md
    } else {
        spacing.lg
    }
    val scrollState = rememberScrollState()

    Box(modifier = Modifier.fillMaxSize()) {
        OriveoScreenBackground()
        RelayConstellationAtmosphere()

        Box(
            modifier = Modifier
                .fillMaxSize()
                .imePadding(),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // The page title of the add-page board is only the hero; the topBar keeps just the back button, and on the manual page it becomes the top-left "Use quick setup instead".
                // Step 2 (SetupModels) brings its own back button + title row, so no topBar is stacked on it.
                if (!showsModelsStep) RelaySetupTopBar(
                    quickSetupAction = if (showsManual) stringResource(viewModel.manualBoard.leadingActionRes) else null,
                    onBack = onBack,
                    onQuickSetup = viewModel::showQuickSetup,
                ) else Spacer(Modifier.statusBarsPadding()) // The back button + title row of step 2 must not run under the status bar.

                Column(
                    modifier = Modifier
                        .weight(1f)
                        .verticalScroll(scrollState)
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
                    } else if (showsModelsStep) {
                        RelaySetupModelsContent(viewModel)
                    } else if (showsManual) {
                        RelayManualSetupContent(viewModel)
                    } else {
                        RelayQuickSetupContent(viewModel)
                    }
                }
            }

            if (routeMethod == CustomLLMConnectionMethod.Local) {
                val localBoard = localViewModel.board
                LocalComputeActionBar(
                    action = localBoard.primaryButton,
                    isWorking = localBoard.isPrimaryLoading,
                    enabled = localBoard.isPrimaryEnabled,
                    secondaryRow = localBoard.secondaryRow,
                    onClick = localViewModel::runPrimaryAction,
                    onSecondary = localViewModel::toggleManualPicker,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            } else if (showsModelsStep) {
                RelayModelsActionBar(
                    board = viewModel.modelsBoard,
                    onSave = viewModel::save,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            } else if (showsManual) {
                RelayManualActionBar(
                    board = viewModel.manualBoard,
                    onValidate = viewModel::validateManual,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            } else {
                RelayStepOneActionBar(
                    board = viewModel.board,
                    onNext = viewModel::next,
                    onCancelDetection = viewModel::cancelDetection,
                    onSecondary = viewModel::showManualSetup,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .onSizeChanged { actionBarHeightPx = it.height },
                )
            }
        }
    }
}

/**
 * Top bar: quick setup has only a back button; manual setup has a text button "Use quick setup instead" at the top left (no arrow, no separate back button,
 * footnote SemiBold in three tiers: 100% on one line -> 85% on one line -> 85% wrapping as needed with no line limit, never truncated, and no symmetric blank space on the right).
 */
@Composable
private fun RelaySetupTopBar(
    quickSetupAction: String?,
    onBack: () -> Unit,
    onQuickSetup: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 24.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (quickSetupAction != null) {
            val baseStyle = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold)
            val measurer = rememberTextMeasurer()
            BoxWithConstraints(modifier = Modifier.weight(1f, fill = false)) {
                // Measure the one-line width at 100% font size to pick the tier; no continuous auto-shrinking.
                val fullSizeLineWidth = remember(quickSetupAction, baseStyle) {
                    measurer.measure(quickSetupAction, baseStyle, maxLines = 1, softWrap = false).size.width.toFloat()
                }
                val tier = relayQuickSetupButtonTier(constraints.maxWidth.toFloat(), fullSizeLineWidth)
                Text(
                    text = quickSetupAction,
                    style = baseStyle.copy(
                        fontSize = baseStyle.fontSize * tier.scale,
                        lineHeight = baseStyle.lineHeight * tier.scale,
                    ),
                    color = OriveoTheme.colors.primaryTextSafe,
                    maxLines = tier.maxLines,
                    softWrap = tier.maxLines > 1,
                    modifier = Modifier
                        .clip(RoundedCornerShape(OriveoTheme.radius.inset))
                        .clickable(onClick = onQuickSetup)
                        .semantics { role = Role.Button }
                        .padding(vertical = 6.dp),
                )
            }
            return@Row
        }
        OriveoBackButton(
            onClick = onBack,
            // Line the icon box up with the page margin
            modifier = Modifier.offset(x = -OriveoBackButtonDefaults.EdgeInset),
        )
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
    val board = viewModel.board

    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        SetupBoardHero(
            icon = painterResource(R.drawable.ph_hard_drives),
            label = stringResource(board.heroLabel),
            title = stringResource(board.heroTitle),
            subtitle = stringResource(board.heroSubtitle),
            tint = colors.primary,
        )

        board.slots.forEach { slot ->
            when (slot) {
                SetupBoardSlot.Address -> Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    RelayQuickField(
                        label = stringResource(R.string.relay_field_endpoint),
                        value = viewModel.endpoint,
                        onValueChange = viewModel::updateEndpoint,
                        placeholder = RELAY_ENDPOINT_PLACEHOLDER,
                        icon = painterResource(R.drawable.ph_link),
                        keyboardType = KeyboardType.Uri,
                        selectionRange = viewModel.endpointHighlightRange,
                        schemeChip = setupSchemeChip(viewModel.endpoint, cleartext = false),
                    )
                    board.willRequest?.let { RelayWillRequestLine(it) }
                }
                SetupBoardSlot.ApiKey -> Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    RelaySetupKeyList(viewModel, board.keys)
                    viewModel.keyInputIssue?.let { Text(it, style = OriveoTheme.typography.footnote, color = colors.warning) }
                }
                SetupBoardSlot.AddKey -> RelayKeysFootnoteRow(stringResource(board.keysFootnote), onAdd = viewModel::addKey)
            }
        }

        board.detection?.let { RelayDetectionCardView(it) }

        RelayFormIssueNotes(issues = viewModel.formIssues)
    }
}

/** The key slots shared by step 1 and manual setup: each key has an "API Key" title row, and with two or more keys each also has a name slot. */
@Composable
private fun RelaySetupKeyList(viewModel: RelaySetupViewModel, keys: List<RelaySetupKeyRow>) {
    keys.forEach { key ->
        RelaySetupKeyFields(
            key = key,
            label = stringResource(R.string.api_key),
            onSecretChange = { value ->
                if (key.isPrimary) viewModel.updateApiKey(value) else viewModel.updateKeySecret(key.id, value)
            },
            onNameChange = { value ->
                if (key.isPrimary) viewModel.updatePrimaryKeyName(value) else viewModel.updateKeyName(key.id, value)
            },
            onRemove = { viewModel.removeKey(key.id) },
        )
    }
}

/** Footnote row of the key block: "Keys are stored on this device only" (footnote tertiary) + Spacer + "+ Add another key", vertically centered on the whole row. */
@Composable
private fun RelayKeysFootnoteRow(footnote: String, onAdd: () -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = footnote,
            style = OriveoTheme.typography.footnote,
            color = OriveoTheme.colors.textTertiary,
            modifier = Modifier.weight(1f),
        )
        RelayAddKeyRow(onAdd = onAdd)
    }
}

/** "+ Add another key" (minimum height 44). */
@Composable
private fun RelayAddKeyRow(onAdd: () -> Unit) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(OriveoTheme.radius.inset))
            .clickable(onClick = onAdd)
            .padding(horizontal = OriveoTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(R.drawable.ph_plus), contentDescription = null, tint = colors.primary, modifier = Modifier.size(14.dp))
        Text(
            text = stringResource(R.string.relay_setup_add_key),
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.primary,
        )
    }
}

@Composable
internal fun RelayQuickField(
    /** null = no title row (a second input in the same group, such as the key name or the search box). */
    label: String?,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    /** Title row icon; null = the title row draws no icon. */
    icon: Painter?,
    footnote: String? = null,
    secure: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    selectionRange: IntRange? = null,
    /** The scheme prefix chip of the address slot ("https" / "http" on the board). */
    schemeChip: String? = null,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
    /** Label at the start of the slot row (such as "Name (optional)" for the connection name), in the secondary color. */
    slotLabel: String? = null,
    /** Icon at the start of the slot row (such as the magnifier of the step 2 search box), in the tertiary color. */
    leadingIcon: Painter? = null,
    /** Trailing part of the title row ("Remove" for an extra key); null = not drawn. */
    labelTrailing: (@Composable () -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val surfaceFill = relayQuickSurfaceFillColor(colors, OriveoTheme.isDark)
    var focused by remember { mutableStateOf(false) }
    var revealsSecureText by remember { mutableStateOf(false) }
    // Address slot with a scheme chip: the slot shows only what follows the scheme, and when writing back a scheme the user already typed is kept.
    val slotText = if (schemeChip != null) relaySchemeSlotText(value) else value
    val slotRange = if (schemeChip != null) relaySchemeSlotRange(value, selectionRange) else selectionRange
    val slotPlaceholder = if (schemeChip != null) relaySchemeSlotText(placeholder) else placeholder
    var fieldValue by remember { mutableStateOf(TextFieldValue(slotText, selection = TextRange(slotText.length))) }
    LaunchedEffect(slotText, slotRange) {
        if (fieldValue.text != slotText || slotRange != null) {
            fieldValue = TextFieldValue(
                text = slotText,
                selection = slotRange?.let { TextRange(it.first, it.last + 1) }
                    ?: TextRange(slotText.length),
            )
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        label?.let {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                icon?.let { painter -> Icon(painter, contentDescription = null, tint = colors.primary, modifier = Modifier.size(16.dp)) }
                Text(
                    it,
                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textSecondary,
                    modifier = if (labelTrailing != null) Modifier.weight(1f) else Modifier,
                )
                labelTrailing?.invoke()
            }
        }
        BasicTextField(
            value = fieldValue,
            onValueChange = {
                fieldValue = it
                onValueChange(if (schemeChip != null) relaySchemeSlotInput(value, it.text) else it.text)
            },
            enabled = enabled,
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
                // Aligned with iOS RelaySetupField: the right side of a secret field is left to the 44dp eye button, so only an xs margin remains
                .padding(
                    start = if (schemeChip != null) 10.dp else 16.dp,
                    end = if (secure || trailing != null) OriveoTheme.spacing.xs else 16.dp,
                ),
            // With a label inside the slot the input is right-aligned (iOS RelaySetupField: label on the left, value on the right).
            textStyle = OriveoTheme.typography.body.copy(
                color = colors.textPrimary,
                textAlign = if (slotLabel != null) TextAlign.End else TextAlign.Start,
            ),
            cursorBrush = SolidColor(colors.primary),
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            visualTransformation = if (secure && !revealsSecureText) PasswordVisualTransformation() else VisualTransformation.None,
            decorationBox = { inner ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    schemeChip?.let {
                        SetupSchemeChip(it)
                        Spacer(Modifier.size(10.dp))
                    }
                    leadingIcon?.let {
                        Icon(it, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(10.dp))
                    }
                    slotLabel?.let {
                        Text(it, style = OriveoTheme.typography.body, color = colors.textTertiary, maxLines = 1, softWrap = false)
                        Spacer(Modifier.size(10.dp))
                    }
                    Box(
                        modifier = Modifier.weight(1f),
                        contentAlignment = if (slotLabel != null) Alignment.CenterEnd else Alignment.CenterStart,
                    ) {
                        if (fieldValue.text.isEmpty()) {
                            Text(slotPlaceholder, style = OriveoTheme.typography.body, color = colors.textTertiary, maxLines = 1)
                        }
                        inner()
                    }
                    if (secure) {
                        // A pasted key has to be checkable; same icons and screen reader labels as OriveoLabeledField
                        IconButton(
                            onClick = { revealsSecureText = !revealsSecureText },
                            modifier = Modifier.size(44.dp),
                        ) {
                            Icon(
                                painter = painterResource(R.drawable.ph_eye),
                                contentDescription = stringResource(
                                    if (revealsSecureText) R.string.secure_field_hide else R.string.secure_field_show,
                                ),
                                tint = if (revealsSecureText) colors.primary else colors.textTertiary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                    trailing?.invoke()
                }
            },
        )
        footnote?.let {
            Text(it, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        }
    }
}

/** One key: an "API Key" title row (an extra key gets "Remove" at the end of the row) + the key slot (with a show/hide eye) + with two or more keys, a name slot with an in-slot label. */
@Composable
private fun RelaySetupKeyFields(
    key: RelaySetupKeyRow,
    label: String,
    onSecretChange: (String) -> Unit,
    onNameChange: (String) -> Unit,
    onRemove: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val removeLabel = stringResource(R.string.relay_setup_remove_key)
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs)) {
        RelayQuickField(
            label = label,
            value = key.secret,
            onValueChange = onSecretChange,
            placeholder = stringResource(R.string.relay_api_key_placeholder),
            icon = painterResource(R.drawable.ph_key),
            secure = true,
            labelTrailing = if (key.removable) {
                {
                    Row(
                        modifier = Modifier
                            .heightIn(min = 44.dp)
                            .clickable(onClick = onRemove)
                            .semantics(mergeDescendants = true) { contentDescription = removeLabel }
                            .padding(horizontal = OriveoTheme.spacing.xs),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(painterResource(R.drawable.ph_trash), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(14.dp))
                        Text(
                            text = stringResource(R.string.remove),
                            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textSecondary,
                        )
                    }
                }
            } else {
                null
            },
        )
        if (key.showsName) {
            RelayQuickField(
                label = null,
                value = key.name,
                onValueChange = onNameChange,
                placeholder = "",
                icon = null,
                slotLabel = stringResource(R.string.relay_setup_key_name),
            )
        }
    }
}

internal fun relayQuickSurfaceFillColor(colors: OriveoColors, isDark: Boolean): Color =
    colors.primarySoft
        .opacity(if (isDark) 0.68f else 0.62f)
        .compositeOver(colors.surfaceInset)

/** Protocol colors reuse the existing brand color tokens: Chat = OpenAI, Responses = the same color at 60%, Messages = Anthropic, Gemini = Gemini. */
@Composable
internal fun relayProtocolColor(protocol: RelayBoardProtocol): Color = when (protocol) {
    RelayBoardProtocol.Chat -> ProviderBadgeColors.usageBreakdown(ProviderKind.OpenAI)
    RelayBoardProtocol.Responses -> ProviderBadgeColors.usageBreakdown(ProviderKind.OpenAI).copy(alpha = 0.6f)
    RelayBoardProtocol.Messages -> ProviderBadgeColors.usageBreakdown(ProviderKind.Anthropic)
    RelayBoardProtocol.Gemini -> ProviderBadgeColors.usageBreakdown(ProviderKind.Gemini)
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

/** Detection card: a title row "Detection" (the UI is not locked) + n / 3 + a progress bar; each of the three items shows its state and its own elapsed time (refreshed every 0.1 s while running). */
@Composable
private fun RelayDetectionCardView(detection: RelayDetectionBoard) {
    val colors = OriveoTheme.colors
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(detection.isRunning) {
        now = System.currentTimeMillis()
        while (detection.isRunning) {
            delay(100)
            now = System.currentTimeMillis()
        }
    }
    // Card fill and border follow the state: primary color while running, success color when all pass, warning color when any fails (iOS RelaySetupDetectionCard).
    val (tone, fill) = when {
        detection.isRunning -> colors.primary to colors.primarySoft
        detection.rows.any { it.state == RelayCheckState.Failed } -> colors.warning to colors.warningSoft
        else -> colors.success to colors.successSoft
    }
    val shape = RoundedCornerShape(OriveoTheme.radius.md)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(fill)
            .border(1.dp, tone.opacity(0.28f), shape)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(R.string.relay_setup_detection_title),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                modifier = Modifier.alignByBaseline(),
            )
            Text(
                stringResource(R.string.relay_setup_detection_subtitle),
                color = colors.textSecondary,
                modifier = Modifier
                    .weight(1f)
                    .alignByBaseline(),
                maxLines = 1,
                style = OriveoTheme.typography.footnote,
                autoSize = TextAutoSize.StepBased(
                    minFontSize = OriveoTheme.typography.footnote.fontSize * 0.85f,
                    maxFontSize = OriveoTheme.typography.footnote.fontSize,
                    stepSize = 0.25.sp,
                ),
            )
            Text(
                "${detection.completed} / ${detection.total}",
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.primary,
                modifier = Modifier.alignByBaseline(),
            )
        }
        LinearProgressIndicator(
            progress = { detection.completed.toFloat() / detection.total },
            modifier = Modifier.fillMaxWidth(),
            color = colors.primary,
            trackColor = colors.surfaceInset,
        )
        detection.rows.forEach { row ->
            RelayDetectionRowView(row, detection, now)
        }
        RelayInfoNote(stringResource(R.string.relay_setup_detection_note), colors.textTertiary)
    }
}

/** Detection row: icon (top-aligned) + left column [title / key catalog row / details / failure], with the elapsed time in a column of its own (iOS checkRow). */
@Composable
private fun RelayDetectionRowView(row: RelayCheckRow, detection: RelayDetectionBoard, now: Long) {
    val colors = OriveoTheme.colors
    val locale = LocalConfiguration.current.locales[0]
    val detail = when {
        row.state == RelayCheckState.Skipped -> stringResource(R.string.relay_setup_check_skipped)
        row.kind == RelayCheckKind.Connection && row.state == RelayCheckState.Done ->
            row.reachablePath?.let { stringResource(R.string.relay_setup_reachable_path, it) }
        row.kind == RelayCheckKind.Protocols && row.state == RelayCheckState.Running ->
            stringResource(R.string.relay_setup_protocols_running)
        row.kind == RelayCheckKind.Protocols && row.state == RelayCheckState.Done ->
            stringResource(R.string.relay_setup_protocols_done)
        else -> null
    }
    // The elapsed-time column is vertically centered on the whole row and is not pinned to the title line when the left column has several lines. (whole-row vertical centering)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(modifier = Modifier.size(24.dp), contentAlignment = Alignment.Center) { RelayCheckStateIcon(row.state) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(
                        when (row.kind) {
                            RelayCheckKind.Connection -> R.string.relay_setup_check_connection
                            RelayCheckKind.Catalog -> R.string.relay_setup_check_catalog
                            RelayCheckKind.Protocols -> R.string.relay_setup_check_protocols
                        },
                    ),
                    style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                if (row.kind == RelayCheckKind.Catalog && row.state != RelayCheckState.Skipped && row.state != RelayCheckState.Pending) {
                    detection.keyLines.forEach { line -> RelayKeyCatalogLineView(line) }
                }
                detail?.let { Text(it, style = OriveoTheme.typography.footnote, color = colors.textSecondary) }
                if (row.state == RelayCheckState.Failed) {
                    if (row.kind == RelayCheckKind.Connection) RelayAttemptDiagnostics(detection.attempts)
                    RelayFailureSentence(row.failure, row.failureText)
                }
            }
        }
        row.elapsedMs(now)?.let { elapsed ->
            Text(
                stringResource(R.string.mcp_detail_seconds, relaySetupSeconds(elapsed, locale)),
                style = OriveoTheme.typography.footnote.copy(fontFeatureSettings = "tnum"),
                color = colors.textTertiary,
            )
        }
    }
}

@Composable
private fun RelayCheckStateIcon(state: RelayCheckState) {
    val colors = OriveoTheme.colors
    when (state) {
        RelayCheckState.Running -> CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        RelayCheckState.Done -> Icon(painterResource(R.drawable.ph_check_circle), null, tint = colors.success, modifier = Modifier.size(22.dp))
        RelayCheckState.Failed -> Icon(painterResource(R.drawable.ph_warning_circle), null, tint = colors.warning, modifier = Modifier.size(22.dp))
        RelayCheckState.Skipped -> Icon(painterResource(R.drawable.ph_minus_circle), null, tint = colors.textTertiary, modifier = Modifier.size(22.dp))
        RelayCheckState.Pending -> Icon(painterResource(R.drawable.ph_circle), null, tint = colors.textTertiary, modifier = Modifier.size(22.dp))
    }
}

/** Key catalog row: inside the title column, under the title; a chip with key 13 + footnote (8 / 3); skipped ones are not shown. */
@Composable
private fun RelayKeyCatalogLineView(line: RelayKeyCatalogLine) {
    val colors = OriveoTheme.colors
    if (line.state == RelayCheckState.Skipped) return
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        line.label?.let { label ->
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(colors.surfaceInset)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(painterResource(R.drawable.ph_key), null, tint = colors.primary, modifier = Modifier.size(13.dp))
                Text(label, style = OriveoTheme.typography.footnote, color = colors.textSecondary, maxLines = 1)
            }
        }
        when (line.state) {
            RelayCheckState.Done -> line.modelCount?.let { count ->
                Text(
                    pluralStringResource(R.plurals.relay_setup_catalog_count, count, count),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
            RelayCheckState.Failed -> RelayFailureSentence(line.failure, line.failureText)
            RelayCheckState.Skipped, RelayCheckState.Running, RelayCheckState.Pending -> Unit
        }
    }
}

@Composable
private fun RelayFailureSentence(kind: RelaySetupFailureKind?, fallback: String?) {
    val text = kind?.messageRes?.let { stringResource(it) } ?: fallback ?: return
    Text(text, style = OriveoTheme.typography.footnote, color = OriveoTheme.colors.warning)
}

/** Failure item: the upstream raw text -> a collapsible "What Oriveo tried" (collapsed by default; one line per attempt, shrunk to 0.7 if it does not fit, + the number of automatic retries); the failure sentence follows. */
@Composable
private fun RelayAttemptDiagnostics(attempts: List<RelayDiscoveryAttempt>) {
    val colors = OriveoTheme.colors
    val footnote = OriveoTheme.typography.footnote
    var expanded by remember(attempts) { mutableStateOf(false) }
    relayPreferredUpstreamMessage(attempts)
        ?.let { Text(it, style = footnote, color = colors.textPrimary) }
    val lines = relayAttemptDiagnosticLines(attempts)
    val retryCount = relayRetryCount(attempts)
    if (lines.isEmpty() && retryCount == 0) return
    val expandedLabel = stringResource(if (expanded) R.string.mcp_steps_expanded else R.string.mcp_steps_collapsed)
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    Row(
        modifier = Modifier
            .clickable { expanded = !expanded }
            .semantics { stateDescription = expandedLabel }
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.relay_setup_attempts_title),
            style = footnote.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        // Collapsed points in the reading direction, expanded points down; the caret_right resource is not mirrored automatically, so flip it manually in RTL.
        Icon(
            painterResource(if (expanded) R.drawable.ph_caret_down else R.drawable.ph_caret_right),
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier
                .size(12.dp)
                .then(if (rtl && !expanded) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
        )
    }
    if (!expanded) return
    lines.forEach { diagnostic ->
        Text(
            diagnostic,
            style = footnote,
            color = colors.textSecondary,
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(minFontSize = footnote.fontSize * 0.7f, maxFontSize = footnote.fontSize, stepSize = 0.25.sp),
        )
    }
    if (retryCount > 0) {
        Text(
            text = stringResource(R.string.relay_quick_automatic_retries, retryCount),
            style = footnote,
            color = colors.textSecondary,
        )
    }
}

/** Step 2: back + title + subtitle (host · n keys · Step 2 of 2) -> search -> group selection -> manual add. */
@Composable
private fun RelaySetupModelsContent(viewModel: RelaySetupViewModel) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val board = viewModel.modelsBoard
    Column(verticalArrangement = Arrangement.spacedBy(spacing.lg)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(spacing.md)) {
            OriveoBackButton(onClick = viewModel::backToAddress)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    stringResource(R.string.relay_setup_models_title),
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                    modifier = Modifier.semantics { heading() },
                )
                val parts = listOfNotNull(
                    board.host,
                    pluralStringResource(R.plurals.relay_setup_key_count, board.keyCount, board.keyCount).takeIf { board.keyCount >= 2 },
                    stringResource(R.string.relay_setup_step_of, 2, 2),
                )
                Text(parts.joinToString(" · "), style = OriveoTheme.typography.footnote, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Box {
            RelayQuickField(
                label = null,
                value = viewModel.modelSearch,
                onValueChange = viewModel::updateSearch,
                placeholder = pluralStringResource(R.plurals.relay_setup_search_models, board.totalModels, board.totalModels),
                icon = null,
                leadingIcon = painterResource(R.drawable.ph_magnifying_glass),
            )
        }
        if (board.isCatalogEmpty) {
            Text(stringResource(R.string.relay_setup_models_empty), style = OriveoTheme.typography.body, color = colors.textSecondary)
        }
        board.groups.forEach { group ->
            RelaySetupModelGroupView(
                group = group,
                onToggleGroup = { viewModel.toggleGroup(group.id) },
                onSelectGroup = { viewModel.selectGroup(group.id) },
                onToggleModel = viewModel::toggleModel,
            )
        }
        RelayManualModelEntry(
            onBegin = viewModel::beginManualModelEntry,
            onAdd = { viewModel.addManualModel(it) },
            showsNotice = board.manualAddNotice,
        )
        // Persistence failure: one box = a warning icon + the reason (footnote warning), with a warningSoft fill and a 0.3 warning border (iOS has no title row).
        board.saveFailure?.let { failure ->
            val shape = RoundedCornerShape(OriveoTheme.radius.inset)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(colors.warningSoft)
                    .border(1.dp, colors.warning.opacity(0.3f), shape)
                    .padding(spacing.md),
                horizontalArrangement = Arrangement.spacedBy(spacing.sm),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(painterResource(R.drawable.ph_warning_duotone), contentDescription = null, tint = colors.warning, modifier = Modifier.size(16.dp))
                Text(failure, style = OriveoTheme.typography.footnote, color = colors.warning)
            }
        }
    }
}

@Composable
private fun RelaySetupModelGroupView(
    group: RelaySetupModelGroup,
    onToggleGroup: () -> Unit,
    onSelectGroup: () -> Unit,
    onToggleModel: (String) -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggleGroup),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Collapsed points in the reading direction, expanded points down; the caret_right resource is not mirrored automatically, so flip it manually in RTL.
            Icon(
                painterResource(if (group.expanded) R.drawable.ph_caret_down else R.drawable.ph_caret_right),
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier
                    .size(14.dp)
                    .then(if (LocalLayoutDirection.current == LayoutDirection.Rtl && !group.expanded) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
            )
            // Name + count + selected form one cluster that takes all the remaining width; "Select all in group" is pinned to the end of the row and does not drift with the name length.
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    group.titleRes?.let { stringResource(it) } ?: group.title,
                    style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Text("· ${group.modelCount}", style = OriveoTheme.typography.footnote, color = colors.textTertiary, maxLines = 1)
                if (group.selectedCount > 0) {
                    Text(stringResource(R.string.relay_setup_group_selected, group.selectedCount), style = OriveoTheme.typography.caption, color = colors.primary, maxLines = 1)
                }
            }
            // When not selectable, the whole control is at 0.45 alpha with the color unchanged (iOS disabled).
            Text(
                stringResource(R.string.relay_setup_select_group),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.Medium),
                color = colors.primary,
                maxLines = 1,
                modifier = Modifier
                    .alpha(if (group.canSelectAll) 1f else 0.45f)
                    .clip(RoundedCornerShape(50))
                    .background(colors.primarySoft)
                    .clickable(enabled = group.canSelectAll, onClick = onSelectGroup)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
        if (group.rows.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OriveoTheme.radius.md))
                    .background(colors.surfaceInset)
                    .padding(vertical = 4.dp),
            ) {
                group.rows.forEachIndexed { index, row ->
                    if (index > 0) {
                        // The divider is inset to just past the checkbox (iOS 48).
                        Box(
                            modifier = Modifier
                                .padding(start = 48.dp)
                                .fillMaxWidth()
                                .height(0.5.dp)
                                .background(colors.border.opacity(0.72f)),
                        )
                    }
                    // The checkbox uses the Phosphor drawing, while the whole row is still a checkable control (Role.Checkbox), so screen reader and tap semantics are unchanged.
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .toggleable(value = row.selected, role = Role.Checkbox, onValueChange = { onToggleModel(row.id) })
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(
                            painter = painterResource(if (row.selected) R.drawable.ph_check_square_duotone else R.drawable.ph_square),
                            contentDescription = null,
                            tint = if (row.selected) colors.primary else colors.textTertiary,
                            modifier = Modifier.size(24.dp),
                        )
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.weight(1f)) {
                            // The model id and the protocol chip are technical strings, so the whole row is forced to LTR.
                            CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(
                                        row.id,
                                        style = OriveoTheme.typography.body,
                                        color = colors.textPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.MiddleEllipsis,
                                        modifier = Modifier.weight(1f, fill = false),
                                    )
                                    RelayProtocolChip(row.protocol)
                                }
                            }
                            row.keyChip?.let { RelayKeyChip(it) }
                        }
                    }
                }
            }
        }
    }
}

/** Protocol chip: a capsule with a dot of 7 + caption. */
@Composable
private fun RelayProtocolChip(protocol: RelayBoardProtocol) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(colors.surfaceElevated)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier = Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(relayProtocolColor(protocol)),
        )
        Text(protocol.legend, style = OriveoTheme.typography.caption, color = colors.textSecondary, maxLines = 1)
    }
}

/** Key chip: key 12 + a label caption, in a capsule. */
@Composable
private fun RelayKeyChip(label: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(colors.surfaceElevated)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(painterResource(R.drawable.ph_key), contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(12.dp))
        Text(label, style = OriveoTheme.typography.caption, color = colors.textSecondary, maxLines = 1)
    }
}

@Composable
private fun RelayManualModelEntry(onBegin: () -> Unit, onAdd: (String) -> Unit, showsNotice: Boolean) {
    val colors = OriveoTheme.colors
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    val fieldFocus = remember { FocusRequester() }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            modifier = Modifier
                .clickable {
                    onBegin()
                    draft = ""
                    editing = true
                }
                .heightIn(min = 44.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(painterResource(R.drawable.ph_plus), null, tint = colors.primary, modifier = Modifier.size(16.dp))
            Text(stringResource(R.string.relay_setup_add_model_manually), style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold), color = colors.primary)
        }
        if (showsNotice) {
            Text(
                stringResource(R.string.relay_setup_models_already_listed),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
    if (editing) {
        // A system dialog isomorphic to the iOS `.alert`.
        AlertDialog(
            onDismissRequest = { editing = false },
            title = { Text(stringResource(R.string.relay_setup_add_model_manually)) },
            text = {
                // Focus the input field as soon as the dialog opens.
                LaunchedEffect(Unit) { fieldFocus.requestFocus() }
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.focusRequester(fieldFocus),
                    placeholder = { Text(RelayFlagshipModel.current()) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onAdd(draft)
                        draft = ""
                        editing = false
                    },
                    enabled = relayManualModelAddable(draft),
                ) {
                    Text(stringResource(R.string.add))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { editing = false },
                ) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

/** Step 1 bottom bar: "Step 1 of 2" above the button + "Cancel detection" while running; the primary button is always "Next"; a "manual" row under a hairline. */
@Composable
private fun RelayStepOneActionBar(
    board: RelaySetupBoard,
    onNext: () -> Unit,
    onCancelDetection: () -> Unit,
    onSecondary: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    SetupActionBar(
        primaryText = stringResource(board.primaryLabel),
        primaryEnabled = board.isPrimaryEnabled,
        primaryLoading = false,
        secondaryText = stringResource(board.secondaryRow),
        secondaryCompact = true,
        onPrimary = onNext,
        onSecondary = onSecondary,
        modifier = modifier,
        header = {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.relay_setup_step_of, 1, 2),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                if (board.showsCancelDetection) {
                    Text(
                        stringResource(R.string.relay_setup_cancel_detection),
                        style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textSecondary,
                        modifier = Modifier
                            .clickable(onClick = onCancelDetection)
                            .padding(vertical = 4.dp),
                    )
                }
            }
        },
    )
}

/** Step 2 bottom bar: a footnote (after saving, one very small request is sent for the first selected model) + "Save (n selected)", not tappable with 0 selected. */
@Composable
private fun RelayModelsActionBar(
    board: RelaySetupModelsBoard,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    SetupActionBar(
        primaryText = stringResource(R.string.relay_setup_save_selected, board.selectedCount),
        primaryEnabled = board.isSaveEnabled,
        primaryLoading = board.isSaving,
        secondaryText = null,
        onPrimary = onSave,
        onSecondary = {},
        modifier = modifier,
        header = { RelayInfoNote(stringResource(R.string.relay_setup_save_note), colors.textSecondary) },
    )
}

/** Three states of the local primary button: Detect connection settings / detecting (loading) / Connect and save. */
@Composable
private fun LocalComputeActionBar(
    action: LocalPrimaryAction,
    isWorking: Boolean,
    enabled: Boolean,
    @StringRes secondaryRow: Int,
    onClick: () -> Unit,
    onSecondary: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SetupActionBar(
        primaryText = when (action) {
            LocalPrimaryAction.Detect -> stringResource(R.string.relay_quick_detect_action)
            LocalPrimaryAction.ConnectAndSave -> stringResource(R.string.relay_quick_connect_save)
        },
        primaryEnabled = enabled,
        primaryLoading = isWorking,
        secondaryText = stringResource(secondaryRow),
        onPrimary = onClick,
        onSecondary = onSecondary,
        modifier = modifier,
    )
}

@Composable
internal fun RelayTransport.localizedLabel(): String = stringResource(
    when (this) {
        RelayTransport.OpenAIChatCompletions, RelayTransport.Auto -> R.string.relay_transport_openai_chat_completions
        RelayTransport.LlamaCppNative -> R.string.relay_transport_llamacpp_native
        RelayTransport.OpenAIResponses -> R.string.relay_transport_openai_responses
        RelayTransport.AnthropicMessages -> R.string.relay_transport_anthropic_messages
        RelayTransport.GeminiGenerateContent -> R.string.relay_transport_gemini_generate_content
    },
)

/**
 * Manual setup (the ManualSetup board): the same page shell as step 1; address -> key -> model -> connection name -> "Protocol" card ->
 * the collapsible group "Authentication, headers and query parameters" -> (after a failure) the failure card. Rendered strictly from [RelaySetupViewModel.manualBoard].
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RelayManualSetupContent(viewModel: RelaySetupViewModel) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val board = viewModel.manualBoard

    // Only when a new failure card appears do we dismiss the keyboard and scroll to it; the same card does not scroll again, and a dismissed one does not scroll (same reveal function as edit connection).
    val failureRequester = remember { BringIntoViewRequester() }
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val lastStatus = remember { arrayOfNulls<RelayEditStatus>(1) }
    LaunchedEffect(board.status) {
        val reveal = RelayEditBoardModel.revealsStatus(lastStatus[0], board.status)
        lastStatus[0] = board.status
        if (reveal) {
            focusManager.clearFocus()
            keyboard?.hide()
            failureRequester.bringIntoView()
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        SetupBoardHero(
            icon = painterResource(R.drawable.ph_hard_drives),
            label = stringResource(board.heroLabelRes),
            title = stringResource(board.heroTitleRes),
            subtitle = stringResource(board.heroSubtitleRes),
            tint = colors.primary,
            tag = stringResource(board.heroTagRes),
        )

        board.blocks.forEach { block ->
            when (block) {
                RelayManualBlock.RequestUrl -> Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    RelayQuickField(
                        label = stringResource(board.requestUrlTitleRes),
                        value = viewModel.endpoint,
                        onValueChange = viewModel::updateEndpoint,
                        placeholder = RELAY_ENDPOINT_PLACEHOLDER,
                        icon = painterResource(board.requestUrlIcon),
                        keyboardType = KeyboardType.Uri,
                        selectionRange = viewModel.endpointHighlightRange,
                        schemeChip = setupSchemeChip(viewModel.endpoint, cleartext = false),
                    )
                    board.willRequest?.let { RelayWillRequestLine(it) }
                }
                RelayManualBlock.ApiKeys -> Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    RelaySetupKeyList(viewModel, board.keys)
                    // Same row as step 1: the "Keys are stored on this device only" footnote + "Add another key".
                    RelayKeysFootnoteRow(stringResource(R.string.relay_setup_keys_local), onAdd = viewModel::addKey)
                    RelayFormIssueNotes(issues = board.keyIssues)
                }
                RelayManualBlock.Model -> RelayQuickField(
                    label = stringResource(board.modelTitleRes),
                    value = viewModel.defaultModel,
                    onValueChange = viewModel::updateDefaultModel,
                    placeholder = board.modelPlaceholder,
                    icon = painterResource(board.modelIcon),
                    footnote = stringResource(board.modelFootnoteRes),
                )
                RelayManualBlock.ConnectionName -> Column(verticalArrangement = Arrangement.spacedBy(spacing.xs)) {
                    RelayQuickField(
                        label = stringResource(board.connectionNameTitleRes),
                        value = viewModel.name,
                        onValueChange = viewModel::updateConnectionName,
                        // The right side shows only the domain derived from the address; if it cannot be derived it stays empty and does not repeat the in-slot label.
                        placeholder = board.connectionNamePlaceholder.orEmpty(),
                        icon = painterResource(board.connectionNameIcon),
                        slotLabel = stringResource(board.connectionNameSlotLabelRes),
                        footnote = stringResource(board.connectionNameFootnoteRes),
                    )
                }
                RelayManualBlock.ProtocolCard -> EditGroup(
                    group = board.protocolGroup,
                    onToggle = {},
                ) { row ->
                    MenuRow(
                        row = row,
                        options = RelayManualSetupBoardModel.protocolOptions,
                        label = { relayAdvancedTransportLabel(it) },
                        onSelect = viewModel::selectManualTransport,
                    )
                }
                RelayManualBlock.Advanced -> {
                    val summary = board.advancedSummary
                    val count = if (summary.filledCount == 0) {
                        stringResource(R.string.relay_manual_not_set)
                    } else {
                        pluralStringResource(R.plurals.relay_edit_headers_set_count, summary.filledCount, summary.filledCount)
                    }
                    EditGroup(
                        group = board.advancedGroup,
                        onToggle = viewModel::toggleManualAdvanced,
                        trailing = "${stringResource(summary.authRes)} · $count",
                    ) { row -> RelayManualAdvancedRow(viewModel, row) }
                }
                RelayManualBlock.Failure -> Box(modifier = Modifier.bringIntoViewRequester(failureRequester)) {
                    StatusBlock(
                        status = board.status,
                        onSaveUnverified = viewModel::saveManualUnverified,
                        failureNote = stringResource(board.failureNoteRes),
                    )
                }
            }
        }
    }
}

/** Rows of the collapsible group: auth menu / UA / headers (masked) / query parameters (not masked) / add, the same row set as edit connection. */
@Composable
private fun RelayManualAdvancedRow(viewModel: RelaySetupViewModel, row: RelayEditRow) {
    fun List<RelayKeyValue>.replaced(index: Int, value: RelayKeyValue) = toMutableList().also { it[index] = value }
    when (row.id) {
        RelayEditRowId.Authentication -> MenuRow(
            row = row,
            options = RelayAuthMode.entries,
            label = { relayAdvancedAuthModeLabel(it) },
            onSelect = viewModel::selectManualAuthMode,
        )
        RelayEditRowId.UserAgent -> KeyValueRow(
            label = stringResource(row.titleRes),
            name = null,
            value = viewModel.manualUserAgent,
            valuePlaceholder = stringResource(R.string.relay_advanced_user_agent_placeholder),
            masked = false,
            onName = {},
            onValue = viewModel::updateManualUserAgent,
            onRemove = null,
        )
        RelayEditRowId.Header -> {
            val headers = viewModel.manualHeaders
            val pair = headers[row.index]
            KeyValueRow(
                label = stringResource(row.titleRes),
                name = pair.key,
                namePlaceholder = RelayFormValidation.definition(RelayFormValidation.Field.Headers)?.placeholder.orEmpty(),
                value = pair.value,
                valuePlaceholder = stringResource(R.string.relay_value_label),
                masked = row.masked,
                onName = { viewModel.updateManualHeaders(headers.replaced(row.index, pair.copy(key = it))) },
                onValue = { viewModel.updateManualHeaders(headers.replaced(row.index, pair.copy(value = it))) },
                onRemove = { viewModel.updateManualHeaders(headers.filterIndexed { i, _ -> i != row.index }) },
            )
            RowIssues(row.issues)
        }
        RelayEditRowId.QueryParam -> {
            val params = viewModel.manualQueryParams
            val pair = params[row.index]
            KeyValueRow(
                label = stringResource(row.titleRes),
                name = pair.key,
                namePlaceholder = RelayFormValidation.definition(RelayFormValidation.Field.QueryParams)?.placeholder.orEmpty(),
                value = pair.value,
                valuePlaceholder = stringResource(R.string.relay_value_label),
                masked = false,
                onName = { viewModel.updateManualQueryParams(params.replaced(row.index, pair.copy(key = it))) },
                onValue = { viewModel.updateManualQueryParams(params.replaced(row.index, pair.copy(value = it))) },
                onRemove = { viewModel.updateManualQueryParams(params.filterIndexed { i, _ -> i != row.index }) },
            )
            RowIssues(row.issues)
        }
        RelayEditRowId.AddEntry -> AddEntryRow(
            onAddHeader = { viewModel.updateManualHeaders(viewModel.manualHeaders + RelayKeyValue("", "")) },
            onAddQueryParam = { viewModel.updateManualQueryParams(viewModel.manualQueryParams + RelayKeyValue("", "")) },
        )
        else -> Unit
    }
}

/** Manual setup bottom bar: a single primary button (verify and save / spinner while running / re-verify) and no "Test connection". */
@Composable
private fun RelayManualActionBar(
    board: RelayManualSetupBoard,
    onValidate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SetupActionBar(
        primaryText = stringResource(board.primary.titleRes),
        primaryEnabled = board.primary.enabled,
        primaryLoading = board.primary.loading,
        secondaryText = null,
        onPrimary = onValidate,
        onSecondary = {},
        modifier = modifier,
    )
}

/** "Will request ..." under the address slot: a leading arrow-elbow-down-right (13, flipped in RTL, tertiary color, hidden from screen readers) aligned to the first line, at most 2 lines. */
@Composable
private fun RelayWillRequestLine(url: String) {
    val colors = OriveoTheme.colors
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val style = OriveoTheme.typography.footnote
    val firstLine = with(LocalDensity.current) { style.lineHeight.toDp() }
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
        // The icon is centered within the first line height, equivalent to the iOS first-baseline alignment.
        Box(modifier = Modifier.height(firstLine), contentAlignment = Alignment.Center) {
            Icon(
                painter = painterResource(R.drawable.ph_arrow_elbow_down_right),
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier
                    .size(13.dp)
                    .then(if (rtl) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
            )
        }
        // Middle ellipsis on Android supports a single line only; with two lines fall back to tail ellipsis.
        Text(
            text = stringResource(R.string.relay_setup_will_request, url),
            style = style,
            color = colors.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Footnote row: a leading info icon (16). Shared by the detection card explanation row and the step 2 save bar footnote. */
@Composable
private fun RelayInfoNote(text: String, color: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
        Icon(painterResource(R.drawable.ph_info), contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        Text(text, style = OriveoTheme.typography.footnote, color = color)
    }
}
