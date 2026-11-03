package ai.oriveo.community.ui.component

import androidx.compose.material3.SwitchColors
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Switch colors shared by every toggle: the checked thumb is always [ai.oriveo.community.ui.theme.OriveoColors.switchThumb]
 * (white, matching iOS) instead of M3's `colorScheme.onPrimary`, which turns dark under light brand palettes and in
 * dark mode. Every other slot keeps the M3 default.
 */
@Composable
fun oriveoSwitchColors(): SwitchColors =
    SwitchDefaults.colors(checkedThumbColor = OriveoTheme.colors.switchThumb)
