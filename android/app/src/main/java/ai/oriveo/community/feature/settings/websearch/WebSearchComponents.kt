package ai.oriveo.community.feature.settings.websearch

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.search.SearchPriceSummary
import ai.oriveo.community.core.search.SearchTestPresentation
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.providerLogoRes
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.NumberFormat

internal val WsCardShape = RoundedCornerShape(14.dp)

/** Page chrome shared by every web search page (same as the theme settings page). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WsPage(
    title: @Composable () -> Unit,
    onBack: () -> Unit,
    tag: String,
    bottomBar: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Box(modifier = Modifier.fillMaxSize().testTag(tag)) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = title,
                    navigationIcon = { OriveoBackButton(onClick = onBack, modifier = Modifier.testTag("${tag}_back")) },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
            bottomBar = {
                if (bottomBar != null) {
                    Box(Modifier.padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp)) { bottomBar() }
                }
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(top = 6.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                content = content,
            )
        }
    }
}

@Composable
internal fun WsTitle(text: String) {
    Text(text = text, style = OriveoTheme.typography.title3, color = OriveoTheme.colors.textPrimary)
}

@Composable
internal fun WsSection(title: String) {
    FlatSectionHeader(title = title, modifier = Modifier.padding(top = 12.dp, start = 4.dp))
}

@Composable
internal fun WsFooter(text: String, color: Color = OriveoTheme.colors.textTertiary) {
    Text(
        text = text,
        style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp),
        color = color,
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg + 4.dp),
    )
}

@Composable
internal fun WsCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .padding(horizontal = OriveoTheme.spacing.lg)
            .fillMaxWidth()
            .clip(WsCardShape)
            .background(OriveoTheme.colors.surface),
        content = content,
    )
}

@Composable
internal fun WsDivider() {
    InsetHairline()
}

/** A tappable card row with press feedback; [onClick] null = static row. */
@Composable
internal fun WsRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    subtitleColor: Color = OriveoTheme.colors.textTertiary,
    titleColor: Color = OriveoTheme.colors.textPrimary,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    titleTrailing: (@Composable RowScope.() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        leading?.invoke()
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = title,
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium),
                    color = if (enabled) titleColor else OriveoTheme.colors.textTertiary,
                    modifier = Modifier.weight(1f, fill = false),
                )
                titleTrailing?.invoke(this)
            }
            if (!subtitle.isNullOrEmpty()) {
                Text(text = subtitle, style = TextStyle(fontSize = 12.sp, lineHeight = 17.sp), color = subtitleColor)
            }
        }
        trailing?.invoke()
    }
}

