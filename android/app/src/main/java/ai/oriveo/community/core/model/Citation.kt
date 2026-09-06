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
)
