@file:Suppress("PropertyName")

package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.ContextBudgetLimit
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.notice.ContextPriceLineAcknowledgement
import ai.oriveo.community.core.notice.ContextPriceLineConfirmState
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import kotlin.math.roundToLong

/** What started the request; only [SEND] and [EDIT] are new user content and may ask. */
enum class ContextConfirmAttempt(val wire: String) {
    SEND("send"),
    EDIT("edit"),
    RETRY("retry"),
    REGENERATE("regenerate"),
    CONTINUE("continue"),
    OVERFLOW_RECOVERY("overflowRecovery"),
    TOOL_LOOP_LEG("toolLoopLeg"),
    ;

    companion object {
        fun fromWire(wire: String): ContextConfirmAttempt? = entries.firstOrNull { it.wire == wire }
    }
}

enum class ContextConfirmKind(val wire: String) {
    NONE("none"),
    OVER_CAP("overCap"),
    PRICE_LINE("priceLine"),
    OVER_CAP_AND_PRICE_LINE("overCapAndPriceLine"),
}

/** Input-only USD estimate at the long-context and the base prompt price, rounded to 6 decimals. */
data class ContextConfirmCost(val long: Double, val base: Double)

/** One user-initiated send after pre-send compaction (contract P9·U8 rule 1). */
data class ContextConfirmInput(
    val attempt: ContextConfirmAttempt,
    /** Runtime model id of this request. */
    val model: String,
    /** Settings › Context "ask before long-context pricing". */
    val reminderEnabled: Boolean,
    val state: ContextPriceLineConfirmState,
    val pricing: ContextCapPricing?,
    /** Assembled plan estimate P-hat. */
    val estimatedInput: Int,
    val B: Int?,
    val limitedBy: ContextBudgetLimit?,
    /** Price line T; null for managed / Free / Relay. */
    val priceLineTokens: Int?,
)

data class ContextConfirmDecision(
    val kind: ContextConfirmKind,
    val showDontAsk: Boolean,
    val cost: ContextConfirmCost?,
    val multiplier: ContextCapMultiplier?,
    val acknowledgeOnConfirm: ContextPriceLineAcknowledgement?,
) {
    val asks: Boolean get() = kind != ContextConfirmKind.NONE
    val priceLine: Boolean get() = kind == ContextConfirmKind.PRICE_LINE || kind == ContextConfirmKind.OVER_CAP_AND_PRICE_LINE
    val overCap: Boolean get() = kind == ContextConfirmKind.OVER_CAP || kind == ContextConfirmKind.OVER_CAP_AND_PRICE_LINE
}

/** Localized templates of the confirmation dialog (%n$s placeholders). */
class ContextConfirmStrings(
    val overCapTitle: String,
    /** %1$s estimate, %2$s cap. */
    val overCapBody: String,
    val priceLineTitle: String,
    /** %1$s estimate, %2$s model, %3$s line, %4$s cost, %5$s base. */
    val priceLineBodyCost: String,
    /** %1$s estimate, %2$s model, %3$s line, %4$s multiplier sentence. */
    val priceLineBodyMult: String,
    /** %1$s estimate, %2$s model, %3$s line. */
    val priceLineBody: String,
    /** %1$s model, %2$s line, %3$s cost, %4$s base. */
    val alsoPriceLineCost: String,
    /** %1$s model, %2$s line, %3$s multiplier sentence. */
    val alsoPriceLineMult: String,
    /** %1$s model, %2$s line. */
    val alsoPriceLine: String,
    val dontAsk: String,
    val send: String,
    /** Shared "Cancel" key. */
    val cancel: String,
) {
    /** Templates looked up by resource key name. */
    constructor(byKey: (String) -> String) : this(
        overCapTitle = byKey("context_confirm_over_cap_title"),
        overCapBody = byKey("context_confirm_over_cap_body"),
        priceLineTitle = byKey("context_confirm_price_line_title"),
        priceLineBodyCost = byKey("context_confirm_price_line_body_cost"),
        priceLineBodyMult = byKey("context_confirm_price_line_body_mult"),
        priceLineBody = byKey("context_confirm_price_line_body"),
        alsoPriceLineCost = byKey("context_confirm_also_price_line_cost"),
        alsoPriceLineMult = byKey("context_confirm_also_price_line_mult"),
        alsoPriceLine = byKey("context_confirm_also_price_line"),
        dontAsk = byKey("context_confirm_dont_ask"),
        send = byKey("context_confirm_send"),
        cancel = byKey("cancel"),
    )
}

/**
 * Dialog text. [dontAsk] is the checkbox label, null when the checkbox is hidden (it starts unchecked).
 * Buttons are [cancel] then [confirm]; the default / Enter action is cancel, never send.
 */
data class ContextConfirmText(
    val title: String,
    val body: String,
    val dontAsk: String?,
    val confirm: String,
    val cancel: String,
)

/** Pre-send confirmation: decision, dialog text and the local state change on confirm (contract P9·U8 rules 1–3). */
object ContextCapConfirmPresentation {
    private const val PER_MILLION = 1_000_000.0
    private const val COST_SCALE = 1_000_000.0

    private const val FSI = "\u2068"
    private const val PDI = "\u2069"

    private val NONE = ContextConfirmDecision(ContextConfirmKind.NONE, false, null, null, null)

