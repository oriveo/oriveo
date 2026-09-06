package ai.oriveo.community.core.data.entity

data class ProviderUsageByModelRow(
    val modelName: String?,
    val thisMonthCost: Double,
    val thisMonthMessages: Int,
    val allTimeCost: Double,
    val allTimeMessages: Int,
)
