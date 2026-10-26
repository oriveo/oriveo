package ai.oriveo.community.feature.chat

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.component.markdown.MarkdownMessageView
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

/** Detail sheet buttons; each one dispatches its action, then closes the sheet. */
class ContextCompactionDetailActions(
    val onRecompact: () -> Unit,
    val onClear: () -> Unit,
    val onNewChatWithSummary: () -> Unit,
)

/**
 * Wires the three detail buttons to the chat-page actions: condense again (rule 4), clear without a second
 * confirmation (rule 3), new chat with summary (rule 7, [quoteLabel] = context_compaction_quote_label).
 */
fun ChatCompactionUiCoordinator.detailActions(quoteLabel: String, close: () -> Unit) = ContextCompactionDetailActions(
    onRecompact = {
        launchRecompact()
        close()
    },
    onClear = {
        launchClear()
        close()
    },
    onNewChatWithSummary = {
        startNewChatWithSummary(quoteLabel)
        close()
    },
)

/** Shows the compaction result toasts through GlobalSnackbarManager. */
@Composable
fun ContextCompactionToastEffect(coordinator: ChatCompactionUiCoordinator?, openProviderDetail: (String) -> Unit) {
    val currentOpenProviderDetail by rememberUpdatedState(openProviderDetail)
    LaunchedEffect(coordinator) {
        coordinator?.providerDetailRequests?.collect { currentOpenProviderDetail(it) }
    }
    val snackbar = rememberGlobalSnackbarManager()
    LaunchedEffect(coordinator, snackbar) {
        val manager = snackbar ?: return@LaunchedEffect
        coordinator?.toasts?.collect { manager.show(it.snackbarMessage()) }
    }
}

/** Read-only detail of the latestValid compaction row. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextCompactionDetailSheet(
    detail: ContextCompactionDetail,
    actions: ContextCompactionDetailActions,
    recompactEnabled: Boolean,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { ai.oriveo.community.ui.component.OriveoSheetDragHandle() },
        containerColor = colors.backgroundBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = stringResource(R.string.context_compaction_detail_title),
                style = OriveoTheme.typography.title3,
                color = colors.textPrimary,
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                val summary = detail.summary
                if (summary != null) {
                    Text(
                        text = stringResource(R.string.context_compaction_detail_summary),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                    )
                    MarkdownMessageView(text = summary, modifier = Modifier.fillMaxWidth())
                } else {
                    Text(
                        text = stringResource(R.string.context_compaction_detail_fallback_note),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                    )
                }
                Text(
                    text = pluralStringResource(R.plurals.context_compaction_detail_kept, detail.kept, detail.kept),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
            }
            HorizontalDivider(color = colors.hairline)
            DetailRow(stringResource(R.string.context_compaction_detail_model), detail.model)
            DetailRow(
                stringResource(R.string.context_compaction_detail_cost),
                when (val cost = detail.cost) {
                    ContextCompactionCost.NoExtraCost -> stringResource(R.string.context_compaction_detail_no_extra_cost)
                    ContextCompactionCost.Unavailable -> stringResource(R.string.context_compaction_detail_cost_unavailable)
                    is ContextCompactionCost.Amount -> formatCompactionCost(cost.value)
                },
            )
            DetailRow(
                stringResource(R.string.context_compaction_detail_time),
                DateUtils.formatDateTime(
                    context,
                    detail.createdAt,
                    DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH,
                ),
            )
            HorizontalDivider(color = colors.hairline)
            TextButton(
                onClick = actions.onRecompact,
                enabled = recompactEnabled,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.context_compaction_action_recompact))
            }
            TextButton(
                onClick = actions.onClear,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.context_compaction_action_clear))
            }
            TextButton(
                onClick = actions.onNewChatWithSummary,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.context_compaction_action_new_chat_with_summary))
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    val colors = OriveoTheme.colors
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(text = label, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
        Text(text = value, style = OriveoTheme.typography.footnote, color = colors.textPrimary)
    }
}

/** Compaction calls cost fractions of a cent, so up to four decimals. */
private fun formatCompactionCost(value: Double): String =
    NumberFormat.getCurrencyInstance(Locale.getDefault()).apply {
        currency = Currency.getInstance("USD")
        minimumFractionDigits = 2
        maximumFractionDigits = 4
    }.format(value)
