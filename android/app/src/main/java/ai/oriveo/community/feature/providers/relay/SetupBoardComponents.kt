package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoTheme

/*
 * Presentation pieces shared by the add page boards (Setup / LocalSetup). They only render the ViewModel board state and contain no criteria.
 */

/** Hero: small label + icon (+ trailing text-only label) -> title (accessibility heading) -> subtitle. */
@Composable
internal fun SetupBoardHero(
    icon: Painter,
    label: String,
    title: String,
    subtitle: String,
    tint: Color,
    /** A text-only label on the same row as the icon + label, pushed to the trailing end (the "Manual setup" label of manual setup); null = not shown. */
    tag: String? = null,
) {
    val colors = OriveoTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
            Text(
                text = label,
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = tint,
                modifier = if (tag != null) Modifier.weight(1f) else Modifier,
            )
            tag?.let {
                Text(
                    text = it,
                    style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textSecondary,
                    maxLines = 1,
                )
            }
        }
        Text(
            text = title,
            style = OriveoTheme.typography.hero,
            color = colors.textPrimary,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = subtitle,
            style = OriveoTheme.typography.body,
            color = colors.textSecondary,
        )
    }
}

/** The scheme shown by the address slot prefix chip: as the user wrote it if present, otherwise per connection convention (https for public, plain http for local). */
internal fun setupSchemeChip(endpoint: String, cleartext: Boolean): String =
    endpoint.trim().substringBefore("://", missingDelimiterValue = "").lowercase()
        .takeIf { it == "http" || it == "https" }
        ?: if (cleartext) "http" else "https"

/** In an address slot with a chip only the part after the scheme is shown; the scheme is shown by the chip. */
internal fun relaySchemeSlotText(endpoint: String): String =
    if ("://" in endpoint) endpoint.substringAfter("://") else endpoint

/**
 * Write slot input back into a full address: input containing "://" (a pasted full URL) replaces the whole string, otherwise the already written scheme is kept;
 * when the slot is cleared the scheme is cleared too, avoiding a half address that is just "https://".
 */
internal fun relaySchemeSlotInput(endpoint: String, slot: String): String = when {
    "://" in slot || slot.isEmpty() -> slot
    "://" in endpoint -> endpoint.substringBefore("://") + "://" + slot
    else -> slot
}

/** Convert a selection in the full address (e.g. the highlight of a completed scheme) to in-slot coordinates; the part inside the scheme is dropped. */
internal fun relaySchemeSlotRange(endpoint: String, range: IntRange?): IntRange? {
    range ?: return null
    val offset = endpoint.length - relaySchemeSlotText(endpoint).length
    val first = (range.first - offset).coerceAtLeast(0)
    val last = range.last - offset
    return if (last < first) null else first..last
}

/** Placeholder of the setup / manual setup address slot: the scheme is shown by the chip (URL examples are not translated). */
internal const val RELAY_ENDPOINT_PLACEHOLDER = "api.example.com"

/** Placeholder of the edit connection address slot (URL examples are not translated). */
internal const val RELAY_EDIT_ENDPOINT_PLACEHOLDER = "api.example.com/v1"

@Composable
internal fun SetupSchemeChip(scheme: String) {
    val colors = OriveoTheme.colors
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(colors.primarySoft)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(scheme, style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.primary)
    }
}

@Composable
internal fun SetupDot(color: Color) {
    Box(
        modifier = Modifier
            .size(10.dp)
            .clip(CircleShape)
            .background(color),
    )
}

@Composable
internal fun SetupResultCard(success: Boolean, content: @Composable ColumnScope.() -> Unit) {
    val colors = OriveoTheme.colors
    val tone = if (success) colors.success else colors.warning
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(if (success) colors.successSoft else colors.warningSoft)
            .border(1.dp, tone.copy(alpha = 0.3f), RoundedCornerShape(OriveoTheme.radius.md))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

/** Detecting: progress + "Detecting..." (same copy as iOS / Web; the primary button shows only a spinner while loading). */
@Composable
internal fun SetupDetectingCard(text: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OriveoTheme.radius.md))
            .background(colors.primarySoft)
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
        Text(text, style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
    }
}

