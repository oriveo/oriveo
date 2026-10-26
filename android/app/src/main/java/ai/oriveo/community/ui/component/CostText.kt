package ai.oriveo.community.ui.component

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.core.os.ConfigurationCompat
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.usage.CostPart
import java.util.Locale

/** UI locale used for non-USD cost parts (platform currency format with the UI locale). */
@Composable
fun rememberCostLocale(): Locale {
    val configuration = LocalConfiguration.current
    return remember(configuration) {
        ConfigurationCompat.getLocales(configuration)[0] ?: Locale.getDefault()
    }
}

/**
 * Per-currency cost text: parts joined by " + "; currencies whose amount is unknown
 * render the existing "not available" string instead of 0. Empty when nothing is displayable.
 */
@Composable
fun costPartsText(
    parts: List<CostPart>,
    notAvailableCodes: List<String> = emptyList(),
    usdPartTransform: (String) -> String = { it },
): String {
    val locale = rememberCostLocale()
    val notAvailableText = stringResource(R.string.context_compaction_detail_cost_unavailable)
    return remember(parts, notAvailableCodes, locale, notAvailableText, usdPartTransform) {
        CostFormatter.formatParts(parts, locale, notAvailableCodes, notAvailableText, usdPartTransform)
    }
}
