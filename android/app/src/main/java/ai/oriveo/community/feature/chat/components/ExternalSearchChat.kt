package ai.oriveo.community.feature.chat.components

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.SearchMessageErrorCard
import ai.oriveo.community.core.model.SearchMessageSourcesLine
import ai.oriveo.community.core.model.SearchMessageSwitchTarget
import ai.oriveo.community.core.search.EXTERNAL_SEARCH_SOURCE
import ai.oriveo.community.core.search.ExternalSearchActivityState
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

// External web search in chat (external search service contract): activity line chips, sources card, error card.
// Every state reads exactly one persisted / streamed source: the activity reads streamingExternalSearch, the sources card
// reads message.searchSourcesLine, the error card reads message.searchErrorCard, the notice reads message.searchNotice.

/** What a search error card button does. */
internal enum class SearchCardAction {
    /** Open the service detail (key rejected). */
    UpdateKey,

    /** External link: the chosen site's pricing page. */
    TopUp,

    /** Regenerate with a new search (regenerate.action = re_search). */
    Retry,

    /** Open model options › search method. */
    SwitchService,

    /** Open the custom service editor. */
    CheckSettings,

    /** External link: the search setup guide. */
    ViewSetupGuide,

    /** Open the service detail to confirm the new address. */
    Reconfirm,
}

internal data class SearchCardButton(
    val action: SearchCardAction,
    @param:StringRes val titleRes: Int,
    /** Opens an external page (shows the external-link icon). */
    val external: Boolean = false,
    /** Regenerates the answer: only offered on the last answer. */
    val regenerates: Boolean = false,
)

internal data class SearchErrorCardModel(
    @param:StringRes val headlineRes: Int,
    val serviceName: String,
    val serviceId: String?,
    val primary: SearchCardButton?,
    /** "Answer again with X"; only on the last answer (it regenerates). */
    val answerWith: SearchMessageSwitchTarget?,
)

/** Sources card header: lead · service name [custom badge] · count (or no sources). */
internal data class SearchSourcesHeaderModel(
    val reused: Boolean,
    val searchCount: Int,
    val serviceName: String,
    val custom: Boolean,
    val sourceCount: Int,
) {
    /** 0 sources: no expand chevron. */
    val expandable: Boolean get() = sourceCount > 0
}

internal object ExternalSearchChatPresentation {
    /** finishSearchReply.errorCard.headline → chatError.<camelCase>. */
    @StringRes
    fun headlineRes(headline: String): Int? = when (headline) {
        "key_rejected" -> R.string.web_search_chat_error_key_rejected
        "insufficient_balance" -> R.string.web_search_chat_error_insufficient_balance
        "rate_limited" -> R.string.web_search_chat_error_rate_limited
        "no_response" -> R.string.web_search_chat_error_no_response
        "service_error" -> R.string.web_search_chat_error_service_error
        "format_mismatch" -> R.string.web_search_chat_error_format_mismatch
        "searxng_json_disabled" -> R.string.web_search_chat_error_searxng_json_disabled
        "host_changed" -> R.string.web_search_chat_error_host_changed
        "service_withdrawn" -> R.string.web_search_chat_error_service_withdrawn
        else -> null
    }

    /** finishSearchReply.errorCard.primaryAction → button. */
    fun primaryButton(primaryAction: String): SearchCardButton? = when (primaryAction) {
        "update_key" -> SearchCardButton(SearchCardAction.UpdateKey, R.string.web_search_action_update_key)
        "top_up" -> SearchCardButton(SearchCardAction.TopUp, R.string.web_search_action_top_up, external = true)
        "retry", "retry_later" -> SearchCardButton(SearchCardAction.Retry, R.string.web_search_action_retry, regenerates = true)
        "switch_service" -> SearchCardButton(SearchCardAction.SwitchService, R.string.web_search_action_switch_service)
        "check_settings" -> SearchCardButton(SearchCardAction.CheckSettings, R.string.web_search_action_check_settings)
        "view_setup_guide" -> SearchCardButton(SearchCardAction.ViewSetupGuide, R.string.web_search_action_view_setup_guide, external = true)
        "reconfirm" -> SearchCardButton(SearchCardAction.Reconfirm, R.string.web_search_action_reconfirm)
        else -> null
    }

