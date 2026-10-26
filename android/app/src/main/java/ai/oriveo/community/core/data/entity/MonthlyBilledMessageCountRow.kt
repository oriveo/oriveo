package ai.oriveo.community.core.data.entity

/**
 * Room query result DTO: the number of billed messages this month, aggregated by providerID
 * (message-level first, falling back to the conversation's). A message counts once, whatever its currencies.
 */
data class MonthlyBilledMessageCountRow(
    val providerID: String,
    val billedCount: Int,
)
