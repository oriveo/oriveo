package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.resolveProviderLogoKind
import java.time.Instant
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

/** Where a spend figure came from. Only one source exists: this device's own message table. */
enum class CostSummarySource {
    LocalDevice,
}

/** This month's spend, split across the providers that account for most of it. */
data class MonthlyCostSummary(
    val totalCost: Double = 0.0,
    val providers: List<MonthlyCostProviderEntry> = emptyList(),
    val hiddenProviderCount: Int = 0,
    val source: CostSummarySource = CostSummarySource.LocalDevice,
) {
    val isVisible: Boolean
        get() = totalCost > CostFormatter.COST_EPSILON && providers.isNotEmpty()
}

data class MonthlyCostProviderEntry(
    val providerKind: ProviderKind,
    /** Kept alongside the kind so two relay connections do not merge into one row. */
    val providerID: String,
    /** The connection's own name where it has one, otherwise the vendor's. */
    val displayName: String,
    val logoProviderKind: ProviderKind? = null,
    val cost: Double,
)

object CostSummaryCalculator {
    private val entryOrder: Comparator<MonthlyCostProviderEntry> =
        compareByDescending<MonthlyCostProviderEntry> { it.cost }
            .thenBy { it.displayName }

    fun calculateMonthlySummary(
        conversations: List<Conversation>,
        providers: List<Provider>,
        now: Instant = Instant.now(),
        visibleProviderLimit: Int = 3,
    ): MonthlyCostSummary {
        val windowStart = now.atZone(ZoneOffset.UTC)
            .withDayOfMonth(1)
            .truncatedTo(ChronoUnit.DAYS)
            .toInstant()
        val windowEnd = windowStart.atZone(ZoneOffset.UTC)
            .plusMonths(1)
            .toInstant()

        val providerByID = providers.associateBy { it.id }

        val groupedCosts = mutableMapOf<String, Triple<ProviderKind, String, Double>>()

        conversations
            .asSequence()
            .filterNot { it.isDraft }
            .forEach { conversation ->
                conversation.messages.forEach { message ->
                    if (message.role != ChatRole.Assistant) return@forEach
                    if (message.state != ChatMessageState.Delivered) return@forEach
                    if (message.estimatedCost <= CostFormatter.COST_EPSILON) return@forEach

                    val occurredAt = message.createdAt ?: conversation.updatedAt
                    val occurredAtInstant = Instant.ofEpochMilli(occurredAt)
                    if (occurredAtInstant < windowStart || occurredAtInstant >= windowEnd) return@forEach

                    val providerID = message.providerID ?: conversation.providerID
                    val key = "${message.providerKind.name}|$providerID"
                    val previous = groupedCosts[key]
                    groupedCosts[key] = Triple(
                        message.providerKind,
                        providerID,
                        (previous?.third ?: 0.0) + message.estimatedCost,
                    )
                }
            }

        val sortedProviders = groupedCosts.values
            .map { (kind, providerID, cost) ->
                MonthlyCostProviderEntry(
                    providerKind = kind,
                    providerID = providerID,
                    displayName = providerByID[providerID]?.displayName ?: kind.displayName,
                    logoProviderKind = providerByID[providerID]?.let(::resolveProviderLogoKind),
                    cost = cost,
                )
            }
            .sortedWith(entryOrder)

        return MonthlyCostSummary(
            totalCost = sortedProviders.sumOf { it.cost },
            providers = sortedProviders.take(visibleProviderLimit),
            hiddenProviderCount = maxOf(0, sortedProviders.size - visibleProviderLimit),
            source = CostSummarySource.LocalDevice,
        )
    }

    /** Fills in each entry's display name and logo from the current provider list. */
    fun augmentDisplayNames(
        summary: MonthlyCostSummary,
        providers: List<Provider>,
    ): MonthlyCostSummary {
        if (providers.isEmpty()) return summary
        val byID = providers.associateBy { it.id }
        return summary.copy(
            providers = summary.providers.map { entry ->
                val provider = byID[entry.providerID]
                val displayName = provider?.displayName ?: entry.displayName
                val logoProviderKind = provider?.let(::resolveProviderLogoKind) ?: entry.logoProviderKind
                if (displayName == entry.displayName && logoProviderKind == entry.logoProviderKind) {
                    entry
                } else {
                    entry.copy(displayName = displayName, logoProviderKind = logoProviderKind)
                }
            },
        )
    }

    /** This month's spend keyed by provider id, for the provider list rows. */
    fun monthlyCostByProvider(
        conversations: List<Conversation>,
        now: Instant = Instant.now(),
    ): Map<String, Double> {
        val windowStart = now.atZone(ZoneOffset.UTC)
            .withDayOfMonth(1)
            .truncatedTo(ChronoUnit.DAYS)
            .toInstant()
        val windowEnd = windowStart.atZone(ZoneOffset.UTC)
            .plusMonths(1)
            .toInstant()

        val costs = mutableMapOf<String, Double>()

        conversations
            .asSequence()
            .filterNot { it.isDraft }
            .forEach { conversation ->
                conversation.messages.forEach { message ->
                    if (message.role != ChatRole.Assistant) return@forEach
                    if (message.state != ChatMessageState.Delivered) return@forEach
                    if (message.estimatedCost <= CostFormatter.COST_EPSILON) return@forEach

                    val occurredAt = message.createdAt ?: conversation.updatedAt
                    val occurredAtInstant = Instant.ofEpochMilli(occurredAt)
                    if (occurredAtInstant < windowStart || occurredAtInstant >= windowEnd) return@forEach

                    costs[conversation.providerID] =
                        (costs[conversation.providerID] ?: 0.0) + message.estimatedCost
                }
            }

        return costs
    }
}
