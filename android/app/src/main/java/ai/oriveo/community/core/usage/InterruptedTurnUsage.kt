package ai.oriveo.community.core.usage

import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.DeliveredCostResolver

/**
 * Usage of a reply stopped midway off managed (interrupted-turn.v1).
 *
 * The stopped leg is estimated like the skill marker interrupted leg: input = the request's own input estimate,
 * output = estimateText(visible text) + estimateText(visible reasoning) at this turn's rhoHi. Usage fragments the
 * stopped leg already received are ignored. Legs finished before the stop keep their reported usage and are added
 * field by field. Nothing visible adds no stopped leg; with no finished leg either nothing is recorded (null).
 */
object InterruptedTurnUsage {

    fun result(
        estimatedInput: Int?,
        rhoHi: Double,
        visibleText: String,
        reasoningText: String,
        finishedLegs: List<ProviderChatResult> = emptyList(),
    ): ProviderChatResult? {
        if (visibleText.isEmpty() && reasoningText.isEmpty()) {
            // Nothing visible: the stopped leg adds nothing; finished legs are always kept.
            return when (finishedLegs.size) {
                0 -> null
                1 -> finishedLegs[0].copy(text = "")
                else -> DeliveredCostResolver.mergeLegs(finishedLegs).copy(text = "")
            }
        }
        val output = ContextBudget.estimateText(visibleText, rhoHi) + ContextBudget.estimateText(reasoningText, rhoHi)
        val stopped = if (estimatedInput == null) {
            // No input estimate: input stays empty and the cost unknown; output is still estimated.
            ProviderChatResult(text = "", completionTokens = output, costSource = CostSource.UNKNOWN.name, usageReported = false)
        } else {
            ProviderChatResult(
                text = "",
                promptTokens = estimatedInput,
                completionTokens = output,
                costSource = CostSource.LOCAL_ESTIMATE.name,
                usageReported = true,
            )
        }
        if (finishedLegs.isEmpty()) return stopped
        return DeliveredCostResolver.mergeLegs(finishedLegs + stopped, base = stopped).copy(text = "")
    }

    /**
     * Visible text the stopped leg added: [streamed] minus [shownBefore] minus one leading blank-line leg separator.
     * Nothing else is trimmed.
     */
    fun stoppedLegText(streamed: String, shownBefore: String): String =
        streamed.removePrefix(shownBefore).removePrefix(LEG_SEPARATOR)

    private const val LEG_SEPARATOR = "\n\n"

    /** Input tokens written to the message: empty when any leg (the stopped one included) has no input. */
    fun inputTokens(usage: ProviderChatResult): Int? = usage.promptTokens.takeIf { usage.usageReported }

    /** What the existing cost derivation is fed: a leg without usage makes the whole cost unknown, never 0. */
    fun pricingResult(usage: ProviderChatResult): ProviderChatResult =
        if (usage.usageReported) usage else ProviderChatResult(text = "", usageReported = false)

    /** skillManifestTokens is written only beside recorded usage. */
    fun manifestTokens(usage: ProviderChatResult?, manifestTokens: Int?): Int? = manifestTokens.takeIf { usage != null }
}