@Composable
internal fun WsTag(text: String, emphasized: Boolean) {
    val colors = OriveoTheme.colors
    Text(
        text = text,
        style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
        color = if (emphasized) colors.primaryTextSafe else colors.textSecondary,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (emphasized) colors.primarySoft else colors.surfaceInset)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@DrawableRes
private fun presetLogoRes(serviceId: String?, dark: Boolean): Int? = when (serviceId) {
    "deepseek" -> providerLogoRes(ProviderKind.DeepSeek, dark)
    "zhipu" -> providerLogoRes(ProviderKind.Zhipu, dark)
    "kimi" -> providerLogoRes(ProviderKind.Moonshot, dark)
    "tavily" -> R.drawable.ic_web_search_logo_tavily
    "exa" -> R.drawable.ic_web_search_logo_exa
    "brave" -> R.drawable.ic_web_search_logo_brave
    "perplexity" -> R.drawable.ic_web_search_logo_perplexity
    else -> null
}

/** Catalog logo by serviceId; custom services and unknown ids use the generic server icon. No border, no plate. */
@Composable
internal fun WsLogo(serviceId: String?, custom: Boolean, size: Dp) {
    val res = if (custom) null else presetLogoRes(serviceId, OriveoTheme.isDark)
    if (res != null) {
        Image(painter = painterResource(res), contentDescription = null, modifier = Modifier.size(size).clip(RoundedCornerShape(size * 0.22f)))
    } else {
        Icon(
            imageVector = Icons.Outlined.Dns,
            contentDescription = null,
            tint = OriveoTheme.colors.textSecondary,
            modifier = Modifier.size(size),
        )
    }
}

// ── Text helpers ──────────────────────────────────────────

@Composable
private fun locale() = LocalConfiguration.current.locales[0]

/** Price summary fragments joined with " · ". */
@Composable
internal fun priceText(summary: SearchPriceSummary, withOtherRegion: Boolean = false): String {
    val parts = mutableListOf<String>()
    summary.price?.let { p ->
        parts += if (p.unit == "per_request") {
            stringResource(R.string.web_search_price_per_request, p.label)
        } else {
            stringResource(R.string.web_search_price_per1k, p.label)
        }
    }
    summary.free?.let { f ->
        val count = f.count
        parts += if (count != null) {
            stringResource(R.string.web_search_price_free_credits, NumberFormat.getIntegerInstance(locale()).format(count))
        } else {
            stringResource(R.string.web_search_price_free_usd, f.amountLabel.orEmpty())
        }
        parts += stringResource(if (f.cardRequired) R.string.web_search_price_card_required else R.string.web_search_price_no_card)
    }
    if (withOtherRegion && summary.otherRegionCount > 0) parts += stringResource(R.string.web_search_price_other_region)
    return parts.joinToString(" · ")
}

@StringRes
internal fun headlineRes(headline: String): Int = when (headline) {
    "key_rejected" -> R.string.web_search_error_key_rejected
    "insufficient_balance" -> R.string.web_search_error_insufficient_balance
    "rate_limited" -> R.string.web_search_error_rate_limited
    "no_response" -> R.string.web_search_error_no_response
    "format_mismatch" -> R.string.web_search_error_format_mismatch
    "searxng_json_disabled" -> R.string.web_search_error_searxng_json_disabled
    "host_changed" -> R.string.web_search_error_host_changed
    "service_withdrawn" -> R.string.web_search_error_service_withdrawn
    else -> R.string.web_search_error_service_error
}

@StringRes
internal fun actionRes(action: String): Int? = when (action) {
    "update_key" -> R.string.web_search_action_update_key
    "top_up" -> R.string.web_search_action_top_up
    "check_settings" -> R.string.web_search_action_check_settings
    "view_setup_guide" -> R.string.web_search_action_view_setup_guide
    "reconfirm" -> R.string.web_search_action_reconfirm
    "retry" -> R.string.web_search_action_retry
    else -> null
}

@StringRes
internal fun formErrorRes(key: String): Int = when (key) {
    "nameEmpty" -> R.string.web_search_form_name_empty
    "nameTooLong" -> R.string.web_search_form_name_too_long
    "httpPublic" -> R.string.web_search_form_http_public
    "httpOnWeb" -> R.string.web_search_form_http_on_web
    "privateOnWeb" -> R.string.web_search_form_private_on_web
    "portOnWeb" -> R.string.web_search_form_port_on_web
    "addressUnresolved" -> R.string.web_search_form_address_unresolved
    "protocolInvalid" -> R.string.web_search_form_protocol_invalid
    "presetUnavailable" -> R.string.web_search_form_preset_unavailable
    "mappingIncomplete" -> R.string.web_search_form_mapping_incomplete
    "headerName" -> R.string.web_search_form_header_name
    "pathInvalid" -> R.string.web_search_form_path_invalid
    "getBody" -> R.string.web_search_form_get_body
    "tooManyParams" -> R.string.web_search_form_too_many_params
    "paramValue" -> R.string.web_search_form_param_value
    "template" -> R.string.web_search_form_template
    "pathConflict" -> R.string.web_search_form_path_conflict
    "keyEmpty" -> R.string.web_search_form_key_empty
    "keyInvalid" -> R.string.web_search_form_key_invalid
    "cleartextLan" -> R.string.web_search_form_cleartext_lan
    else -> R.string.web_search_form_address_invalid
}

@StringRes
internal fun protocolNameRes(protocol: String?): Int = when (protocol) {
    "same_as" -> R.string.web_search_custom_protocol_same_as
    "manual" -> R.string.web_search_custom_protocol_manual
    else -> R.string.web_search_custom_protocol_searxng
}

@Composable
internal fun regionLabel(regionId: String): String = when (regionId) {
    "cn" -> stringResource(R.string.web_search_region_cn)
    "intl" -> stringResource(R.string.web_search_region_intl)
    else -> regionId
}

/** "Passed · 0.8 s · 5 results" with the tenths formatted for the current language. */
@Composable
internal fun passedText(p: SearchTestPresentation.Passed): String {
    val nf = NumberFormat.getNumberInstance(locale()).apply {
        minimumFractionDigits = 1
        maximumFractionDigits = 1
    }
    return stringResource(
        R.string.web_search_test_passed,
        nf.format(p.latencyTenths / 10.0),
        NumberFormat.getIntegerInstance(locale()).format(p.count),
    )
}
