package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.provider.RelayFormValidation
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

@Composable
internal fun RelayGroupHeader(
    title: String,
    icon: ImageVector,
    trailing: String? = null,
    tint: Color? = null,
) {
    val colors = OriveoTheme.colors
    val iconColor = tint ?: colors.textTertiary
    val iconBg = tint?.copy(alpha = 0.14f) ?: colors.surfaceInset
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        modifier = Modifier.padding(horizontal = 2.dp),
    ) {
        Box(
            modifier = Modifier
                .size(18.dp)
                .clip(RoundedCornerShape(5.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconColor,
                modifier = Modifier.size(11.dp),
            )
        }

        Text(
            text = title.uppercase(),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
            letterSpacing = 0.4.sp,
        )
        if (trailing != null) {
            Text(
                text = trailing.uppercase(),
                style = OriveoTheme.typography.footnote,
                color = colors.textTertiary,
            )
        }
    }
}

@Composable
internal fun RelayRowGroup(
    content: @Composable () -> Unit,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(OriveoTheme.radius.md)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface)
            .border(OriveoBorderWidth.standard, colors.border, shape),
    ) {
        content()
    }
}

@Composable
internal fun RelayRowDivider(leadingInset: androidx.compose.ui.unit.Dp = OriveoTheme.spacing.lg) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = leadingInset)
            .height(0.6.dp)
            .background(colors.border.opacity(0.6f)),
    )
}

@Composable
internal fun <T> RelayMenuRow(
    title: String,
    value: T,
    options: List<T>,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    enabled: Boolean = true,
    footnote: String? = null,
) {
    val colors = OriveoTheme.colors
    var expanded by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = enabled) { expanded = true }
                .padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = title,
                    style = OriveoTheme.typography.body,
                    color = if (enabled) colors.textPrimary else colors.textTertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (footnote != null) {
                    Text(
                        text = footnote,
                        style = OriveoTheme.typography.footnote,
                        color = colors.textTertiary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Text(
                text = label(value),
                style = OriveoTheme.typography.body,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(12.dp),
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            RelayMenuOptions(
                options = options,
                label = label,
                onSelect = { option ->
                    onSelect(option)
                    expanded = false
                },
            )
        }
    }
}

/** Above this many options the menu switches to a lazy list; small enums like transport or auth keep DropdownMenu's native content width. */
internal const val RelayMenuLazyThreshold = 32

/** Material's menu width cap (DropdownMenuItem's own maxWidth); a lazy list cannot measure its content width, so use the cap directly. */
private val RelayLazyMenuWidth = 280.dp

/**
 * The option area of a DropdownMenu.
 *
 * DropdownMenu's content is a **non-lazy** Column measured with `IntrinsicSize.Max` width,
 * so opening it composes every row and measures each one's intrinsic size before the real
 * measure pass. When the options are a model catalog (it comes from the user's own server,
 * and thousands of entries are normal), 1500 rows cost 60-140ms on the JVM and several times
 * that on a device, all on the main thread and growing with the catalog. Above
 * [RelayMenuLazyThreshold] the options go into a fixed-size LazyColumn that only composes the
 * dozen or so visible rows.
 *
 * LazyColumn does not support intrinsic measurement, and the DropdownMenu content is a
 * `width(IntrinsicSize.Max)` Column that asks each child for its intrinsic **height** while
 * computing the intrinsic width. The outer Box must therefore pin both width and height: a
 * fixed-size SizeNode answers both queries itself and never forwards them to the LazyColumn
 * (pinning only the width crashes as soon as the menu opens). Half the screen height is used
 * because more than the threshold's worth of 48dp rows always exceeds it, so the fixed height
 * is never taller than the content.
 */
@Composable
internal fun <T> RelayMenuOptions(
    options: List<T>,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    maxLines: Int = Int.MAX_VALUE,
) {
    if (options.size <= RelayMenuLazyThreshold) {
        options.forEach { option ->
            RelayMenuOptionItem(option = option, label = label, onSelect = onSelect, maxLines = maxLines)
        }
        return
    }
    val menuHeight = (LocalConfiguration.current.screenHeightDp / 2).dp
    Box(modifier = Modifier.size(width = RelayLazyMenuWidth, height = menuHeight)) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(options) { option ->
                RelayMenuOptionItem(option = option, label = label, onSelect = onSelect, maxLines = maxLines)
            }
        }
    }
}

@Composable
private fun <T> RelayMenuOptionItem(
    option: T,
    label: @Composable (T) -> String,
    onSelect: (T) -> Unit,
    maxLines: Int,
) {
    DropdownMenuItem(
        text = { Text(label(option), maxLines = maxLines, overflow = TextOverflow.Ellipsis) },
        onClick = { onSelect(option) },
    )
}

@Composable
internal fun RelayToggleRow(
    title: String,
    isOn: Boolean,
    onToggle: (Boolean) -> Unit,
    enabled: Boolean = true,
    footnote: String? = null,
) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = OriveoTheme.typography.body,
                color = if (enabled) colors.textPrimary else colors.textTertiary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (footnote != null) {
                Text(
                    text = footnote,
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Switch(
            checked = isOn,
            enabled = enabled,
            onCheckedChange = onToggle,
        )
    }
}

@Composable
internal fun RelayInlineTextRow(
    title: String,
    text: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    enabled: Boolean = true,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    val colors = OriveoTheme.colors
    val textStyle = OriveoTheme.typography.body.copy(
        color = if (enabled) colors.textPrimary else colors.textTertiary,
        textAlign = TextAlign.End,
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.body,
            color = if (enabled) colors.textPrimary else colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        BasicTextField(
            value = text,
            onValueChange = onValueChange,
            singleLine = true,
            enabled = enabled,
            textStyle = textStyle,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            cursorBrush = SolidColor(colors.primary),
            modifier = Modifier.weight(2f),
            decorationBox = { innerTextField ->
                Box(
                    modifier = Modifier.fillMaxWidth(),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    if (text.isEmpty()) {
                        Text(
                            text = placeholder,
                            style = textStyle.copy(color = colors.textTertiary),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    innerTextField()
                }
            },
        )
    }
}

@Composable
internal fun RelayFormIssueNotes(
    issues: List<RelayFormValidation.FieldIssue>,
    modifier: Modifier = Modifier,
) {
    val notes = RelayFormValidation.displayableIssues(issues)
    if (notes.isEmpty()) return
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
    ) {
        notes.forEach { issue ->
            Text(
                text = stringResource(issue.messageRes),
                style = OriveoTheme.typography.footnote,
                color = OriveoTheme.colors.danger,
            )
        }
    }
}
