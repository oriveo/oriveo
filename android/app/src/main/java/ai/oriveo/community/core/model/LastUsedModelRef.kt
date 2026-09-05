package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.Serializable


@Immutable
@Serializable
data class LastUsedModelRef(
    val providerID: String,
    val modelID: String,
)