    fun decide(input: ContextConfirmInput): ContextConfirmDecision {
        if (input.attempt != ContextConfirmAttempt.SEND && input.attempt != ContextConfirmAttempt.EDIT) return NONE
        val b = input.B
        val overCap = input.limitedBy == ContextBudgetLimit.CUSTOM && b != null && input.estimatedInput > b
        val t = input.priceLineTokens
        val ack = t?.let { ContextPriceLineAcknowledgement(input.model, it) }
        val priceLine = ack != null &&
            input.estimatedInput >= ack.T &&
            input.reminderEnabled &&
            !input.state.suppressed &&
            input.state.acknowledged != ack
        val kind = when {
            overCap && priceLine -> ContextConfirmKind.OVER_CAP_AND_PRICE_LINE
            overCap -> ContextConfirmKind.OVER_CAP
            priceLine -> ContextConfirmKind.PRICE_LINE
            else -> return NONE
        }
        if (!priceLine) return ContextConfirmDecision(kind, false, null, null, null)
        val cost = input.pricing?.let { cost(input.estimatedInput, it) }
        val multiplier = if (cost == null) input.pricing?.let(ContextCapPresentation::multiplier) else null
        return ContextConfirmDecision(kind, showDontAsk = true, cost = cost, multiplier = multiplier, acknowledgeOnConfirm = ack)
    }

    private fun cost(estimatedInput: Int, pricing: ContextCapPricing): ContextConfirmCost? {
        val base = pricing.basePrompt ?: return null
        val long = pricing.longPrompt ?: return null
        if (base <= 0.0 || long <= 0.0) return null
        return ContextConfirmCost(
            long = round6(estimatedInput * long / PER_MILLION),
            base = round6(estimatedInput * base / PER_MILLION),
        )
    }

    private fun round6(value: Double): Double = (value * COST_SCALE).roundToLong() / COST_SCALE

    /** State after the user confirms; cancel leaves the state untouched (do not call this). */
    fun afterConfirm(
        state: ContextPriceLineConfirmState,
        decision: ContextConfirmDecision,
        dontAskChecked: Boolean,
    ): ContextPriceLineConfirmState {
        if (!decision.priceLine) return state
        return state.copy(
            suppressed = state.suppressed || dontAskChecked,
            acknowledged = decision.acknowledgeOnConfirm ?: state.acknowledged,
        )
    }

    /** Model display name: [AIModel.name], falling back to the id when blank or missing; [text] isolates it. */
    fun modelDisplayName(model: AIModel?, id: String): String = model?.name?.takeIf { it.isNotBlank() } ?: id

    /** Dialog text; null when the decision does not ask. */
    fun text(
        decision: ContextConfirmDecision,
        input: ContextConfirmInput,
        modelName: String,
        strings: ContextConfirmStrings,
        panelStrings: ContextCapPanelStrings,
        locale: String,
    ): ContextConfirmText? {
        if (!decision.asks) return null
        // {model} is isolated like the numbers and costs (gate contract rule 4); {multiplier} is not wrapped again.
        val model = FSI + modelName + PDI
        val estimate = ContextCapPresentation.isolatedCompact(input.estimatedInput.toLong(), locale)
        val overCapBody = input.B?.takeIf { decision.overCap }?.let {
            String.format(strings.overCapBody, estimate, ContextCapPresentation.isolatedCompact(it.toLong(), locale))
        }
        val priceLineBody = input.priceLineTokens?.takeIf { decision.priceLine }?.let { t ->
            val line = ContextCapPresentation.isolatedCompact(t.toLong(), locale)
            val cost = decision.cost
            val multiplier = decision.multiplier?.let { ContextCapPresentation.multiplierText(it, panelStrings, locale) }
            val also = decision.overCap
            when {
                cost != null -> {
                    val long = isolatedCost(cost.long)
                    val base = isolatedCost(cost.base)
                    if (also) {
                        String.format(strings.alsoPriceLineCost, model, line, long, base)
                    } else {
                        String.format(strings.priceLineBodyCost, estimate, model, line, long, base)
                    }
                }
                multiplier != null -> if (also) {
                    String.format(strings.alsoPriceLineMult, model, line, multiplier)
                } else {
                    String.format(strings.priceLineBodyMult, estimate, model, line, multiplier)
                }
                also -> String.format(strings.alsoPriceLine, model, line)
                else -> String.format(strings.priceLineBody, estimate, model, line)
            }
        }
        val body = listOfNotNull(overCapBody, priceLineBody).joinToString("\n")
        return ContextConfirmText(
            title = if (decision.overCap) strings.overCapTitle else strings.priceLineTitle,
            body = body,
            dontAsk = strings.dontAsk.takeIf { decision.showDontAsk },
            confirm = strings.send,
            cancel = strings.cancel,
        )
    }

    private fun isolatedCost(value: Double): String = FSI + CostFormatter.format(value) + PDI
}

/** Records a confirm in the local state (no-op unless the decision asked about the price line). */
fun ContextPriceLineConfirmStore.confirm(
    conversationId: String,
    decision: ContextConfirmDecision,
    dontAskChecked: Boolean,
) {
    if (!decision.priceLine) return
    save(conversationId, ContextCapConfirmPresentation.afterConfirm(state(conversationId), decision, dontAskChecked))
}
