package ai.oriveo.community.feature.mcp

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.mcp.McpCard
import ai.oriveo.community.feature.chat.mcp.McpHairline
import ai.oriveo.community.feature.chat.mcp.McpServerIcon
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme

// Shared look of the connect and management screens. The chat-side sheet look is in `McpSheetChrome.kt`;
// cards, initial tiles and dividers are reused from there.

/**
 * Page skeleton: page background + transparent top bar (back / centred title / trailing action) + scrollable content + a button area pinned to the bottom.
 * Content has 16 horizontal padding and 18 between blocks; the button area moves up with the keyboard.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun McpPageScaffold(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    actions: @Composable () -> Unit = {},
    bottomBar: (@Composable ColumnScope.() -> Unit)? = null,
    refresh: McpPullRefresh? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Box(modifier = modifier.fillMaxSize()) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                CenterAlignedTopAppBar(
                    title = {
                        Text(
                            text = title,
                            style = OriveoTheme.typography.title3,
                            color = OriveoTheme.colors.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    navigationIcon = { OriveoBackButton(onClick = onBack) },
                    actions = { actions() },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
            bottomBar = {
                if (bottomBar != null) McpBottomActions(content = bottomBar)
            },
        ) { padding ->
            if (refresh == null) {
                McpPageBody(modifier = Modifier.padding(padding), content = content)
            } else {
                PullToRefreshBox(
                    isRefreshing = refresh.refreshing,
                    onRefresh = refresh.onRefresh,
                    modifier = Modifier.padding(padding),
                ) {
                    McpPageBody(content = content)
                }
            }
        }
    }
}

/** Pull to refresh: when provided, the page content can be pulled down. */
internal class McpPullRefresh(val refreshing: Boolean, val onRefresh: () -> Unit)

/** Page content column. A separate function so UI tests can render a page's content without the Scaffold. */
@Composable
internal fun McpPageBody(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        content = content,
    )
}

/** Bottom button area: primary button + text button stacked, sitting on top of the navigation bar. */
@Composable
internal fun McpBottomActions(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .imePadding()
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        content = content,
    )
}

// ── Hero card ───────────────────────────────────────────────

/** Server icon slot: the initial tile when the name is known, a globe while only the host name is. */
@Composable
internal fun McpHeroIcon(name: String, nameKnown: Boolean, size: Dp = 52.dp, iconUrl: String? = null, serverUrl: String? = null) {
    if (nameKnown || iconUrl != null || ai.oriveo.community.core.mcp.McpBrandIcons.key(name, serverUrl) != null) {
        McpServerIcon(name = name, iconUrl = iconUrl, size = size, serverUrl = serverUrl)
        return
    }
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .size(size)
            .background(colors.primarySoft, RoundedCornerShape(size * 0.28f))
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Outlined.Language, contentDescription = null, modifier = Modifier.size(size * 0.46f), tint = colors.primaryTextSafe)
    }
}