    /**
     * Error card for a message. Buttons that regenerate (retry, answer with X) only show on the last answer;
     * older messages keep only the navigation buttons.
     */
    fun errorCard(card: SearchMessageErrorCard, isLastMessage: Boolean, switchToAvailable: Boolean): SearchErrorCardModel =
        SearchErrorCardModel(
            // An unrecognized headline must not make the whole card disappear: fall back to the title "Returned an error"
            headlineRes = headlineRes(card.headline) ?: R.string.web_search_chat_error_service_error,
            serviceName = card.serviceName,
            serviceId = card.serviceId,
            primary = primaryButton(card.primaryAction)?.takeIf { !it.regenerates || isLastMessage },
            // "Answer again with X" only looks at switchTo, and requires the service to still be on this device
            answerWith = card.switchTo?.takeIf { isLastMessage && switchToAvailable },
        )

    fun sourcesHeader(line: SearchMessageSourcesLine): SearchSourcesHeaderModel =
        SearchSourcesHeaderModel(line.reused, line.searchCount, line.serviceName, line.custom, line.sourceCount)

    /** Web sources of the card, in their shared numbering order. */
    fun webSources(citations: List<Citation>?): List<Citation> =
        citations.orEmpty().filter { it.source == EXTERNAL_SEARCH_SOURCE }.sortedBy { it.index ?: Int.MAX_VALUE }

    /** Library / MCP sources keep the existing citations block. */
    fun otherSources(citations: List<Citation>?): List<Citation> =
        citations.orEmpty().filter { it.source != EXTERNAL_SEARCH_SOURCE }

    /** The regenerate menu gets "Regenerate with a new search" when the message has web sources. */
    fun offersRegenerateWithSearch(citations: List<Citation>?): Boolean =
        citations.orEmpty().any { it.source == EXTERNAL_SEARCH_SOURCE }

    fun host(url: String): String? = runCatching {
        java.net.URI(url).host?.takeIf { it.isNotBlank() }?.removePrefix("www.")
    }.getOrNull()
}

/** Chat-screen side of the error card and the activity line; provided by ChatScreenContent. */
internal interface ExternalSearchChatHost {
    val activity: StateFlow<ExternalSearchActivityState?>

    /**
     * Service detail; [edit] = straight into the key editor (preset) or the service editor (custom).
     * A service gone from this device opens Web Search settings.
     */
    fun openService(serviceId: String?, edit: Boolean)

    /** The service is still on this device (the "Answer again with X" button needs it). */
    suspend fun serviceExists(serviceId: String): Boolean

    fun openSearchMethod()

    fun regenerateWithSearch(messageId: String)

    fun answerWith(messageId: String, target: SearchMessageSwitchTarget)

    /** Pricing page of the service's chosen site; null when it can't be resolved. */
    suspend fun pricingUrl(serviceId: String): String?
}

internal val LocalExternalSearchChatHost = staticCompositionLocalOf<ExternalSearchChatHost?> { null }

/** Sources card starts expanded (screenshot presets only; the chat always starts collapsed). */
internal val LocalSearchSourcesInitiallyExpanded = staticCompositionLocalOf { false }

