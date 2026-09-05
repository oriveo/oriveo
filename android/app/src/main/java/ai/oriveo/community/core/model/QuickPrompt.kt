package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import java.util.UUID


@Immutable
data class QuickPrompt(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val prompt: String,
)
