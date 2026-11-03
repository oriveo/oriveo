package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.core.context.ContextCompactNumber
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.usage.CostParts
import java.util.Locale

/**
 * Pure presentation-decision layer for the token usage popup -- no Compose / Android dependency.
 *
 * Pulled out on purpose: this repo has no Compose UI test infrastructure (no
 * `ui-test-junit4` in the version catalog, zero `createComposeRule` calls anywhere),
 * so visibility logic left inline inside a Composable is effectively untestable. A
 * silent regression across every locale once slipped through for exactly that reason --
 * nothing here was ever asserted by a test.
 *
 * Number formatting stays in the Composable (it's locale-sensitive and follows the
 * app's in-app language); this layer only decides what to render.
 */
internal data class MessageTokenUsageSnapshot(
    val inputTokens: Int? = null,
    val outputTokens: Int? = null,
    val cacheReadTokens: Int? = null,
    val cacheWriteTokens: Int? = null,
    /** USD part of the message cost, as persisted. */
    val estimatedCost: Double = 0.0,
    /** [CostSource] enum name of the USD part; null = not recorded (legacy). */
    val costSource: String? = null,
    val nonUsdCost: NonUsdCost? = null,
) {
    /** The USD part is billed by the Oriveo server. */
    private val isManaged: Boolean
        get() = costSource.equals(CostSource.MANAGED.name, ignoreCase = true)

    /** The USD price is unknown and nothing else is recorded: the row shows the missing-state label. */
    val showsUsdUnavailable: Boolean
        get() = nonUsdCost == null && !isManaged &&
            costSource.equals(CostSource.UNKNOWN.name, ignoreCase = true) &&
            !(estimatedCost.isFinite() && estimatedCost > CostFormatter.COST_EPSILON)

    /**
     * Cost row visibility: shown for a USD amount above epsilon,
     * for a non-USD part whose price is unknown or whose amount is above epsilon, or for an unknown
     * USD price of a non-managed message. Managed / subscription / missing sources at or below epsilon
     * are hidden; a zero amount is never shown.
     */
    val showsCost: Boolean
        get() {
            if (estimatedCost.isFinite() && estimatedCost > CostFormatter.COST_EPSILON) return true
            if (showsUsdUnavailable) return true
            val nonUsd = nonUsdCost ?: return false
            return nonUsd.costSource.equals(CostSource.UNKNOWN.name, ignoreCase = true) ||
                (nonUsd.amount.isFinite() && nonUsd.amount > CostFormatter.COST_EPSILON)
        }

    /** The Estimated tag: any source other than upstream or managed, a missing source included. */
    val isCostEstimated: Boolean
        get() = !costSource.equals(CostSource.UPSTREAM.name, ignoreCase = true) && !isManaged

    /**
     * The total only exists when both input and output are present; cache sub-values
     * are already included in the input count, so they must not be added again
     * (`totalTokens = inputTokens + outputTokens`).
     */
    val total: Int?
        get() {
            val input = inputTokens ?: return null
            val output = outputTokens ?: return null
            return (input.toLong() + output.toLong()).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }
}

/** One cache sub-row nested inside the "input" card. */
internal data class TokenUsageCacheRow(
    val kind: Kind,
    val value: Int,
) {
    internal enum class Kind { CacheRead, CacheWrite }
}

/**
 * The rows/cards the popup should render.
 *
 * @property cacheRows Cache read/write sub-rows. An empty list means the upstream
 *   simply didn't report this metric -- the card is omitted entirely rather than shown
 *   with a placeholder that would look like real data. A value of 0 is a genuine
 *   observation and still appears in the list, rendered as 0.
 * @property singleColumn When the input card carries sub-rows its height dwarfs the
 *   output card, so a side-by-side layout looks ragged -- switch to a single column
 *   instead. Different information density warranting different layouts is intentional,
 *   not an inconsistency.
 */
internal data class MessageTokenUsageRows(
    val inputTokens: Int?,
    val outputTokens: Int?,
    val cacheRows: List<TokenUsageCacheRow>,
    val total: Int?,
) {
    val singleColumn: Boolean
        get() = cacheRows.isNotEmpty()
}

/**
 * Resolves a message's usage snapshot into rendering decisions.
 *
 * The primary fields (input / output / total) always render; when a value can't be
 * resolved, the caller shows a missing-state placeholder -- that means "the upstream
 * didn't report this number", not "this capability is unsupported". The optional
 * fields (cache read / write) simply skip their row when missing. The distinction is
 * that input and output are primary fields, while cache read and cache write are optional.
 */
internal fun resolveTokenUsageRows(snapshot: MessageTokenUsageSnapshot): MessageTokenUsageRows =
    MessageTokenUsageRows(
        inputTokens = snapshot.inputTokens,
        outputTokens = snapshot.outputTokens,
        cacheRows = buildList {
            snapshot.cacheReadTokens?.let { add(TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheRead, it)) }
            snapshot.cacheWriteTokens?.let { add(TokenUsageCacheRow(TokenUsageCacheRow.Kind.CacheWrite, it)) }
        },
        total = snapshot.total,
    )

/**
 * Compact total under the "Token usage" menu item (same notation as the transcript separator, rounds
 * down). Null when the total is unknown: the subtitle is not shown, no placeholder (same as iOS).
 */
internal fun tokenUsageMenuSubtitle(snapshot: MessageTokenUsageSnapshot, locale: String): String? =
    snapshot.total?.let { ContextCompactNumber.format(it.toLong(), locale) }

/**
 * Cost row value: same per-currency formatting as the message cost text (parts joined by " + ");
 * a non-USD part with an unknown price renders [unavailableText] (the sheet's own missing-state label).
 * Empty when nothing is displayable.
 */
internal fun tokenUsageCostText(snapshot: MessageTokenUsageSnapshot, locale: Locale, unavailableText: String): String =
    if (snapshot.showsUsdUnavailable) unavailableText else CostFormatter.formatParts(
        parts = CostParts.messageParts(snapshot.estimatedCost, snapshot.nonUsdCost),
        locale = locale,
        notAvailableCodes = CostParts.messageNotAvailableCodes(snapshot.nonUsdCost),
        notAvailableText = unavailableText,
    )
