package ai.oriveo.community.core.model

import java.util.UUID


data class OriveoError(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val message: String,
    val actionTitle: String = "",
    val detail: String = "",
    val severity: OriveoErrorSeverity = OriveoErrorSeverity.Warning,
)

enum class OriveoErrorSeverity {
    Warning,
    Critical,
}
