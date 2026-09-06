package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.util.normalizeUuid

enum class NoteSort {
    UpdatedAt,
    CreatedAt,
    SourceProviderKind,
    ;

    val rawValue: String
        get() = when (this) {
            UpdatedAt -> "updatedAt"
            CreatedAt -> "createdAt"
            SourceProviderKind -> "sourceProviderKind"
        }

    companion object {
        fun fromRawValue(raw: String?): NoteSort =
            entries.firstOrNull { it.rawValue == raw } ?: UpdatedAt
    }
}

object NoteListing {

    fun filterAndSort(
        notes: List<Note>,
        folderId: String? = null,
        tags: List<String> = emptyList(),
        sort: NoteSort = NoteSort.UpdatedAt,

        uncategorizedOnly: Boolean = false,
    ): List<Note> {
        val normalizedFolder = folderId?.let(::normalizeUuid)
        val filtered = notes.asSequence()
            .filter { it.deletedAt == null }
            .filter { note ->
                when {
                    uncategorizedOnly -> note.noteFolderID == null
                    normalizedFolder == null -> true
                    else -> note.noteFolderID?.let(::normalizeUuid) == normalizedFolder
                }
            }
            .filter { note -> tags.all { tag -> note.tags.contains(tag) } }
            .toList()
        return sortNotes(filtered, sort)
    }

    fun sortNotes(notes: List<Note>, sort: NoteSort): List<Note> {
        val byField: Comparator<Note> = when (sort) {
            NoteSort.UpdatedAt -> compareByDescending { millis(it.updatedAt) }
            NoteSort.CreatedAt -> compareByDescending { millis(it.createdAt) }
            NoteSort.SourceProviderKind -> compareBy<Note> { it.sourceProviderKind?.rawValue ?: "" }
                .thenByDescending { millis(it.updatedAt) }
        }
        val comparator = compareByDescending<Note> { it.isPinned }
            .then(byField)
            .thenBy { it.title.lowercase() }
        return notes.sortedWith(comparator)
    }

    fun availableTags(notes: List<Note>, folderId: String?, max: Int = 12, uncategorizedOnly: Boolean = false): List<String> {
        val normalizedFolder = folderId?.let(::normalizeUuid)
        return notes.asSequence()
            .filter { it.deletedAt == null }
            .filter { note ->
                when {
                    uncategorizedOnly -> note.noteFolderID == null
                    normalizedFolder == null -> true
                    else -> note.noteFolderID?.let(::normalizeUuid) == normalizedFolder
                }
            }
            .flatMap { it.tags.asSequence() }
            .distinct()
            .sortedBy { it.lowercase() }
            .take(max)
            .toList()
    }

    fun tagSuggestions(notes: List<Note>, excluding: List<String>, max: Int = 12): List<String> {
        val existing = excluding.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
        val seen = linkedSetOf<String>()
        val suggestions = mutableListOf<String>()
        notes.asSequence()
            .filter { it.deletedAt == null }
            .flatMap { it.tags.asSequence() }
            .forEach { raw ->
                val tag = raw.trim()
                val key = tag.lowercase()
                if (tag.isNotEmpty() && key !in existing && seen.add(key)) {
                    suggestions += tag
                    if (suggestions.size >= max) return suggestions
                }
            }
        return suggestions
    }

    private fun millis(iso: String): Long = NoteTime.isoToMillisOrNull(iso) ?: 0L
}
