package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.resolveProviderLogoKind

/** Where a spend figure came from. Only one source exists: this device's own message table. */
enum class CostSummarySource {
    LocalDevice,
}

/** This month's spend, split across the providers that account for most of it. */
data class MonthlyCostSummary(
    /** USD only (used by USD budgets and older callers); the per-currency totals are in [totals]. */
    val totalCost: Double = 0.0,
    /** Totals kept apart per currency: USD first, the rest by ascending code; zero amounts are left out. */
    val totals: List<CostPart> = emptyList(),
    val providers: List<MonthlyCostProviderEntry> = emptyList(),
    val hiddenProviderCount: Int = 0,
    val source: CostSummarySource = CostSummarySource.LocalDevice,
) {
    val isVisible: Boolean
        get() = totals.isNotEmpty() && providers.isNotEmpty()
}

data class MonthlyCostProviderEntry(
    val providerKind: ProviderKind,
    /** Kept alongside the kind so two relay connections do not merge into one row. */
    val providerID: String,
    /** The connection's own name where it has one, otherwise the vendor's. */
    val displayName: String,
    val logoProviderKind: ProviderKind? = null,
    /** USD only (used for ordering and older callers); the per-currency amounts are in [costs]. */
    val cost: Double,
    /** This provider's spend kept apart per currency. */
    val costs: List<CostPart> = emptyList(),
)

object CostSummaryCalculator {
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
}