/** Hero card: icon 52 + title 22 / 800 + one status row (pill and note); key-value rows and buttons may follow below. */
@Composable
internal fun McpHeroCard(
    name: String,
    modifier: Modifier = Modifier,
    nameKnown: Boolean = true,
    status: (@Composable () -> Unit)? = null,
    caption: String? = null,
    iconUrl: String? = null,
    serverUrl: String? = null,
    icon: @Composable () -> Unit = { McpHeroIcon(name = name, nameKnown = nameKnown, iconUrl = iconUrl, serverUrl = serverUrl) },
    extra: (@Composable ColumnScope.() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    McpCard(modifier = modifier, contentPadding = PaddingValues(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            icon()
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = name,
                    style = OriveoTheme.typography.title1.copy(fontWeight = FontWeight.ExtraBold),
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() },
                )
                if (status != null || !caption.isNullOrEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        status?.invoke()
                        if (!caption.isNullOrEmpty()) {
                            Text(
                                text = caption,
                                style = OriveoTheme.typography.caption,
                                color = colors.textSecondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
        extra?.invoke(this)
    }
}

// ── Status pill ─────────────────────────────────────────────

internal enum class McpPillTone { Success, Warning, Danger, Neutral, Primary }

/** Status pill: height 24, horizontal padding 9, 12 / 600, tinted background + outline of the same hue. */
@Composable
internal fun McpStatusPill(text: String, tone: McpPillTone, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val (fill, ink) = when (tone) {
        McpPillTone.Success -> colors.successSoft to colors.success
        McpPillTone.Warning -> colors.warningSoft to colors.warningText
        McpPillTone.Danger -> colors.dangerSoft to colors.danger
        McpPillTone.Neutral -> colors.surfaceInset to colors.textSecondary
        McpPillTone.Primary -> colors.primarySoft to colors.primaryTextSafe
    }
    val line = if (tone == McpPillTone.Neutral) colors.borderStrong else ink.copy(alpha = 0.28f)
    Box(
        modifier = modifier
            .heightIn(min = 24.dp)
            .background(fill, CircleShape)
            .border(1.dp, line, CircleShape)
            .padding(horizontal = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = ink,
            maxLines = 1,
        )
    }
}

// ── Checklist card ──────────────────────────────────────────

internal enum class McpChecklistState { Done, Active, Waiting }

internal data class McpChecklistRow(val text: String, val state: McpChecklistState, val detail: String? = null)

/** Checklist card: per row a 20 status icon + 15 text; pending rows use the tertiary text colour. Status has a text label besides the shape (accessibility). */
@Composable
internal fun McpChecklistCard(rows: List<McpChecklistRow>, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    McpCard(modifier = modifier, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
        rows.forEachIndexed { index, row ->
            if (index > 0) McpHairline()
            val stateLabel = stringResource(
                when (row.state) {
                    McpChecklistState.Done -> R.string.mcp_step_state_done
                    McpChecklistState.Active -> R.string.mcp_step_state_in_progress
                    McpChecklistState.Waiting -> R.string.mcp_step_state_waiting
                },
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .padding(vertical = 10.dp)
                    .semantics(mergeDescendants = true) { stateDescription = stateLabel },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(modifier = Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                    when (row.state) {
                        McpChecklistState.Done ->
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, modifier = Modifier.size(20.dp), tint = colors.success)
                        McpChecklistState.Active -> CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = colors.primary,
                            trackColor = colors.border,
                        )
                        McpChecklistState.Waiting -> {
                            val ring = colors.textTertiary
                            Box(
                                modifier = Modifier.size(16.dp).drawBehind {
                                    drawCircle(
                                        color = ring,
                                        radius = size.minDimension / 2 - 1.dp.toPx(),
                                        style = Stroke(
                                            width = 1.5.dp.toPx(),
                                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())),
                                        ),
                                    )
                                },
                            )
                        }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = row.text,
                        style = OriveoTheme.typography.body.copy(
                            fontSize = 15.sp,
                            fontWeight = if (row.state == McpChecklistState.Waiting) FontWeight.Normal else FontWeight.SemiBold,
                        ),
                        color = if (row.state == McpChecklistState.Waiting) colors.textTertiary else colors.textPrimary,
                    )
                    if (!row.detail.isNullOrEmpty()) {
                        Text(text = row.detail, style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp), color = colors.textTertiary)
                    }
                }
            }
        }
    }
}

// ── Notice block ────────────────────────────────────────────

/** Notice block: radius 16, tinted background + outline of the same hue; title 15 / 600 in the same hue, body 13.5 in the secondary text colour. */
@Composable
internal fun McpNoticeBlock(title: String, body: String, tone: McpPillTone, modifier: Modifier = Modifier) {
    val colors = OriveoTheme.colors
    val (fill, ink) = when (tone) {
        McpPillTone.Danger -> colors.dangerSoft to colors.danger
        else -> colors.warningSoft to colors.warningText
    }
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(fill, shape)
            .border(1.dp, ink.copy(alpha = 0.28f), shape)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
            color = ink,
        )
        Text(text = body, style = OriveoTheme.typography.caption.copy(fontSize = 13.5.sp), color = colors.textSecondary)
    }
}

