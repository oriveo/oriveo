package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import java.text.NumberFormat
import kotlinx.coroutines.delay

/**
 * The "Test capabilities" bottom panel (two states of the CapabilityTest board): while in progress it cannot be swiped away / dismissed by tapping outside and has only "Cancel";
 * after completion or interruption it has "Done". All display comes from [RelayCapabilityTestPanelModel.present], and the elapsed time refreshes every 0.1 s while in progress.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RelayCapabilityTestPanel(
    state: ProviderDetailViewModel.RelayCapabilityTestPanelState,
    clockMillis: () -> Long,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
) {
    val running = state.phase == RelayCapTestPhase.Running
    val runningNow by rememberUpdatedState(running)
    var now by remember { mutableLongStateOf(clockMillis()) }
    LaunchedEffect(running) {
        while (running) {
            now = clockMillis()
            delay(100L)
        }
    }
    val presentation = RelayCapabilityTestPanelModel.present(state.panelInput(now))
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { value -> value != SheetValue.Hidden || !runningNow },
    )
    OriveoModalBottomSheet(
        onDismissRequest = { if (!runningNow) onDismiss() },
        sheetState = sheetState,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        RelayCapabilityTestPanelContent(
            modelName = state.model.name.ifBlank { state.model.id },
            presentation = presentation,
            onCancel = onCancel,
            onDone = onDismiss,
        )
    }
}

@Composable
private fun RelayCapabilityTestPanelContent(
    modelName: String,
    presentation: RelayCapTestPresentation,
    onCancel: () -> Unit,
    onDone: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    Column(
        modifier = Modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = spacing.lg)
            .padding(top = 24.dp, bottom = spacing.xl),
        verticalArrangement = Arrangement.spacedBy(spacing.md),
    ) {
        // Test-capabilities header: the badge is vertically centered against the whole "title + chip" row (iOS HStack(.center)). (whole-row vertical centering)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(spacing.xs)) {
                Text(
                    text = stringResource(R.string.relay_cap_test_title, modelName),
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(spacing.xs)) {
                    // The transport name is a literal and is not translated (same as the model-library transport chip).
                    Chip(RelayBoardProtocol.of(presentation.transport).legend, icon = null)
                    presentation.keyName?.let { Chip(it, icon = R.drawable.ph_key) }
                }
            }
            HeaderBadge(presentation.header)
        }
        val (finished, total) = presentation.progressFraction
        LinearProgressIndicator(
            progress = { if (total == 0) 0f else finished.toFloat() / total },
            modifier = Modifier.fillMaxWidth(),
            color = if (presentation.header == RelayCapTestHeader.Done) colors.success else colors.primary,
            trackColor = colors.surfaceInset,
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(colors.surfaceElevated),
        ) {
            presentation.rows.forEachIndexed { index, row ->
                if (index > 0) HorizontalDivider(color = colors.border.opacity(0.6f), modifier = Modifier.padding(horizontal = spacing.md))
                RowView(row)
            }
        }
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(
                painter = painterResource(R.drawable.ph_info),
                contentDescription = null,
                modifier = Modifier.padding(top = 3.dp).size(14.dp),
                tint = colors.textSecondary,
            )
            Text(
                text = footerText(presentation.footer),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
            )
        }
        when (presentation.button) {
            RelayCapTestButton.Cancel -> OriveoSecondaryButton(
                text = stringResource(R.string.cancel),
                onClick = onCancel,
                modifier = Modifier.fillMaxWidth(),
            )
            RelayCapTestButton.Done -> OriveoPrimaryButton(
                text = stringResource(R.string.done),
                onClick = onDone,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun Chip(text: String, icon: Int?) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.surfaceInset.opacity(0.6f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        icon?.let { Icon(painter = painterResource(it), contentDescription = null, modifier = Modifier.size(12.dp), tint = colors.textSecondary) }
        Text(text = text, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
    }
}

@Composable
private fun HeaderBadge(header: RelayCapTestHeader) {
    val colors = OriveoTheme.colors
    when (header) {
        is RelayCapTestHeader.Progress -> Text(
            text = stringResource(R.string.relay_cap_test_progress, header.current, header.total),
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.primary,
        )
        RelayCapTestHeader.Done -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(painter = painterResource(R.drawable.ph_check), contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.success)
            Text(text = stringResource(R.string.relay_cap_test_done_badge), style = OriveoTheme.typography.body, color = colors.success)
        }
        RelayCapTestHeader.Stopped -> Text(
            text = stringResource(R.string.relay_cap_test_stopped_badge),
            style = OriveoTheme.typography.body,
            color = colors.warningText,
        )
    }
}

@Composable
private fun RowView(row: RelayCapTestRow) {
    val colors = OriveoTheme.colors
    val dim = row.icon == RelayCapTestIcon.Waiting || row.icon == RelayCapTestIcon.NotRun
    Column {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        RowIcon(row.icon)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = stringResource(RelayCapabilityTestPanelModel.titleRes(row.kind)),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.Medium),
                color = if (dim) colors.textTertiary else colors.textPrimary,
            )
            row.subtitle?.let { res ->
                Text(
                    text = subtitleText(res, row.subtitleArg),
                    style = OriveoTheme.typography.caption,
                    color = if (row.icon == RelayCapTestIcon.Rejected) colors.danger else colors.textSecondary,
                )
            }
        }
        row.trailing?.let { trailing ->
            Text(
                text = trailingText(trailing),
                // Monospaced digits so the timer does not jitter while ticking (iOS monospacedDigit).
                style = OriveoTheme.typography.caption.copy(fontFeatureSettings = "tnum"),
                color = when (trailing) {
                    is RelayCapTestTrailing.Running -> colors.primary
                    RelayCapTestTrailing.Waiting -> colors.textTertiary
                    else -> colors.textSecondary
                },
            )
        }
    }
    }
}

@Composable
private fun RowIcon(icon: RelayCapTestIcon) {
    val colors = OriveoTheme.colors
    val modifier = Modifier.size(26.dp)
    when (icon) {
        RelayCapTestIcon.Running -> CircularProgressIndicator(modifier = modifier.padding(2.dp), strokeWidth = 2.dp, color = colors.primary)
        RelayCapTestIcon.Accepted -> Icon(painter = painterResource(R.drawable.ph_check_circle), contentDescription = null, modifier = modifier, tint = colors.success)
        RelayCapTestIcon.Rejected -> Box(
            modifier = modifier.border(1.5.dp, colors.danger, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painter = painterResource(R.drawable.ph_x), contentDescription = null, modifier = Modifier.size(12.dp), tint = colors.danger)
        }
        RelayCapTestIcon.Undetermined -> Icon(painter = painterResource(R.drawable.ph_warning_circle), contentDescription = null, modifier = modifier, tint = colors.warning)
        RelayCapTestIcon.Waiting,
        RelayCapTestIcon.NotRun,
        -> Box(modifier = modifier.padding(1.dp).border(1.5.dp, colors.textTertiary, CircleShape))
    }
}

@Composable
private fun subtitleText(res: Int, arg: RelayCapTestArg?): String = when (arg) {
    null -> stringResource(res)
    is RelayCapTestArg.Code -> stringResource(res, arg.code)
    is RelayCapTestArg.Text -> stringResource(res, argText(arg))
}

@Composable
private fun argText(arg: RelayCapTestArg.Text): String =
    if (arg.code != null) stringResource(arg.res, arg.code) else stringResource(arg.res)

/** Localized seconds with one decimal place. */
private fun seconds(tenths: Long): String = NumberFormat.getNumberInstance().apply {
    minimumFractionDigits = 1
    maximumFractionDigits = 1
}.format(tenths / 10.0)

@Composable
private fun trailingText(trailing: RelayCapTestTrailing): String = when (trailing) {
    RelayCapTestTrailing.Waiting -> stringResource(R.string.relay_cap_test_waiting)
    is RelayCapTestTrailing.Elapsed -> stringResource(R.string.relay_cap_test_elapsed, seconds(trailing.tenths))
    is RelayCapTestTrailing.Running -> stringResource(R.string.relay_cap_test_elapsed_running, seconds(trailing.tenths))
}

@Composable
private fun footerText(footer: RelayCapTestFooter): String = when {
    footer.plural && footer.keyName != null ->
        pluralStringResource(footer.res, footer.count ?: 0, footer.count ?: 0, footer.keyName)
    footer.plural -> pluralStringResource(footer.res, footer.count ?: 0, footer.count ?: 0)
    footer.reason != null -> stringResource(footer.res, stringResource(footer.reason))
    else -> stringResource(footer.res)
}
