package ai.oriveo.community.feature.settings

enum class MemoryScreenMode {
    Starter,
    Editor,
}

enum class MemoryScreenAction {
    GenerateDraft,
    FocusEditor,
}

enum class MemoryHeroStyle {
    DraftStarter,
    ManualStarter,
    ActiveMemory,
}

data class MemoryScreenPresentation(
    val mode: MemoryScreenMode,
    val heroStyle: MemoryHeroStyle,
    val primaryAction: MemoryScreenAction?,
    val secondaryAction: MemoryScreenAction?,
    val showsExampleSuggestions: Boolean,
    val showsSupportSections: Boolean,
)

fun buildMemoryScreenPresentation(
    memoryText: String,
    isEditorFocused: Boolean,
    hasRecentConversations: Boolean,
): MemoryScreenPresentation {
    val isStarter = memoryText.trim().isEmpty() && !isEditorFocused
    if (isStarter) {
        return MemoryScreenPresentation(
            mode = MemoryScreenMode.Starter,
            heroStyle = if (hasRecentConversations) {
                MemoryHeroStyle.DraftStarter
            } else {
                MemoryHeroStyle.ManualStarter
            },
            primaryAction = if (hasRecentConversations) {
                MemoryScreenAction.GenerateDraft
            } else {
                MemoryScreenAction.FocusEditor
            },
            secondaryAction = if (hasRecentConversations) {
                MemoryScreenAction.FocusEditor
            } else {
                null
            },
            showsExampleSuggestions = false,
            showsSupportSections = false,
        )
    }

    return MemoryScreenPresentation(
        mode = MemoryScreenMode.Editor,
        heroStyle = MemoryHeroStyle.ActiveMemory,

        primaryAction = if (hasRecentConversations) MemoryScreenAction.GenerateDraft else null,
        secondaryAction = null,
        showsExampleSuggestions = false,
        showsSupportSections = true,
    )
}
