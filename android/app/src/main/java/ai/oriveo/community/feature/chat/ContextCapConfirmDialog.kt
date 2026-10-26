package ai.oriveo.community.feature.chat

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.PendingContextCapConfirmation

/**
 * Pre-send confirmation dialog: title, body, the "don't ask again" checkbox only when the
 * decision shows it (starts unchecked), then [Cancel] [Send anyway]. Tapping outside or back = cancel; there is no
 * default / Enter action on send.
 */
@Composable
fun ContextCapConfirmDialog(
    pending: PendingContextCapConfirmation,
    onSend: (dontAsk: Boolean) -> Unit,
    onCancel: () -> Unit,
) {
    val locale = LocalConfiguration.current.locales[0].toLanguageTag()
    val strings = contextConfirmStrings()
    val panelStrings = contextCapPanelStrings()
    val text = ContextCapConfirmPresentation.text(
        pending.decision, pending.input, pending.modelName, strings, panelStrings, locale,
    ) ?: return
    // A new pending confirmation starts unchecked again.
    var dontAsk by rememberSaveable(pending.id) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(text.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(text.body)
                text.dontAsk?.let { label ->
                    Row(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Checkbox(
                            checked = dontAsk,
                            onCheckedChange = { dontAsk = it },
                            modifier = Modifier.testTag("context_confirm_dont_ask"),
                        )
                        Text(label)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSend(dontAsk) },
                modifier = Modifier.testTag("context_confirm_send"),
            ) {
                Text(text.confirm)
            }
        },
        dismissButton = {
            TextButton(
                onClick = onCancel,
                modifier = Modifier.testTag("context_confirm_cancel"),
            ) {
                Text(text.cancel)
            }
        },
    )
}

@Composable
private fun contextConfirmStrings() = ContextConfirmStrings(
    overCapTitle = stringResource(R.string.context_confirm_over_cap_title),
    overCapBody = stringResource(R.string.context_confirm_over_cap_body),
    priceLineTitle = stringResource(R.string.context_confirm_price_line_title),
    priceLineBodyCost = stringResource(R.string.context_confirm_price_line_body_cost),
    priceLineBodyMult = stringResource(R.string.context_confirm_price_line_body_mult),
    priceLineBody = stringResource(R.string.context_confirm_price_line_body),
    alsoPriceLineCost = stringResource(R.string.context_confirm_also_price_line_cost),
    alsoPriceLineMult = stringResource(R.string.context_confirm_also_price_line_mult),
    alsoPriceLine = stringResource(R.string.context_confirm_also_price_line),
    dontAsk = stringResource(R.string.context_confirm_dont_ask),
    send = stringResource(R.string.context_confirm_send),
    cancel = stringResource(R.string.cancel),
)

/** Same multiplier sentence templates as the cap panel. */
@Composable
private fun contextCapPanelStrings() = ContextCapPanelStrings(
    windowLine = stringResource(R.string.context_cap_window_line),
    windowLinePrice = stringResource(R.string.context_cap_window_line_price),
    windowLinePricePlain = stringResource(R.string.context_cap_window_line_price_plain),
    aboveLine = stringResource(R.string.context_cap_above_line),
    multBoth = stringResource(R.string.context_cap_mult_both),
    multInput = stringResource(R.string.context_cap_mult_input),
    multOutput = stringResource(R.string.context_cap_mult_output),
    multSplit = stringResource(R.string.context_cap_mult_split),
)
