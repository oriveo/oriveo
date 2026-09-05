package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.CostFormatter

/** Where a usage figure came from. Only one source exists: this device's own message table. */
enum class UsageDataSource {
    LocalDevice,
}

data class ProviderUsageModelEntry(
    val modelKey: String,
    val modelName: String,
    val cost: Double,
    val messages: Int,
)

data class ProviderUsageWindow(
    val totalCost: Double = 0.0,
    val totalMessages: Int = 0,
    val models: List<ProviderUsageModelEntry> = emptyList(),
    val hiddenModelCount: Int = 0,
) {
    val isVisible: Boolean
        get() = totalCost > CostFormatter.COST_EPSILON && models.isNotEmpty()
}

data class ProviderUsageSummary(
    val providerId: String = "",
    val providerName: String = "",
    val source: UsageDataSource = UsageDataSource.LocalDevice,
    val thisMonth: ProviderUsageWindow = ProviderUsageWindow(),
    val allTime: ProviderUsageWindow = ProviderUsageWindow(),
) {
    val isVisible: Boolean
        get() = thisMonth.isVisible || allTime.isVisible
}
