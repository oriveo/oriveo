package ai.oriveo.community.core.data.entity

/** Room query result DTO: the monthly cost per (providerKind, providerID); every relay gets its own row. */
data class MonthlyCostRow(
    val providerKind: String,
    /** Each relay is billed separately: the message-level providerID wins, falling back to the conversation's. */
    val providerID: String,
    val totalCost: Double,
    /** USD rows come from estimatedCost, other currencies from nonUsdCost*; one row per currency for the same provider. */
    val currencyCode: String,
)
