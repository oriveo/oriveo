package ai.oriveo.community.core.data.entity

/** Room query result DTO: cost aggregated per currency (USD comes from estimatedCost, non-USD from nonUsdCost*). */
data class CurrencyCostRow(
    val currencyCode: String,
    val totalCost: Double,
)