// ── Activity line chips ──────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SearchQueryChips(state: ExternalSearchActivityState, modifier: Modifier = Modifier) {
    val chips = state.chips
    if (chips.isEmpty()) return
    val colors = OriveoTheme.colors
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        chips.forEachIndexed { index, text ->
            val inFlight = state.searching && index == chips.lastIndex
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(colors.backgroundSecondary)
                    .padding(horizontal = 10.dp, vertical = 4.dp)
                    .widthIn(max = 260.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (inFlight) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(10.dp),
                        strokeWidth = 1.5.dp,
                        color = colors.textTertiary,
                    )
                } else {
                    Icon(
                        imageVector = Icons.Outlined.Search,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = colors.textTertiary,
                    )
                }
                Text(
                    text = text,
                    style = OriveoTheme.typography.caption,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Activity line text for an external search: searching with {name}, then answering from results until the first character. */
@Composable
internal fun externalSearchActivityText(state: ExternalSearchActivityState?): String = when {
    state == null -> stringResource(R.string.stream_activity_web_search)
    state.searching -> stringResource(R.string.web_search_chat_searching, state.serviceName)
    else -> stringResource(R.string.web_search_chat_answering_from_results)
}

// ── Sources card ─────────────────────────────────────────

@Composable
internal fun searchSourcesHeaderText(header: SearchSourcesHeaderModel): Pair<String, String> {
    val lead = if (header.reused) {
        stringResource(R.string.web_search_chat_reused_search)
    } else {
        pluralStringResource(R.plurals.web_search_chat_searched_times, header.searchCount, header.searchCount)
    }
    val count = if (header.sourceCount > 0) {
        pluralStringResource(R.plurals.web_search_chat_sources_count, header.sourceCount, header.sourceCount)
    } else {
        stringResource(R.string.web_search_chat_no_sources)
    }
    return lead to count
}

/** Sources card (board 12): collapsed by default; rows = number · favicon · title · domain (domain always shown). */
@Composable
internal fun SearchSourcesBlock(
    line: SearchMessageSourcesLine,
    citations: List<Citation>,
    modifier: Modifier = Modifier,
    initiallyExpanded: Boolean = false,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val header = ExternalSearchChatPresentation.sourcesHeader(line)
    var expanded by rememberSaveable { mutableStateOf(initiallyExpanded) }
    val (lead, count) = searchSourcesHeaderText(header)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .border(OriveoBorderWidth.standard, colors.hairline, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (header.expandable) Modifier.clickable { expanded = !expanded } else Modifier),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Outlined.Public, contentDescription = null, modifier = Modifier.size(14.dp), tint = colors.textSecondary)
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = "$lead · ${header.serviceName}",
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (header.custom) {
                    Text(
                        text = stringResource(R.string.web_search_badge_custom),
                        style = OriveoTheme.typography.caption,
                        color = colors.textTertiary,
                        modifier = Modifier
                            .border(OriveoBorderWidth.standard, colors.hairline, RoundedCornerShape(4.dp))
                            .padding(horizontal = 4.dp, vertical = 1.dp),
                    )
                }
                Text(text = "· $count", style = OriveoTheme.typography.footnote, color = colors.textSecondary, maxLines = 1)
            }
            if (header.expandable) {
                Icon(
                    imageVector = if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = colors.textTertiary,
                )
            }
        }
        if (expanded && header.expandable) {
            citations.forEach { citation ->
                val host = remember(citation.url) { ExternalSearchChatPresentation.host(citation.url) }
                val openable = remember(citation.url) { isOpenableCitationUrl(citation.url) }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = openable) { openExternalUrl(context, citation.url) }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = "${citation.index ?: ""}",
                        style = OriveoTheme.typography.caption,
                        color = colors.textTertiary,
                    )
                    Box(
                        modifier = Modifier.size(16.dp).background(colors.backgroundSecondary, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Outlined.Public, contentDescription = null, modifier = Modifier.size(12.dp), tint = colors.textTertiary)
                    }
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            text = citation.title?.takeIf { it.isNotBlank() } ?: host ?: citation.url,
                            style = OriveoTheme.typography.footnote,
                            color = colors.textPrimary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = host ?: citation.url,
                            style = OriveoTheme.typography.caption,
                            color = colors.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

// ── Error card ───────────────────────────────────────────

