package ai.oriveo.community.feature.providers.manual

import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDirection
import ai.oriveo.community.feature.providers.relay.RelayFlagshipModel
import ai.oriveo.community.feature.providers.relay.relayQuickSurfaceFillColor
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoErrorCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

/**
 * The "Add model manually" page (ManualModel board): relays and official providers share one page and one layout,
 * with a back button plus a centered title in the header. The content is a single input slot (drawn like the Setup
 * input slot: light fill, no border, monospace font, a clear button at the end of the row when there is text) and a
 * caption under the slot. The official provider copy, "Retry sync" and the save logic are unchanged.
 */
@OptIn(ExperimentalMaterial3Api::class)
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
    val relayPlaceholder = remember { RelayFlagshipModel.current() }
    val board = ManualModelBoardModel.make(
        isRelay = isRelayMode,
        modelID = viewModel.modelID,
        isSaving = viewModel.isSaving,
        relayPlaceholder = relayPlaceholder,
    )
    val layout = OriveoTheme.layout
    val colors = OriveoTheme.colors

    Scaffold(
        containerColor = Color.Transparent,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = stringResource(board.titleRes),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                },
                navigationIcon = {
                    OriveoBackButton(onClick = onBack)
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent,
                ),
            )
        },
        bottomBar = {
            BottomBar(
                board = board,
                canSave = board.primaryEnabled && viewModel.canSave,
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
                .verticalScroll(rememberScrollState())
                .padding(horizontal = layout.screenH)
                .padding(top = layout.sectionGap, bottom = layout.sectionGap),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            board.blocks.forEach { block ->
                when (block) {
                    ManualModelBlock.ModelSlot -> ModelSlot(
                        board = board,
                        modelID = viewModel.modelID,
                        onChange = { viewModel.modelID = it },
                    )
                    ManualModelBlock.Notes -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        board.notes.forEach { note ->
                            Text(
                                text = stringResource(note),
                                style = OriveoTheme.typography.footnote,
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
            }

            viewModel.error?.let { err ->
                OriveoErrorCard(error = err)
            }
        }
    }
}

/** Input slot: slot title + light-filled slot (monospace, the model ID is always left to right) + a clear button at the end of the row when there is text. */
@Composable
private fun ModelSlot(board: ManualModelBoard, modelID: String, onChange: (String) -> Unit) {
    val colors = OriveoTheme.colors
    val slotTitle = stringResource(board.slotTitleRes)
    val placeholder = board.placeholder ?: board.placeholderRes?.let { stringResource(it) }.orEmpty()
    val idDirection = if (board.slotIsLtr) TextDirection.Ltr else TextDirection.Content
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = slotTitle,
            style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        BasicTextField(
            value = modelID,
            onValueChange = onChange,
            singleLine = true,
            textStyle = OriveoTheme.typography.body.copy(
                color = colors.textPrimary,
                fontFamily = FontFamily.Monospace,
                textDirection = idDirection,
            ),
            cursorBrush = SolidColor(colors.primary),
            keyboardOptions = KeyboardOptions.Default,
            modifier = Modifier
                .fillMaxWidth()
                .height(54.dp)
                .clip(RoundedCornerShape(OriveoTheme.radius.inset))
                .background(relayQuickSurfaceFillColor(colors, OriveoTheme.isDark))
                .semantics { contentDescription = slotTitle }
                .padding(start = 16.dp, end = 4.dp),
            decorationBox = { inner ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                        if (modelID.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = OriveoTheme.typography.body.copy(
                                    fontFamily = FontFamily.Monospace,
                                    // The relay placeholder is a model ID (left to right); the official localized hint follows the UI direction.
                                    textDirection = if (board.placeholder != null) TextDirection.Ltr else TextDirection.Content,
                                ),
                                color = colors.textTertiary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        inner()
                    }
                    if (board.showsClear) {
                        IconButton(
                            onClick = { onChange("") },
                            modifier = Modifier.size(44.dp),
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
            },
        )
    }
}

// MARK: - Bottom Bar

@Composable
private fun BottomBar(
    board: ManualModelBoard,
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
            text = stringResource(board.primaryRes),
            onClick = onSave,
            enabled = canSave,
            loading = isSaving,
        )
        board.secondaryRes?.let { secondary ->
            OriveoSecondaryButton(
                text = stringResource(secondary),
                onClick = onRetry,
                enabled = !isRetrying && !isSaving,
                loading = isRetrying,
            )
        }
    }
}