@Composable
internal fun SetupCardTitleRow(success: Boolean, title: String, subtitle: String?) {
    val colors = OriveoTheme.colors
    val tone = if (success) colors.success else colors.warning
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            painter = painterResource(if (success) R.drawable.ph_check_circle else R.drawable.ph_warning_circle),
            contentDescription = null,
            tint = tone,
            modifier = Modifier.size(24.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            subtitle?.let { Text(it, style = OriveoTheme.typography.caption, color = colors.textSecondary) }
        }
    }
}

/**
 * Bottom action bar: gradient mask + (optional) a line above the button + primary button + a secondary "Manual" row under a hairline ([secondaryText] null means not drawn).
 */
@Composable
internal fun SetupActionBar(
    primaryText: String,
    primaryEnabled: Boolean,
    primaryLoading: Boolean,
    secondaryText: String?,
    onPrimary: () -> Unit,
    onSecondary: () -> Unit,
    modifier: Modifier = Modifier,
    header: (@Composable () -> Unit)? = null,
    /** The secondary row is tappable; by default it is the opposite of the primary button loading. Edit connection supplies it separately per the BOARD-EDIT-06 matrix, and it fades when not tappable. */
    secondaryEnabled: Boolean? = null,
    /** Icon before the secondary row; null = not drawn (the "Test connection" of edit connection is an in-place action, with no icon or arrow). */
    @androidx.annotation.DrawableRes secondaryIcon: Int? = R.drawable.ph_sliders_horizontal,
    /** Render the secondary action as an outlined button beside the primary on its left (edit connection "Test connection | Save", same as iOS); default false = unchanged. */
    secondaryInline: Boolean = false,
    /** The secondary row uses the step 1 "Manual setup" entry style (icon 18 + footnote semibold); other pages stay unchanged. */
    secondaryCompact: Boolean = false,
) {
    val colors = OriveoTheme.colors
    val secondaryClickable = secondaryEnabled ?: !primaryLoading
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, colors.background.copy(alpha = 0.96f), colors.background)))
            .navigationBarsPadding()
            .padding(horizontal = OriveoTheme.layout.screenH)
            .padding(top = 18.dp, bottom = 4.dp),
    ) {
        header?.let {
            it()
            Spacer(Modifier.height(10.dp))
        }
        if (secondaryInline && secondaryText != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OriveoSecondaryButton(
                    text = secondaryText,
                    onClick = onSecondary,
                    enabled = secondaryClickable,
                    modifier = Modifier
                        .weight(1f),
                )
                OriveoPrimaryButton(
                    text = primaryText,
                    onClick = onPrimary,
                    enabled = primaryEnabled,
                    loading = primaryLoading,
                    modifier = Modifier
                        .weight(1f),
                )
            }
            return@Column
        }
        OriveoPrimaryButton(
            text = primaryText,
            onClick = onPrimary,
            enabled = primaryEnabled,
            loading = primaryLoading,
            modifier = Modifier
                .fillMaxWidth(),
        )
        if (secondaryText == null) {
            Spacer(Modifier.height(14.dp))
            return@Column
        }
        Box(
            Modifier
                .padding(top = 14.dp)
                .fillMaxWidth()
                .height(1.dp)
                .background(Brush.horizontalGradient(listOf(Color.Transparent, colors.border, Color.Transparent))),
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = secondaryClickable, onClick = onSecondary)
                .padding(vertical = 14.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            secondaryIcon?.let {
                Icon(
                    painterResource(it),
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(if (secondaryCompact) 18.dp else 16.dp),
                )
            }
            Text(
                secondaryText,
                style = if (secondaryCompact) {
                    OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold)
                } else {
                    OriveoTheme.typography.body
                },
                color = if (secondaryEnabled == false) colors.textTertiary else colors.textSecondary,
            )
        }
    }
}