@Composable
internal fun SearchErrorCardView(
    messageId: String,
    card: SearchMessageErrorCard,
    isLastMessage: Boolean,
    modifier: Modifier = Modifier,
) {
    val host = LocalExternalSearchChatHost.current
    val switchToId = card.switchTo?.id
    val switchToAvailable = androidx.compose.runtime.produceState(false, host, switchToId) {
        value = switchToId != null && host?.serviceExists(switchToId) == true
    }.value
    val model = ExternalSearchChatPresentation.errorCard(card, isLastMessage, switchToAvailable)
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    fun perform(action: SearchCardAction) {
        when (action) {
            // Update key: open the service detail and go straight into key editing (custom services go to the editor)
            SearchCardAction.UpdateKey -> host?.openService(model.serviceId, edit = true)
            SearchCardAction.Reconfirm -> host?.openService(model.serviceId, edit = false)
            SearchCardAction.CheckSettings -> host?.openService(model.serviceId, edit = true)
            SearchCardAction.SwitchService -> host?.openSearchMethod()
            SearchCardAction.Retry -> host?.regenerateWithSearch(messageId)
            SearchCardAction.ViewSetupGuide -> openExternalUrl(context, ai.oriveo.community.core.search.SearchSettings.SEARXNG_SETUP_GUIDE_URL)
            SearchCardAction.TopUp -> {
                val id = model.serviceId
                scope.launch {
                    val url = id?.let { host?.pricingUrl(it) }
                    if (url != null) openExternalUrl(context, url) else host?.openService(id, edit = false)
                }
            }
        }
    }
    OriveoCard(
        modifier = modifier.fillMaxWidth(),
        fillColor = colors.backgroundSecondary,
        borderColor = colors.hairline,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                Icon(Icons.Outlined.WarningAmber, contentDescription = null, modifier = Modifier.size(16.dp), tint = colors.warning)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = stringResource(model.headlineRes, model.serviceName),
                        style = OriveoTheme.typography.body,
                        color = colors.textPrimary,
                    )
                    Text(
                        text = stringResource(R.string.web_search_chat_error_detail),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                    )
                }
            }
            val buttons = buildList<@Composable (Modifier) -> Unit> {
                model.primary?.let { button ->
                    add { m ->
                        OriveoPrimaryButton(
                            text = stringResource(button.titleRes),
                            onClick = { perform(button.action) },
                            modifier = m,
                            leadingIcon = if (button.external) {
                                { Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null, modifier = Modifier.size(14.dp)) }
                            } else {
                                null
                            },
                        )
                    }
                }
                model.answerWith?.let { target ->
                    add { m ->
                        OriveoSecondaryButton(
                            text = stringResource(R.string.web_search_action_answer_with, target.name),
                            onClick = { host?.answerWith(messageId, target) },
                            modifier = m,
                        )
                    }
                }
            }
            if (buttons.isNotEmpty()) SearchCardButtons(buttons)
        }
    }
}

/**
 * Error card buttons: side by side (equal width) when every label fits on one line in its half, otherwise stacked
 * full width with the primary first. Labels are never truncated in any language.
 */
@Composable
private fun SearchCardButtons(buttons: List<@Composable (Modifier) -> Unit>) {
    androidx.compose.ui.layout.SubcomposeLayout { constraints ->
        val gap = OriveoTheme.spacing.sm.roundToPx()
        val maxWidth = constraints.maxWidth
        val half = if (buttons.size > 1) (maxWidth - gap * (buttons.size - 1)) / buttons.size else maxWidth
        val natural = subcompose("probe") { buttons.forEach { it(Modifier) } }
            .map { it.maxIntrinsicWidth(androidx.compose.ui.unit.Constraints.Infinity) }
        val sideBySide = buttons.size > 1 && natural.all { it <= half }
        val itemConstraints = if (sideBySide) {
            androidx.compose.ui.unit.Constraints.fixedWidth(half)
        } else {
            androidx.compose.ui.unit.Constraints.fixedWidth(maxWidth)
        }
        val placeables = subcompose("content") { buttons.forEach { it(Modifier) } }.map { it.measure(itemConstraints) }
        val height = if (sideBySide) {
            placeables.maxOf { it.height }
        } else {
            placeables.sumOf { it.height } + gap * (placeables.size - 1)
        }
        layout(maxWidth, height) {
            var offset = 0
            placeables.forEach { p ->
                if (sideBySide) {
                    p.placeRelative(offset, 0)
                    offset += p.width + gap
                } else {
                    p.placeRelative(0, offset)
                    offset += p.height + gap
                }
            }
        }
    }
}
