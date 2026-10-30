package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.Serializable

@Immutable
@Serializable
data class Citation(

    val url: String,

    val title: String? = null,

    val snippet: String? = null,

    val faviconUrl: String? = null,

    val index: Int? = null,

    val startIndex: Int? = null,

    val endIndex: Int? = null,

    val docId: String? = null,

    val source: String? = null,

    val anchor: String? = null,

    val lastEdited: String? = null,
    /** When `source == "external_search"`: the query of the search this result came from. The number is in [index]; the full snippet is in [snippet]. */
    val query: String? = null,
    /** External search service id (the catalog id for a preset, the local id for a custom service). */
    val serviceId: String? = null,
    /** Display name of the external search service. */
    val serviceName: String? = null,
    /** When this device ran the search (ISO 8601). */
    val retrievedAt: String? = null,
    /** Site name of the result, when the service provides one. */
    val site: String? = null,
    /** Publish date of the result, when the service provides one. */
    val date: String? = null,
)