// ── Form ────────────────────────────────────────────────────

@Composable
internal fun McpFieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
        color = OriveoTheme.colors.textPrimary,
        modifier = modifier.padding(horizontal = 6.dp),
    )
}

/**
 * Text field: height 52, radius 14; brand-coloured outline + light outer ring when focused; danger-coloured outline with 12.5 error text below on error.
 * [label] doubles as the field name announced by screen readers.
 */
@Composable
internal fun McpTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    errorText: String? = null,
    monospace: Boolean = false,
    secure: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    val colors = OriveoTheme.colors
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val shape = RoundedCornerShape(14.dp)
    val isError = errorText != null
    val borderColor = when {
        isError -> colors.danger
        focused -> colors.primary
        else -> colors.border
    }
    val ringColor = if (focused && !isError) colors.primary.copy(alpha = 0.16f) else Color.Transparent
    val textStyle = (if (monospace) OriveoTheme.typography.code.copy(fontSize = 15.sp) else OriveoTheme.typography.body)
        .copy(color = colors.textPrimary)
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = textStyle,
            cursorBrush = SolidColor(colors.primary),
            interactionSource = interactionSource,
            visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType, autoCorrectEnabled = false),
            modifier = Modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription = label
                    if (errorText != null) error(errorText)
                },
            decorationBox = { inner ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .drawBehind {
                            val spread = 3.dp.toPx()
                            drawRoundRect(
                                color = ringColor,
                                topLeft = androidx.compose.ui.geometry.Offset(-spread, -spread),
                                size = androidx.compose.ui.geometry.Size(size.width + spread * 2, size.height + spread * 2),
                                cornerRadius = CornerRadius(14.dp.toPx() + spread),
                            )
                        }
                        .heightIn(min = 52.dp)
                        .background(colors.surface, shape)
                        .border(if (focused || isError) 1.5.dp else 1.dp, borderColor, shape)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(
                            text = placeholder,
                            style = textStyle.copy(fontFamily = FontFamily.Default, fontSize = 16.sp),
                            color = colors.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.clearAndSetSemantics { },
                        )
                    }
                    inner()
                }
            },
        )
        if (errorText != null) {
            Text(
                text = errorText,
                style = OriveoTheme.typography.footnote.copy(fontSize = 12.5.sp, lineHeight = 18.sp),
                color = colors.danger,
                modifier = Modifier.padding(horizontal = 6.dp),
            )
        }
    }
}

/** Segmented control: two segments on an inset background; the selected one uses the card colour. */
@Composable
internal fun McpSegmented(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.surfaceInset, shape)
            .border(1.dp, colors.border, shape)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEachIndexed { index, option ->
            val selected = index == selectedIndex
            val segmentShape = RoundedCornerShape(11.dp)
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .clip(segmentShape)
                    .background(if (selected) colors.surface else Color.Transparent)
                    .semantics { this.selected = selected }
                    .clickable(role = Role.Tab) { onSelect(index) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = option,
                    style = OriveoTheme.typography.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = if (selected) colors.textPrimary else colors.textSecondary,
                    maxLines = 1,
                )
            }
        }
    }
}

/** Section title (17 / 600) + trailing count. */
@Composable
internal fun McpSectionTitle(title: String, modifier: Modifier = Modifier, trailing: String? = null) {
    val colors = OriveoTheme.colors
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = OriveoTheme.typography.title3.copy(fontSize = 17.sp),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        if (trailing != null) {
            Text(text = trailing, style = OriveoTheme.typography.caption, color = colors.textTertiary)
        }
    }
}
