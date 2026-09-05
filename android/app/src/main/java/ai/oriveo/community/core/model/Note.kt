package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable


@Immutable
data class Note(
    
    val id: String,
    
    val title: String,
    val titleSource: NoteTitleSource = NoteTitleSource.Placeholder,
    
    val body: String,
    
    val bodySnapshot: String? = null,
    
    val userNote: String? = null,
    
    val tags: List<String> = emptyList(),
    
    val noteFolderID: String? = null,
    val sourceConversationId: String? = null,
    val sourceMessageId: String? = null,
    val sourceModelID: String? = null,
    
    val sourceModelName: String? = null,
    val sourceProviderKind: ProviderKind? = null,
    
    val sourceProviderName: String? = null,
    
    val sourcePrompt: String? = null,
    val captureKind: NoteCaptureKind = NoteCaptureKind.Blank,
    
    val provenance: List<ProvenanceEntry> = emptyList(),
    val isPinned: Boolean = false,
    
    val createdAt: String,
    
    val updatedAt: String,
    /** Soft delete, as a UTC ISO 8601 string. Non-null means the note is in the trash. */
    val deletedAt: String? = null,
) {
    val isTrashed: Boolean get() = deletedAt != null

    
    val hasSource: Boolean
        get() = captureKind != NoteCaptureKind.Blank &&
            (!sourceModelName.isNullOrBlank() || !sourceProviderName.isNullOrBlank() || !sourcePrompt.isNullOrBlank())

    
    val canCrosscheck: Boolean
        get() = !isTrashed && captureKind != NoteCaptureKind.Blank &&
            !sourcePrompt.isNullOrBlank() && sourceModelName != null && sourceProviderKind != null
}


@Immutable
data class NoteFolder(
    val id: String,
    
    val name: String,
    
    val sortOrder: Int,
    
    val colorTag: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String? = null,
)


@Serializable
data class ProvenanceEntry(
    val kind: ProvenanceKind,
    val modelID: String? = null,
    val modelName: String? = null,
    val providerKind: ProviderKind? = null,
    val providerName: String? = null,
    val conversationId: String? = null,
    val messageId: String? = null,
    
    val at: String,
)


enum class NoteTitleSource {
    Placeholder,
    Manual,
    ;

    val rawValue: String
        get() = when (this) {
            Placeholder -> "placeholder"
            Manual -> "manual"
        }

    companion object {
        
        fun fromRawValue(raw: String?): NoteTitleSource =
            entries.firstOrNull { it.rawValue == raw } ?: Placeholder
    }
}


enum class NoteCaptureKind {
    FullAnswer,
    Selection,
    UserMessage,
    Blank,
    ;

    val rawValue: String
        get() = when (this) {
            FullAnswer -> "fullAnswer"
            Selection -> "selection"
            UserMessage -> "userMessage"
            Blank -> "blank"
        }

    companion object {
        
        fun fromRawValue(raw: String?): NoteCaptureKind =
            entries.firstOrNull { it.rawValue == raw } ?: Blank
    }
}


@Serializable
enum class ProvenanceKind {
    @SerialName("origin") Origin,
    @SerialName("crosscheck") Crosscheck,
    @SerialName("digest") Digest,
    @SerialName("transform") Transform,
    ;

    val rawValue: String
        get() = when (this) {
            Origin -> "origin"
            Crosscheck -> "crosscheck"
            Digest -> "digest"
            Transform -> "transform"
        }

    companion object {
        
        fun fromRawValue(raw: String?): ProvenanceKind? =
            entries.firstOrNull { it.rawValue == raw }
    }
}
